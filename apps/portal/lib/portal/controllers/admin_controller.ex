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

defmodule Prodigy.Portal.AdminController do
  @moduledoc """
  Landing page for `/admin`. Redirects to the first admin surface
  the caller has scope to see (Online, Users, Objects, Keywords, ...),
  or home with a flash if they hold no admin scopes at all.
  """
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.AdminLive.Layouts

  def index(conn, _params) do
    case Layouts.default_path_for(conn.assigns[:current_scope]) do
      nil ->
        conn
        |> put_flash(:error, "You don't have access to the admin area.")
        |> redirect(to: ~p"/")

      path ->
        redirect(conn, to: path)
    end
  end
end
