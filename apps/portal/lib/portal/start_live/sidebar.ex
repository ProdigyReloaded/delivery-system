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

defmodule Prodigy.Portal.StartLive.Sidebar do
  @moduledoc """
  Right-column sidebar on /start. Three top-level states:

    * `:anonymous` / `:no_account` - demo advertising + "Get started"
      CTA for portal users without an active service account.
    * `:has_account` - one card per linked service user, each showing
      the user id and either the current password (if the session
      stash is fresh from the signup wizard or a forgot-password
      reroll) or a "Forgot password?" button. The header carries an
      "add an account" `+` affordance when the portal user's
      service_user_quota allows another account (count < quota and
      quota > 1).

  Embedded via `live_render` from the /start controller template so
  clicks (dismiss, forgot-password) don't navigate the host page and
  reload DOSBox. The controller pops a session `:fresh_passwords`
  stash on each /start load - the signup wizard's commit form writes
  it; the LiveView reads it once via the session arg and owns visibility
  from there.

  Multi-account password visibility rule: when ANY service user under
  this portal user authenticates via TCS, all freshly-shown passwords
  are dismissed at once. A portal user juggling several accounts only
  needs to log in once for the page to stop displaying secrets.
  """
  use Prodigy.Portal, :live_view

  import Ecto.Query

  alias Prodigy.Core.Data.Portal
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.User, as: ServiceUser
  alias Prodigy.Portal.SignupIds
  alias Prodigy.Server.SessionManager

  on_mount {Prodigy.Portal.UserAuth, :mount_current_scope}

  @impl true
  def mount(_params, session, socket) do
    fresh_passwords = session["fresh_passwords"] || %{}
    portal_user = socket.assigns[:current_scope] && socket.assigns.current_scope.user
    {state, service_users} = account_state(portal_user)

    if connected?(socket) and service_users != [] do
      # Listen for service-logon events so a successful TCS auth on
      # ANY of this portal user's accounts dismisses all displayed
      # passwords (the user clearly doesn't need to see them anymore).
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, SessionManager.topic())
    end

    {:ok,
     socket
     |> assign(
       account_state: state,
       portal_user: portal_user,
       service_users: service_users,
       fresh_passwords: fresh_passwords,
       editing_password_for: nil,
       custom_password_errors: %{},
       demo_available?: demo_user_active?()
     ),
     layout: false}
  end

  @impl true
  def handle_info({:service_user_authenticated, user_id}, socket) do
    if Enum.any?(socket.assigns.service_users, &(&1.id == user_id)) do
      # Any account under this portal user just authenticated - clear
      # every shown password rather than only the one that signed in.
      {:noreply, assign(socket, :fresh_passwords, %{})}
    else
      # Logon belongs to some other portal user - ignore.
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("dismiss", %{"user-id" => user_id}, socket) do
    {:noreply,
     assign(socket, :fresh_passwords, Map.delete(socket.assigns.fresh_passwords, user_id))}
  end

  def handle_event("forgot", %{"user-id" => user_id}, socket) do
    case find_service_user(socket, user_id) do
      nil ->
        {:noreply, socket}

      service_user ->
        new_password = SignupIds.generate_password()

        case service_user
             |> ServiceUser.changeset(%{password: new_password})
             |> Repo.update() do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(
               :fresh_passwords,
               Map.put(socket.assigns.fresh_passwords, user_id, new_password)
             )
             |> assign(:editing_password_for, nil)
             |> assign(:custom_password_errors, %{})}

          {:error, _changeset} ->
            {:noreply,
             Phoenix.LiveView.put_flash(
               socket,
               :error,
               "Couldn't reset the password. Please try again."
             )}
        end
    end
  end

  def handle_event("edit_password", %{"user-id" => user_id}, socket) do
    if Map.has_key?(socket.assigns.fresh_passwords, user_id) do
      {:noreply,
       socket
       |> assign(:editing_password_for, user_id)
       |> assign(
         :custom_password_errors,
         Map.delete(socket.assigns.custom_password_errors, user_id)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_password", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_password_for, nil)
     |> assign(:custom_password_errors, %{})}
  end

  def handle_event("save_password", %{"user-id" => user_id, "password" => raw}, socket) do
    normalized = raw |> to_string() |> String.trim() |> String.upcase()

    cond do
      normalized == "" ->
        # Blank (user clicked, didn't type, blurred) -> cancel back to
        # the generated password.
        {:noreply,
         socket
         |> assign(:editing_password_for, nil)
         |> assign(
           :custom_password_errors,
           Map.delete(socket.assigns.custom_password_errors, user_id)
         )}

      not String.match?(normalized, ~r/^[A-Z0-9]{2,10}$/) ->
        {:noreply,
         assign(
           socket,
           :custom_password_errors,
           Map.put(socket.assigns.custom_password_errors, user_id, :invalid)
         )}

      true ->
        case find_service_user(socket, user_id) do
          nil ->
            {:noreply, socket}

          service_user ->
            case service_user
                 |> ServiceUser.changeset(%{password: normalized})
                 |> Repo.update() do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> assign(
                   :fresh_passwords,
                   Map.put(socket.assigns.fresh_passwords, user_id, normalized)
                 )
                 |> assign(:editing_password_for, nil)
                 |> assign(
                   :custom_password_errors,
                   Map.delete(socket.assigns.custom_password_errors, user_id)
                 )}

              {:error, _changeset} ->
                {:noreply,
                 assign(
                   socket,
                   :custom_password_errors,
                   Map.put(socket.assigns.custom_password_errors, user_id, :save_failed)
                 )}
            end
        end
    end
  end

  # ------------------------------------------------------------------

  defp find_service_user(socket, user_id) do
    Enum.find(socket.assigns.service_users, &(&1.id == user_id))
  end

  defp account_state(%Portal.User{id: portal_user_id}) do
    today = Date.utc_today()

    users =
      from(u in ServiceUser,
        where: u.portal_user_id == ^portal_user_id,
        where: is_nil(u.date_deleted) or u.date_deleted > ^today,
        order_by: [asc: u.id]
      )
      |> Repo.all()

    case users do
      [] -> {:no_account, []}
      _ -> {:has_account, users}
    end
  end

  defp account_state(_), do: {:anonymous, []}

  # The "Want to just try it?" panel pitches DEMO99A / SECRET as a
  # try-before-signup. Only show it when that account is actually
  # provisioned and not soft-deleted - otherwise we'd be sending
  # would-be users to credentials that bounce them off the logon
  # screen.
  defp demo_user_active? do
    today = Date.utc_today()

    Repo.exists?(
      from u in ServiceUser,
        where: u.id == "DEMO99A",
        where: is_nil(u.date_deleted) or u.date_deleted > ^today
    )
  end

  defp can_add_account?(%Portal.User{service_user_quota: quota}, count)
       when is_integer(quota) and quota > 1 and count < quota,
       do: true

  defp can_add_account?(_, _), do: false

  defp enrolment_state(%ServiceUser{date_enrolled: nil}), do: :unenrolled
  defp enrolment_state(_), do: :enrolled

  @impl true
  def render(assigns) do
    ~H"""
    <div id="start-sidebar">
      <%= case @account_state do %>
        <% :has_account -> %>
          <aside class="start-notice alert alert-info mb-0" role="note">
            <div class="d-flex align-items-center mb-2">
              <h2 class="h5 mb-0 flex-grow-1">Your Prodigy account<%= if length(@service_users) > 1 do %>s<% end %></h2>
              <a
                :if={can_add_account?(@portal_user, length(@service_users))}
                href={~p"/signup"}
                class="btn btn-sm btn-outline-primary"
                aria-label="add an account"
                title="Add another Prodigy account"
              >
                +
              </a>
            </div>

            <%= for service_user <- @service_users do %>
              {account_card(assign(assigns, :service_user, service_user))}
            <% end %>
          </aside>
        <% _ -> %>
          <aside class="start-notice alert alert-info mb-0" role="note">
            <%= if @demo_available? do %>
              <h2 class="h5 mb-2">Want to just try it?</h2>
              <p class="mb-2">
                Sign in with<br />
                ID <code>DEMO99A</code><br />
                password <code>SECRET</code>
              </p>
              <p class="small text-muted mb-2">
                The Demo User can do most things, but there are some limitations.
                <button
                  type="button"
                  class="border-0 bg-transparent p-0 align-baseline shadow-none"
                  style="line-height: 1; color: #084298;"
                  data-bs-toggle="popover"
                  data-bs-trigger="hover focus"
                  data-bs-placement="right"
                  data-bs-html="true"
                  data-bs-title="Demo account limits"
                  data-bs-content="Nothing the Demo User does is saved across sessions. Messages you compose aren't delivered; replies you post to a board aren't shown to anyone else. Profile edits, preference changes, and game state also won't stick."
                  aria-label="About the demo account"
                >
                  <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="currentColor" viewBox="0 0 16 16" aria-hidden="true">
                    <path d="M8 16A8 8 0 1 0 8 0a8 8 0 0 0 0 16m.93-9.412-1 4.705c-.07.34.029.533.304.533.194 0 .487-.07.686-.246l-.088.416c-.287.346-.92.598-1.465.598-.703 0-1.002-.422-.808-1.319l.738-3.468c.064-.293.006-.399-.287-.47l-.451-.081.082-.381 2.29-.287zM8 5.5a1 1 0 1 1 0-2 1 1 0 0 1 0 2"/>
                  </svg>
                </button>
              </p>

              <hr class="my-3" />
            <% end %>

            <h2 class="h6 mb-2">Want your own account?</h2>
            <p class="small text-muted mb-2">
              Set up your own Prodigy user id, a personal inbox, and
              preferences that stick. Takes a minute.
            </p>
            <a href={~p"/get-started"} class="btn btn-primary btn-sm">
              Get started
            </a>
          </aside>
      <% end %>
    </div>
    """
  end

  # Single-account sub-card. Renders user id + password area for one
  # service_user. Multiple may render side-by-side under "Your Prodigy
  # accounts" when the portal user has more than one.
  defp account_card(assigns) do
    fresh_password = Map.get(assigns.fresh_passwords, assigns.service_user.id)
    error = Map.get(assigns.custom_password_errors, assigns.service_user.id)
    editing? = assigns.editing_password_for == assigns.service_user.id
    state = enrolment_state(assigns.service_user)

    assigns =
      assign(assigns,
        fresh_password: fresh_password,
        custom_password_error: error,
        editing_password?: editing?,
        enrolment_state: state
      )

    ~H"""
    <div class="account-card border rounded p-2 mb-2 bg-white">
      <p :if={@enrolment_state == :unenrolled} class="small text-muted mb-2">
        Sign on with these - you'll finish enrolling (name, etc.)
        from the DOS client on first connection.
      </p>

      <div class="mb-2">
        <div class="small text-muted">User id</div>
        <code class="fs-5">{@service_user.id}</code>
      </div>

      <%= if @fresh_password do %>
        <div class="mb-2">
          <div class="small text-muted">Password</div>
          <%= if @editing_password? do %>
            <input
              id={"sidebar-password-input-" <> @service_user.id}
              type="text"
              name="password"
              value=""
              maxlength="10"
              autocomplete="off"
              autocapitalize="characters"
              spellcheck="false"
              class={[
                "form-control font-monospace text-center fs-4 text-uppercase",
                @custom_password_error && "is-invalid"
              ]}
              phx-hook="SidebarPasswordEdit"
              data-user-id={@service_user.id}
              placeholder="2-10 A-Z / 0-9"
            />
            <div :if={@custom_password_error == :invalid} class="invalid-feedback d-block">
              2-10 letters or digits only.
            </div>
            <div :if={@custom_password_error == :save_failed} class="invalid-feedback d-block">
              Couldn't save - try again.
            </div>
          <% else %>
            <button
              type="button"
              class="sidebar-password-display w-100 btn btn-outline-secondary font-monospace text-center fs-4"
              phx-click="edit_password"
              phx-value-user-id={@service_user.id}
              title="Click to set your own password"
            >
              {@fresh_password}
            </button>
          <% end %>
        </div>
        <p class="small text-muted mb-2">
          Your new password is above. Store it safely as it will be
          hidden when you logon.
        </p>
        <p class="small text-muted mb-2">
          Or, if you prefer your own password, click the one shown to
          change as desired.
        </p>
        <button
          type="button"
          class="border-0 bg-transparent p-0 small text-muted shadow-none text-decoration-underline"
          phx-click="dismiss"
          phx-value-user-id={@service_user.id}
        >
          Dismiss
        </button>
      <% else %>
        <button
          type="button"
          class="btn btn-outline-primary btn-sm"
          phx-click="forgot"
          phx-value-user-id={@service_user.id}
        >
          Reset password
        </button>
      <% end %>
    </div>
    """
  end
end
