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

defmodule Prodigy.Portal.AdminLive.Users.ResetPasswordModal do
  @moduledoc """
  Modal owning the admin "Reset password for AAAAxxA" flow. The parent
  `AdminLive.Users` opens this LiveComponent by rendering it with a
  `user` assign; on save the LC commits the reset and messages the
  parent with `{:reset_password_saved, user, plaintext}` so the parent
  can flash + close. Cancellation sends `:close_modal`.

  The generated password is produced on first mount and regenerated
  on demand via the `↻` button; the admin can also type a custom
  value (validated against the 2-10 char alphanumeric rule the RS
  client enforces on next logon).
  """
  use Prodigy.Portal, :live_component

  alias Prodigy.Portal.Admin.Users, as: Admin

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(%{user: user} = assigns, socket) do
    # First update seeds the suggested password; subsequent updates
    # (re-opened modal for a different user) re-seed.
    password =
      cond do
        Map.get(socket.assigns, :user) == user and socket.assigns[:password] not in [nil, ""] ->
          socket.assigns.password

        true ->
          Admin.generate_password()
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:password, password)}
  end

  @impl true
  def handle_event("changed", %{"password" => pw}, socket) do
    {:noreply, assign(socket, :password, pw)}
  end

  def handle_event("regenerate", _params, socket) do
    {:noreply, assign(socket, :password, Admin.generate_password())}
  end

  def handle_event("save", %{"password" => pw}, socket) do
    case Admin.reset_password(socket.assigns.user, pw) do
      {:ok, user} ->
        send(self(), {:reset_password_saved, user, pw})
        {:noreply, socket}

      {:error, :invalid_password} ->
        send(
          self(),
          {:modal_flash, :error, "Password must be 2-10 characters, letters and digits only."}
        )

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset.errors
          |> Enum.map(fn {field, {m, _}} -> "#{field} #{m}" end)
          |> Enum.join("; ")

        send(self(), {:modal_flash, :error, "Couldn't reset: #{msg}"})
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id={@id <> "-modal"}
        show
        title={"Reset password for #{@user.id}"}
        on_cancel={JS.push("close_modal")}
      >
        <form
          id={@id <> "-form"}
          phx-change="changed"
          phx-submit="save"
          phx-target={@myself}
        >
          <p class="text-muted small">
            The new password takes effect on the next logon.
            Existing sessions continue until they disconnect.
            Prodigy passwords are 2-10 characters, letters and digits only;
            input is uppercased before storing to match the DOS client.
          </p>
          <div class="mb-3">
            <label for={@id <> "-pw"} class="form-label">New password</label>
            <div class="input-group">
              <input
                id={@id <> "-pw"}
                type="text"
                name="password"
                class="form-control font-monospace text-uppercase"
                value={@password}
                pattern="[A-Za-z0-9]{2,10}"
                maxlength="10"
                required
              />
              <button
                type="button"
                class="btn btn-outline-secondary"
                phx-click="regenerate"
                phx-target={@myself}
                title="Generate another"
              >
                ↻
              </button>
            </div>
          </div>
        </form>
        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_modal">
            Cancel
          </button>
          <button type="submit" form={@id <> "-form"} class="btn btn-primary">
            Reset password
          </button>
        </:footer>
      </.modal>
    </div>
    """
  end
end
