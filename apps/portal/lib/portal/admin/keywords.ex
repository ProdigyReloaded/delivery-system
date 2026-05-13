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

defmodule Prodigy.Portal.Admin.Keywords do
  @moduledoc """
  Queries + actions the admin "Keywords" tab calls into. The keyword
  table is populated as a side-effect of object upload (see
  `Prodigy.Portal.Admin.Objects.insert_many/1`); this module is for
  read + targeted delete (detach a keyword from its object without
  deleting the object itself - the admin equivalent of editing the
  0x71 segment out of the source).
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Keyword
  alias Prodigy.Core.Objects.KeywordIndex
  alias Prodigy.Core.Objects.Store

  @pubsub Prodigy.Core.PubSub
  @topic "service:keywords"

  # Format constants for the TA-series keyword index family. Values
  # pinned from the real DOS-client cache files in
  # `apps/core/test/fixtures/keyword_index/`.
  @primary_name "TAODCUSSPGM"
  @secondary_name "TAODCUKJD  "
  @keywords_per_secondary 14
  # Byte 15 of the primary's payload is NOT a cap - it's the actual
  # total-secondary count, used by XXPXKWRD label_358/373 as a
  # circular-iteration wrap point. Setting it to a constant like 97
  # when we emit fewer secondaries makes the client's "Index" listing
  # try to FETCH secondaries that don't exist (SafePage). Confirmed
  # via live-client testing on 2026-04-19. The max byte value is 255,
  # which bounds how many secondaries we can emit before needing a
  # rebalance.
  @max_byte_value 0xFF
  @format_flag 0x02
  @candidacy 0x00
  @type_program 0x0C

  @doc "Topic admin LVs subscribe to for keyword lifecycle events."
  def topic, do: @topic

  @doc """
  All keyword rows ordered alphabetically. Each row carries the
  target (object_name, object_sequence, object_type) plus the
  timestamps so the admin table can surface "last updated".
  """
  def list do
    from(k in Keyword, order_by: [asc: k.keyword])
    |> Repo.all()
  end

  @doc """
  Look up a single keyword row. Returns `%Keyword{}` or `nil`.
  """
  def get(keyword) when is_binary(keyword), do: Repo.get(Keyword, keyword)

  @doc """
  Create a new keyword row. Normalizes the keyword to uppercase
  (DOS client wire contract) before insert. Returns
  `{:ok, %Keyword{}}` or `{:error, changeset}`. Broadcasts
  `:keywords_upserted` on success.
  """
  def create(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    %Keyword{}
    |> Keyword.changeset(normalized)
    |> Repo.insert()
    |> case do
      {:ok, row} ->
        broadcast(:keywords_upserted)
        {:ok, row}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Update an existing keyword row. If the supplied `attrs.keyword`
  differs from `old_keyword`, the old row is deleted and a new one
  created (the keyword text is the primary key; renames can't
  happen in place). Returns `{:ok, %Keyword{}}`, `:not_found`, or
  `{:error, changeset}`.
  """
  def update(old_keyword, attrs) when is_binary(old_keyword) and is_map(attrs) do
    normalized = normalize_attrs(attrs)
    new_keyword = Map.get(normalized, :keyword) || old_keyword

    case Repo.get(Keyword, old_keyword) do
      nil ->
        :not_found

      %Keyword{} = existing ->
        if new_keyword == old_keyword do
          existing
          |> Keyword.changeset(normalized)
          |> Repo.update()
          |> case do
            {:ok, row} ->
              broadcast(:keywords_upserted)
              {:ok, row}

            {:error, _} = err ->
              err
          end
        else
          Repo.transaction(fn ->
            {:ok, _} = Repo.delete(existing)

            case %Keyword{} |> Keyword.changeset(normalized) |> Repo.insert() do
              {:ok, row} -> row
              {:error, cs} -> Repo.rollback(cs)
            end
          end)
          |> case do
            {:ok, row} ->
              broadcast(:keywords_upserted)
              {:ok, row}

            {:error, cs} ->
              {:error, cs}
          end
        end
    end
  end

  @doc """
  Delete a keyword row by its keyword text. Returns
  `{:ok, %Keyword{}}` on success or `:not_found`. Broadcasts
  `:keywords_deleted` so admin LVs reload.
  """
  def delete(keyword) when is_binary(keyword) do
    case Repo.get(Keyword, keyword) do
      nil ->
        :not_found

      %Keyword{} = row ->
        case Repo.delete(row) do
          {:ok, deleted} ->
            broadcast(:keywords_deleted)
            {:ok, deleted}

          error ->
            error
        end
    end
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_atom(k), v} end)
    |> Map.update(:keyword, nil, &normalize_keyword/1)
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  defp normalize_keyword(nil), do: nil
  defp normalize_keyword(s) when is_binary(s), do: s |> String.trim() |> String.upcase()
  defp normalize_keyword(other), do: other

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  rescue
    _ -> :ok
  end

  # --- rebuild_index -------------------------------------------------

  @doc """
  Materialize the current `keyword` table into a fresh primary object
  (`TAODCUSSPGM`) + N secondaries (`TAODCUKJD  `, seq 1..N) and push
  the whole family through `Prodigy.Core.Objects.Store.insert_or_bump/2`
  in a single transaction.

  Chunks keywords by `@keywords_per_secondary` (14, matching the TA
  primary's byte at payload offset 1). `pick_chunk_size/1` auto-
  rebalances when we'd exceed 255 secondaries (the byte-15 range).

  The primary's byte 15 is the **total** secondary count - XXPXKWRD
  label_358/373 uses it as a circular-iteration wrap point, not as a
  cap. Setting byte 15 higher than the actual count makes the
  client's "Index" listing walk off the end and FETCH a missing
  TAODCUKJD object, which the server returns as SafePage. Confirmed
  via live-client testing 2026-04-19.

  Returns `{:ok, %{primary: disposition, secondaries:
  [{seq, disposition}], counts: ..., total_secondaries: N}}` on
  success or `{:error, reason}` on failure. The Store's usual
  inserted/bumped/unchanged dispositions bubble up per object so the
  admin can see which parts actually changed since the last rebuild.
  """
  @spec rebuild_index() :: {:ok, map()} | {:error, term()}
  def rebuild_index do
    keywords = all_sorted_keywords()

    cond do
      keywords == [] ->
        {:error, :no_keywords}

      true ->
        chunk_size = pick_chunk_size(length(keywords))
        chunks = Enum.chunk_every(keywords, chunk_size)
        do_rebuild(chunks, chunk_size)
    end
  end

  @doc false
  # Pick keywords_per_secondary so the resulting number of secondaries
  # fits in a byte (since byte 15 of the primary stores it). We use
  # 14 as the default chunk size (matching production's TA primary)
  # until keyword count exceeds 14 x 255; above that we auto-rebalance
  # by bumping chunk size to `ceil(total / 255)`.
  def pick_chunk_size(total_keywords) do
    default_capacity = @keywords_per_secondary * @max_byte_value

    if total_keywords <= default_capacity do
      @keywords_per_secondary
    else
      div(total_keywords + @max_byte_value - 1, @max_byte_value)
    end
  end

  defp all_sorted_keywords do
    from(k in Keyword,
      order_by: [asc: k.keyword],
      select: %{
        keyword: k.keyword,
        object_name: k.object_name,
        object_sequence: k.object_sequence,
        object_type: k.object_type
      }
    )
    |> Repo.all()
  end

  defp do_rebuild(chunks, chunk_size) do
    secondary_structs = build_secondaries(chunks)
    boundary_keywords = Enum.map(secondary_structs, &last_keyword/1)
    primary_struct = build_primary(boundary_keywords, chunk_size, length(chunks))

    parsed =
      [primary_to_parsed(primary_struct) | Enum.map(secondary_structs, &secondary_to_parsed/1)]

    case Store.insert_or_bump(parsed, on_keyword_collision: :error) do
      {:ok, result} ->
        {:ok, summarize(result, length(secondary_structs))}

      {:error, _} = err ->
        err
    end
  end

  defp build_secondaries(chunks) do
    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, seq} ->
      entries =
        Enum.map(chunk, fn row ->
          {row.keyword, {row.object_name, row.object_sequence, row.object_type}}
        end)

      KeywordIndex.build_secondary(entries,
        sequence: seq,
        name: @secondary_name,
        version: 1,
        candidacy: @candidacy,
        format_flag: @format_flag
      )
    end)
  end

  defp build_primary(boundary_keywords, chunk_size, total_secondaries) do
    %KeywordIndex.Primary{
      format_flag: @format_flag,
      keywords_per_secondary: chunk_size,
      secondary_name_template: @secondary_name,
      first_seq_byte: 0x01,
      secondary_type: @type_program,
      total_secondaries: total_secondaries,
      boundary_keywords: boundary_keywords,
      version: 1,
      candidacy: @candidacy
    }
  end

  defp last_keyword(%KeywordIndex.Secondary{entries: entries}) do
    entries |> List.last() |> Map.fetch!(:keyword)
  end

  # Convert a struct into the map shape Store.insert_or_bump expects.
  # content_hash + keyword are used by Store for its content-compare
  # logic; keyword_index objects don't carry keyword-navigation TACs
  # themselves, so the `keyword` field is always nil here.
  defp primary_to_parsed(%KeywordIndex.Primary{} = p) do
    blob = KeywordIndex.encode_primary(p)
    parsed_from_blob(blob, @primary_name, 0x00)
  end

  defp secondary_to_parsed(%KeywordIndex.Secondary{} = s) do
    blob = KeywordIndex.encode_secondary(s)
    parsed_from_blob(blob, s.name, s.sequence)
  end

  defp parsed_from_blob(blob, name, sequence) do
    %{
      name: name,
      sequence: sequence,
      type: @type_program,
      # Use version 1 for a fresh object. Store.insert_or_bump compares
      # content_hash against the latest existing row and bumps from
      # there; the declared version is only used when no prior row
      # exists.
      version: 1,
      contents: blob,
      content_hash: Prodigy.Core.Objects.Codec.content_hash(blob),
      keyword: nil
    }
  end

  defp summarize(%{} = store_result, total_secondaries) do
    all_rows = store_result.inserted ++ store_result.bumped ++ store_result.unchanged

    primary_disposition =
      Enum.find_value(all_rows, :unchanged, fn row ->
        if String.trim(row.name) == "TAODCUSSPGM", do: classify(row, store_result)
      end)

    secondary_dispositions =
      all_rows
      |> Enum.filter(&(String.trim(&1.name) == "TAODCUKJD"))
      |> Enum.map(fn row -> {row.sequence, classify(row, store_result)} end)
      |> Enum.sort_by(fn {seq, _} -> seq end)

    %{
      primary: primary_disposition,
      secondaries: secondary_dispositions,
      counts: %{
        inserted: length(store_result.inserted),
        bumped: length(store_result.bumped),
        unchanged: length(store_result.unchanged)
      },
      total_secondaries: total_secondaries
    }
  end

  defp classify(row, store_result) do
    cond do
      row in store_result.inserted -> :inserted
      row in store_result.bumped -> :bumped
      row in store_result.unchanged -> :unchanged
      true -> :unknown
    end
  end
end
