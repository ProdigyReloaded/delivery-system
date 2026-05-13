# Copyright 2022, Phillip Heller
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

defmodule Import do
  @moduledoc """
  `podbutil import` CLI entry point. Two modes:

  * **Local** (default) - walks the file globs, parses each object via
    `Prodigy.Core.Objects.Store.parse_import_blob/1`, and commits the
    whole batch through `Store.insert_or_bump/1`. Needs DB_* env vars.

  * **HTTP** (`--url <portal>`) - glob-expands the files, packages
    them as `tar.gz` in memory, and POSTs to the portal's
    `/api/v1/objects/upload` endpoint with a Bearer token. No DB
    connection required. See `exec_http/2`.
  """

  alias Prodigy.Core.Objects.Store

  def exec(argv, _args \\ %{}) do
    parsed =
      argv
      |> expand_paths()
      |> Enum.map(&parse_one/1)

    {ok, errors} = Enum.split_with(parsed, &match?({:ok, _}, &1))

    case errors do
      [] ->
        commit(Enum.map(ok, fn {:ok, {_path, attrs}} -> attrs end))

      _ ->
        report_parse_errors(errors)
    end
  end

  @doc """
  HTTP-mode import. `args` must carry a `:url` key; `:api_key_file`
  and `:api_key_env` are optional (env var resolution falls back to
  `PRODIGY_API_KEY`).
  """
  def exec_http(argv, args) do
    paths = expand_paths(argv)

    case paths do
      [] ->
        IO.puts("- No files matched.")

      _ ->
        IO.puts("- Uploading #{length(paths)} file(s)...")

        with {:ok, key} <- resolve_api_key(args),
             {:ok, body} <- build_tar_gz(paths) do
          post_upload(args.url, key, body, Map.get(args, :insecure, false))
        else
          {:error, reason} ->
            IO.puts(:stderr, "! #{reason}")
            System.halt(1)
        end
    end
  end

  @doc false
  # Expand a list of argv paths into a flat list of regular-file
  # paths. Supports:
  #   * globs (`foo/*.pgm`)
  #   * plain files
  #   * directory args - all regular files directly under the dir
  # This is the shape the user's workflow needs: they can pass one
  # directory and have tens of thousands of files land in the tar,
  # rather than relying on shell glob expansion (which blows past
  # ARG_MAX around ~2k files on macOS).
  def expand_paths(argv) do
    argv
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(fn p ->
      cond do
        File.dir?(p) ->
          p
          |> File.ls!()
          |> Enum.map(&Path.join(p, &1))
          |> Enum.filter(&File.regular?/1)

        File.regular?(p) ->
          [p]

        true ->
          []
      end
    end)
  end

  # --- HTTP mode -----------------------------------------------------

  @doc false
  # Exposed for testing. Resolution order: --api-key-file ->
  # --api-key-env -> PRODIGY_API_KEY env var -> error.
  def resolve_api_key(args) do
    cond do
      path = Map.get(args, :api_key_file) ->
        case File.read(path) do
          {:ok, contents} -> {:ok, String.trim(contents)}
          {:error, reason} -> {:error, "cannot read --api-key-file #{path}: #{inspect(reason)}"}
        end

      var = Map.get(args, :api_key_env) ->
        case System.get_env(var) do
          nil -> {:error, "env var #{var} is not set"}
          "" -> {:error, "env var #{var} is empty"}
          val -> {:ok, val}
        end

      val = System.get_env("PRODIGY_API_KEY") ->
        if val == "", do: {:error, "PRODIGY_API_KEY is empty"}, else: {:ok, val}

      true ->
        {:error,
         "no API key - pass --api-key-file <path>, --api-key-env <var>, or set PRODIGY_API_KEY"}
    end
  end

  @doc false
  # Exposed for testing; walks `paths` -> in-memory tar.gz.
  def build_tar_gz(paths) do
    tmp = Path.join(System.tmp_dir!(), "podbutil-#{System.unique_integer([:positive])}.tar")

    try do
      {:ok, tar} = :erl_tar.open(String.to_charlist(tmp), [:write])

      Enum.each(paths, fn path ->
        bytes = File.read!(path)
        :ok = :erl_tar.add(tar, bytes, String.to_charlist(Path.basename(path)), [])
      end)

      :ok = :erl_tar.close(tar)

      {:ok, :zlib.gzip(File.read!(tmp))}
    rescue
      e -> {:error, "could not build tar.gz: #{Exception.message(e)}"}
    after
      File.rm(tmp)
    end
  end

  defp post_upload(base_url, api_key, body, insecure?) do
    :inets.start()
    :ssl.start()

    url = String.to_charlist(URI.merge(base_url, "/api/v1/objects/upload") |> URI.to_string())

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)}
    ]

    req = {url, headers, ~c"application/gzip", body}

    case :httpc.request(:post, req, http_opts(insecure?), []) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        report_http_result(status, List.to_string(resp_body))

      {:error, reason} ->
        IO.puts(:stderr, "! HTTP request failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp http_opts(insecure?) do
    base = [timeout: 300_000, connect_timeout: 30_000]

    if insecure? do
      # Dev-only escape hatch: Caddy's local internal CA isn't in the
      # host trust store; :httpc otherwise rejects the cert.
      base ++ [ssl: [verify: :verify_none]]
    else
      base
    end
  end

  defp report_http_result(status, body) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"counts" => c} = decoded} ->
        IO.puts(
          "- Uploaded: #{Map.get(c, "inserted", 0)} new, " <>
            "#{Map.get(c, "bumped", 0)} bumped, " <>
            "#{Map.get(c, "unchanged", 0)} unchanged"
        )

        if decoded["keyword_index_rebuilt"] do
          IO.puts("  Keyword index rebuilt.")
        end

      _ ->
        IO.puts("- Upload succeeded. Raw response: #{body}")
    end
  end

  defp report_http_result(status, body) do
    IO.puts(:stderr, "! Server returned HTTP #{status}: #{body}")
    System.halt(1)
  end

  # --- Local mode ----------------------------------------------------

  defp parse_one(path) do
    with {:ok, blob} <- File.read(path),
         {:ok, attrs} <- Store.parse_import_blob(blob) do
      {:ok, {path, attrs}}
    else
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp commit([]) do
    IO.puts("- No objects matched.")
  end

  defp commit(parsed) do
    # podbutil runs against the canonical ProdigyReloaded/objects dump
    # for initial seed and periodic refresh; that dataset has real-world
    # keyword collisions (multiple PTOs claiming "DIRECTORY", etc.).
    # :skip preserves whichever object currently owns the keyword and
    # lands the new object without a keyword row, with the collision
    # surfaced on stderr so the admin can reconcile later.
    case Store.insert_or_bump(parsed, on_keyword_collision: :skip) do
      {:ok, %{inserted: ins, bumped: bumped, unchanged: un, skipped_keywords: sk}} ->
        IO.puts(
          "- Imported: #{length(ins)} new, #{length(bumped)} bumped, #{length(un)} unchanged"
        )

        if bumped != [] do
          IO.puts("  Bumped:")

          for row <- Enum.take(bumped, 10) do
            IO.puts(
              "    #{String.trim(row.name)} v#{row.previous_version} -> v#{row.version}"
            )
          end

          if length(bumped) > 10, do: IO.puts("    + #{length(bumped) - 10} more")
        end

        if sk != [] do
          IO.puts(:stderr, "  #{length(sk)} keyword claim(s) skipped (already owned):")

          for row <- Enum.take(sk, 20) do
            IO.puts(
              :stderr,
              "    \"#{row.keyword}\" kept by #{row.owner_obj_id}; #{row.new_obj_id} did not claim it."
            )
          end

          if length(sk) > 20, do: IO.puts(:stderr, "    + #{length(sk) - 20} more")
        end

      {:error, {:object_insert_failed, name, errors}} ->
        IO.puts(:stderr, "! Failed to insert #{String.trim(name)}: #{inspect(errors)}")
        IO.puts(:stderr, "  Nothing was inserted.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "! Import failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp report_parse_errors(errors) do
    IO.puts(:stderr, "! Couldn't parse #{length(errors)} file(s); nothing was inserted.")

    for {:error, {path, reason}} <- Enum.take(errors, 10) do
      IO.puts(:stderr, "  #{path} (#{inspect(reason)})")
    end

    if length(errors) > 10, do: IO.puts(:stderr, "  + #{length(errors) - 10} more")

    System.halt(1)
  end
end
