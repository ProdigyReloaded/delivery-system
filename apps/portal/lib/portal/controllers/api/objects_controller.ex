# Copyright 2026, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Portal.Api.ObjectsController do
  @moduledoc """
  `/api/v1/objects` endpoints. Today: bulk upload via gzipped tar.

  Body is a `tar.gz` where each entry is one Prodigy object blob
  (exactly the bytes that would sit on disk). Entry names are
  informational - the object's identity comes from its 18-byte
  header, not its filename. Handoff is atomic: every entry commits
  via `Prodigy.Core.Objects.Store.insert_or_bump/2` inside one
  `Repo.transaction/1`, and any parse / insert failure rolls the
  whole batch back. Keyword-index rebuild is triggered if and only
  if `insert_or_bump` reports `keywords_changed? == true`.

  Hard caps (bounce with 413 + JSON):
    * compressed body   <=   1 GB
    * entry count       <= 250_000
    * per-entry bytes   <=  10 MB

  Bumped 2026-04-19 to accommodate Groliers (~150k entries, ~530 MB
  uncompressed, ~200-300 MB gzipped). If the buffered decompression
  ever becomes a memory problem, switch to entry-by-entry streaming
  via `:erl_tar.init/3` before raising these further.

  Response (200):

      {
        "counts": {"inserted": .., "bumped": .., "unchanged": .., "skipped_keyword_collisions": ..},
        "keyword_index_rebuilt": bool,
        "keyword_index": { ... } | null,
        "errors": []
      }
  """
  use Prodigy.Portal, :controller

  alias Prodigy.Core.Objects.Store
  alias Prodigy.Portal.Admin.Keywords
  alias Prodigy.Portal.Authz

  plug :require_objects_upload

  defp require_objects_upload(conn, _opts) do
    if Authz.can?(conn.assigns[:current_api_scopes], :objects, :upload) do
      conn
    else
      body = Phoenix.json_library().encode_to_iodata!(%{error: "forbidden"})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, body)
      |> halt()
    end
  end

  @max_compressed_bytes 1024 * 1024 * 1024
  @max_entries 250_000
  @max_entry_bytes 10 * 1024 * 1024

  def upload(conn, _params) do
    case read_all_body(conn) do
      {:ok, compressed, conn} ->
        handle_compressed(conn, compressed)

      {:error, :body_too_large} ->
        json_error(conn, 413, "body_too_large")

      {:error, reason} ->
        json_error(conn, 400, "read_error", %{detail: inspect(reason)})
    end
  end

  # --- internals -----------------------------------------------------

  defp read_all_body(conn) do
    read_all_body_loop(conn, <<>>, 0)
  end

  defp read_all_body_loop(conn, acc, acc_size) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        total = acc_size + byte_size(chunk)
        if total > @max_compressed_bytes do
          {:error, :body_too_large}
        else
          {:ok, acc <> chunk, conn}
        end

      {:more, chunk, conn} ->
        total = acc_size + byte_size(chunk)

        if total > @max_compressed_bytes do
          {:error, :body_too_large}
        else
          read_all_body_loop(conn, acc <> chunk, total)
        end

      {:error, _} = err ->
        err
    end
  end

  defp handle_compressed(conn, compressed) do
    with {:ok, tar_bytes} <- safe_gunzip(compressed),
         {:ok, entries} <- extract_tar(tar_bytes),
         :ok <- enforce_entry_limits(entries),
         {:ok, parsed} <- parse_entries(entries),
         {:ok, result} <- commit(parsed) do
      json(conn, build_response(result))
    else
      {:error, {:entry_too_large, name, size}} ->
        json_error(conn, 413, "entry_too_large", %{name: name, size: size})

      {:error, :too_many_entries} ->
        json_error(conn, 413, "too_many_entries", %{limit: @max_entries})

      {:error, {:parse_errors, errs}} ->
        json_error(conn, 422, "parse_errors", %{errors: errs})

      {:error, {:insert_failed, reason}} ->
        json_error(conn, 422, "insert_failed", %{detail: inspect(reason)})

      {:error, reason} ->
        json_error(conn, 400, "bad_request", %{detail: inspect(reason)})
    end
  end

  defp safe_gunzip(compressed) do
    {:ok, :zlib.gunzip(compressed)}
  rescue
    _ -> {:error, :bad_gzip}
  end

  defp extract_tar(tar_bytes) do
    case :erl_tar.extract({:binary, tar_bytes}, [:memory]) do
      {:ok, entries} ->
        # erl_tar hands back charlist names; normalize to binary.
        {:ok, Enum.map(entries, fn {name, body} -> {List.to_string(name), body} end)}

      {:error, reason} ->
        {:error, {:bad_tar, reason}}
    end
  end

  defp enforce_entry_limits(entries) do
    cond do
      length(entries) > @max_entries ->
        {:error, :too_many_entries}

      too_big = Enum.find(entries, fn {_, body} -> byte_size(body) > @max_entry_bytes end) ->
        {name, body} = too_big
        {:error, {:entry_too_large, name, byte_size(body)}}

      true ->
        :ok
    end
  end

  defp parse_entries(entries) do
    {ok, errs} =
      entries
      |> Enum.map(fn {name, body} ->
        case Store.parse_import_blob(body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, %{name: name, reason: to_string(reason)}}
        end
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    cond do
      errs != [] ->
        {:error, {:parse_errors, Enum.map(errs, fn {:error, m} -> m end)}}

      true ->
        {:ok, Enum.map(ok, fn {:ok, p} -> p end)}
    end
  end

  # 10 minutes. Generous enough for a 250k-entry batch at the current
  # SELECT-per-row pace. See the store-bulk-insert backlog item for
  # the proper fix (one SELECT + Repo.insert_all, bringing a 250k
  # import down from ~5 min to ~10 s).
  @txn_timeout_ms 10 * 60_000

  defp commit(parsed) do
    case Store.insert_or_bump(parsed,
           on_keyword_collision: :error,
           timeout: @txn_timeout_ms
         ) do
      {:ok, result} ->
        if result.keywords_changed? do
          case Keywords.rebuild_index() do
            {:ok, idx} -> {:ok, Map.put(result, :keyword_index, idx)}
            # Empty keyword table after the batch -> no index to build.
            {:error, :no_keywords} -> {:ok, Map.put(result, :keyword_index, nil)}
            {:error, reason} -> {:error, {:insert_failed, {:rebuild_failed, reason}}}
          end
        else
          {:ok, Map.put(result, :keyword_index, nil)}
        end

      {:error, reason} ->
        {:error, {:insert_failed, reason}}
    end
  end

  defp build_response(%{} = result) do
    %{
      counts: %{
        inserted: length(result.inserted),
        bumped: length(result.bumped),
        unchanged: length(result.unchanged),
        skipped_keyword_collisions: length(result.skipped_keywords)
      },
      keyword_index_rebuilt: result.keywords_changed? and result.keyword_index != nil,
      keyword_index: serialize_index_result(result.keyword_index),
      errors: []
    }
  end

  defp serialize_index_result(nil), do: nil

  defp serialize_index_result(%{} = idx) do
    %{
      primary: idx.primary,
      secondaries: Enum.map(idx.secondaries, fn {seq, disp} -> %{sequence: seq, disposition: disp} end),
      counts: idx.counts,
      total_secondaries: idx.total_secondaries
    }
  end

  defp json_error(conn, status, error, extra \\ %{}) do
    body = Map.merge(%{error: error}, extra)

    conn
    |> put_status(status)
    |> json(body)
  end
end
