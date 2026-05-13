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

defmodule Prodigy.Portal.AdminLive.Portal.Settings do
  @moduledoc """
  `/admin/portal/settings` - system-level settings panel. The only
  setting today is `invitation_only`, which gates new portal-user
  creation behind an invite code (see `Prodigy.Portal.Settings` for
  the storage layer and the invitation controllers for the flow).

  Future settings rows append here as their toggle wiring lands; the
  underlying `portal_settings` key/value store is generic, so the LiveView
  is the only place that needs to grow per setting.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :system, :settings}}

  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, invitation_only?: Settings.invitation_only?())}
  end

  @impl true
  def handle_event("toggle_invitation_only", params, socket) do
    actor_id = socket.assigns.current_scope.user.id
    new_value = params["value"] == "on"

    {:ok, _} = Settings.put(actor_id, "invitation_only", new_value)

    {:noreply,
     socket
     |> assign(:invitation_only?, new_value)
     |> put_flash(:info, "Invitation-only mode #{if new_value, do: "enabled", else: "disabled"}.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.wrapper
      active={:portal_settings}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Settings"
    >
      <p class="text-muted small">
        System-wide settings. Changes write to the audit log and take effect
        immediately for any sign-in attempt that arrives after the toggle.
      </p>

      <table class="table table-sm align-middle">
        <thead>
          <tr>
            <th style="width: 40%">Setting</th>
            <th>Description</th>
            <th class="text-end" style="width: 100px">Value</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>Invitation-only mode</strong></td>
            <td class="text-muted small">
              When enabled, new portal-user creation requires a valid invitation
              code. Existing portal users sign in normally regardless of this
              setting. Invites are issued by other portal users out of their
              <code>invite_quota</code> (see Portal Users), or directly by an
              admin.
            </td>
            <td class="text-end">
              <div class="form-check form-switch d-inline-block mb-0">
                <input
                  type="checkbox"
                  class="form-check-input"
                  id="invitation-only-toggle"
                  name="value"
                  checked={@invitation_only?}
                  phx-click="toggle_invitation_only"
                  phx-value-value={if @invitation_only?, do: "off", else: "on"}
                />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.wrapper>
    """
  end
end
