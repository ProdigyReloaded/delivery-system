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

defmodule Prodigy.Portal.AdminObjectController do
  @moduledoc """
  Serves binary downloads of service objects from the admin "Objects" tab.
  Lives here rather than on the LiveView because a `<a href=...>` with a
  dynamic controller response is the cleanest way to deliver a raw blob
  - `consume_uploaded_entries` goes the other direction, and LiveView has no
  primitive for streaming file bodies to the browser.

  Access requires the `objects.view` scope; gated by the plug below.
  The outer router scope has already run `require_authenticated_user`.
  """
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.Admin.Objects
  alias Prodigy.Portal.Authz

  plug :require_objects_view

  defp require_objects_view(conn, _opts) do
    if Authz.can?(conn.assigns[:current_scope], :objects, :view) do
      conn
    else
      conn
      |> put_flash(:error, "You don't have access to that page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  def download(conn, %{
        "name" => name,
        "sequence" => seq_str,
        "type" => type_str,
        "version" => version_str
      }) do
    with {seq, ""} <- Integer.parse(seq_str),
         {type, ""} <- Integer.parse(type_str),
         {version, ""} <- Integer.parse(version_str),
         %{contents: contents} = obj when is_binary(contents) <-
           Objects.get_blob(name, seq, type, version) do
      filename = "#{obj.name}_#{obj.sequence}_#{obj.type}_#{obj.version}"

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, contents)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Object not found.")
    end
  end
end
