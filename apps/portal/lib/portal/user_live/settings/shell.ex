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

defmodule Prodigy.Portal.UserLive.Settings.Shell do
  @moduledoc """
  Shared chrome for the `/users/settings` + `/users/settings/api-keys`
  LiveViews: left rail with General / API-keys nav, page header, and
  a content slot. Each settings LiveView wraps its body in `<.shell active=...>`
  so the chrome lives in exactly one place.
  """
  use Phoenix.Component

  alias Prodigy.Portal.Authz

  attr :active, :atom, required: true, doc: "one of :general, :api_keys"
  attr :current_scope, :any, required: true
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :title, pane_title(assigns.active))

    ~H"""
    <Prodigy.Portal.Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="admin-shell d-flex">
        <aside class="admin-sidebar border-end pe-3 me-3" style="min-width: 140px;">
          <ul class="nav flex-column">
            <li class="nav-item">
              <.link
                navigate="/users/settings"
                class={link_class(@active == :general)}
              >
                General
              </.link>
            </li>
            <li :if={Authz.can?(@current_scope, :api_keys, :self)} class="nav-item">
              <.link
                navigate="/users/settings/api-keys"
                class={link_class(@active == :api_keys)}
              >
                API keys
              </.link>
            </li>
          </ul>
        </aside>

        <section class="admin-content flex-grow-1">
          <header class="mb-3 pb-2 border-bottom">
            <h1 class="h3 mb-0">{@title}</h1>
          </header>

          {render_slot(@inner_block)}
        </section>
      </div>
    </Prodigy.Portal.Layouts.app>
    """
  end

  defp link_class(true), do: "nav-link active fw-semibold"
  defp link_class(false), do: "nav-link text-body-secondary"

  defp pane_title(:api_keys), do: "API keys"
  defp pane_title(_), do: "Account settings"
end
