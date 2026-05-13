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

defmodule Prodigy.Portal.UserLive.Settings do
  @moduledoc """
  `/users/settings` - General pane: email change, password set, and
  the linked-sign-in-methods list (OAuth + password). Sudo-mode gated
  at the router.

  API keys are served by `Prodigy.Portal.UserLive.Settings.ApiKeys`
  at `/users/settings/api-keys` with its own `:api_keys, :self` scope
  gate; both LVs wrap their body in
  `Prodigy.Portal.UserLive.Settings.Shell`.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, :require_sudo_mode}

  import Prodigy.Portal.UserLive.Settings.Shell

  alias Prodigy.Portal.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:general} current_scope={@current_scope} flash={@flash}>
      <.auth_panel title="Email" class="mb-4">
        <.form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
        >
          <.input
            field={@email_form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.button phx-disable-with="Changing...">Change Email</.button>
        </.form>
      </.auth_panel>

      <.auth_panel title="Password" class="mb-4">
        <.form
          for={@password_form}
          id="password_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
        >
          <input
            name={@password_form[:email].name}
            type="hidden"
            id="hidden_user_email"
            spellcheck="false"
            value={@current_email}
          />
          <.input
            field={@password_form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
            spellcheck="false"
          />
          <.button phx-disable-with="Saving...">Save Password</.button>
        </.form>
      </.auth_panel>

      <.auth_panel
        title="Linked sign-in methods"
        subtitle="Any of these can be used to sign in. You can't remove your last remaining method - add another first."
        class="mb-4"
      >
        <ul class="list-group">
          <li
            :for={identity <- @identities}
            class="list-group-item d-flex justify-content-between align-items-center"
          >
            <div>
              <strong>{provider_label(identity.provider)}</strong>
              <span :if={identity.provider_uid} class="text-muted ms-2">
                - {identity.provider_uid}
              </span>
            </div>
            <button
              :if={length(@identities) > 1}
              type="button"
              class="btn btn-sm btn-outline-danger"
              phx-click="unlink_identity"
              phx-value-id={identity.id}
              data-confirm={"Remove #{provider_label(identity.provider)} sign-in from this account?"}
            >
              Remove
            </button>
          </li>
        </ul>

        <div :if={@link_options != []} class="mt-3">
          <h3 class="h6 text-muted">Add another sign-in method</h3>
          <div class="d-grid gap-2">
            <a
              :for={{provider_id, label, href} <- @link_options}
              href={href}
              class={"btn btn-outline-secondary" <> if(provider_id == :mock, do: " btn-outline-warning", else: "")}
            >
              Link {label}
            </a>
          </div>
        </div>
      </.auth_panel>
    </.shell>
    """
  end

  defp provider_label(:identity), do: "Email + password"
  defp provider_label(:google), do: "Google"
  defp provider_label(:github), do: "GitHub"
  defp provider_label(:mock), do: "Mock (dev)"
  defp provider_label(other) when is_atom(other), do: Atom.to_string(other)

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    {:ok,
     socket
     |> assign(:current_email, user.email)
     |> assign(:email_form, to_form(email_changeset))
     |> assign(:password_form, to_form(password_changeset, as: :user))
     |> assign(:trigger_submit, false)
     |> assign_identity_state()}
  end

  defp assign_identity_state(socket) do
    user = socket.assigns.current_scope.user
    identities = Accounts.list_identities(user)

    already_linked = MapSet.new(identities, & &1.provider)

    real_oauth_options =
      Prodigy.Portal.available_oauth_providers()
      |> Enum.reject(fn {id, _label} -> MapSet.member?(already_linked, id) end)
      |> Enum.map(fn {id, label} -> {id, label, "/auth/#{id}"} end)

    link_options =
      if Application.get_env(:portal, :dev_routes) == true and
           not MapSet.member?(already_linked, :mock) do
        real_oauth_options ++ [{:mock, "Mock (dev only)", "/dev/mock-login"}]
      else
        real_oauth_options
      end

    socket
    |> assign(:identities, identities)
    |> assign(:link_options, link_options)
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, put_flash(socket, :info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form(as: :user)

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply,
         assign(socket, trigger_submit: true, password_form: to_form(changeset, as: :user))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert, as: :user))}
    end
  end

  def handle_event("unlink_identity", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    {id_int, _} = Integer.parse(id)

    case Accounts.unlink_identity(user, id_int) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Removed sign-in method.")
         |> assign_identity_state()}

      {:error, :last_identity} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That's your only remaining sign-in method - add another first."
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Not found.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't remove that sign-in method.")}
    end
  end
end
