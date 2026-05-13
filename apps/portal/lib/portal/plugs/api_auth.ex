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

defmodule Prodigy.Portal.Plugs.ApiAuth do
  @moduledoc """
  Authenticates `/api/v1` requests via a Bearer token in the
  `Authorization` header. On success, assigns `:current_user` and
  `:current_api_key_id` on the conn and asynchronously bumps
  `last_used_at` on the key row. On failure, halts with a 401 JSON
  response.

  Per-endpoint scope gates live in the controllers themselves
  (checking `Prodigy.Portal.Authz.can?/3`). Slice 5c extends this
  with key-scope intersection at verify time.
  """
  import Plug.Conn

  alias Prodigy.Portal.ApiKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    with [bearer] <- get_req_header(conn, "authorization"),
         {:ok, token} <- parse_bearer(bearer),
         {:ok, user, key_id, effective_scopes} <- ApiKeys.verify(token) do
      ApiKeys.touch_async(key_id)

      conn
      |> assign(:current_user, user)
      |> assign(:current_api_key_id, key_id)
      |> assign(:current_api_scopes, effective_scopes)
    else
      _ -> deny(conn, "invalid_api_key")
    end
  end

  defp parse_bearer("Bearer " <> rest) when byte_size(rest) > 0, do: {:ok, rest}
  defp parse_bearer(_), do: :error

  defp deny(conn, reason) do
    body = Phoenix.json_library().encode_to_iodata!(%{error: reason})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
