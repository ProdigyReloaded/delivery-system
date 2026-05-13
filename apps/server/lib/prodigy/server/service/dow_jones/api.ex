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

defmodule Prodigy.Server.Service.DowJones.Api do
  @moduledoc """
  Thin HTTP client to the Dow Jones API sidecar service that runs
  alongside us in docker-compose. The sidecar is a small Python
  process that handles the upstream cookie + crumb handshake over
  curl_cffi. Reproducing that handshake purely in Elixir + HTTPoison
  is impractical, so we offload to a small Python service and stay
  HTTP-clients-only on this side.

  The sidecar's `/quote/<symbol>` endpoint returns a fixed JSON
  shape so the caller's decoder
  (`Prodigy.Server.Service.DowJones.decode_quote/1`) is unchanged.
  """
  require Logger

  # Reachable on the docker-compose network. Override via env for
  # tests / local dev that runs the sidecar differently.
  @sidecar_url System.get_env("DOWJONES_API_URL") || "http://dowjones-sidecar:8000"

  # The sidecar is fast on cache-hits, slower (1-3s) on cache-misses
  # while it does the cookie dance. 10s is comfortably above its
  # worst case but bounded enough that a wedged sidecar doesn't tie
  # up the per-connection handler indefinitely.
  @http_timeout_ms 10_000

  @doc """
  Fetches a quote for `symbol`. The `_fields` arg is accepted for
  call-site compatibility with the previous incarnation of this
  module - the sidecar always returns the same canonical field
  set, and the caller only consumes what it needs from the JSON.

  Returns `{:ok, {symbol, json_string}}` on success, `{:error, reason}`
  otherwise.
  """
  def custom_quote(symbol, _fields) when is_binary(symbol) do
    sym = String.trim(symbol)
    Logger.info("DowJones API: custom_quote(#{sym}) via sidecar")

    url = "#{@sidecar_url}/quote/#{URI.encode(sym)}"

    case HTTPoison.get(url, [{"Accept", "application/json"}], recv_timeout: @http_timeout_ms) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Logger.info("DowJones API: custom_quote(#{sym}) ok")
        {:ok, {sym, body}}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        Logger.warning("DowJones API: custom_quote(#{sym}) -> not found")
        {:error, :not_found}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        Logger.warning(
          "DowJones API: custom_quote(#{sym}) -> HTTP #{code}: #{String.slice(body, 0, 200)}"
        )

        {:error, {:sidecar_status, code}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning(
          "DowJones API: custom_quote(#{sym}) -> transport error: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
