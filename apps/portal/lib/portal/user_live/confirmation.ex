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

defmodule Prodigy.Portal.UserLive.Confirmation do
  @moduledoc """
  Landing page for magic-link clicks. Resolves the token to a portal
  user, shows a friendly confirmation step, and - on submit - hands
  the token + remember_me payload off to `UserSessionController`
  which does the actual session creation.

  We keep an explicit click step (instead of auto-consuming the
  token on GET) so opening the link in a link-preview bot or an
  email-security-scanner's pre-fetcher doesn't burn the token.
  """
  use Prodigy.Portal, :live_view

  alias Prodigy.Portal.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card>
        <div class="text-center mb-3">
          <h1 class="h3 mb-2">
            <%= if @user.confirmed_at do %>
              Welcome back
            <% else %>
              Welcome to Prodigy Reloaded
            <% end %>
          </h1>
          <p class="text-muted mb-0">
            Signing in as <strong>{@user.email}</strong>
          </p>
        </div>

        <.form
          for={@form}
          id="confirmation_form"
          phx-submit="submit"
          action={confirmation_action(@user)}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />

          <div :if={!@current_scope} class="form-check mb-3">
            <input
              class="form-check-input"
              type="checkbox"
              id="confirmation_remember_me"
              name={@form[:remember_me].name}
              value="true"
            />
            <label class="form-check-label" for="confirmation_remember_me">
              Stay logged in on this device
            </label>
          </div>

          <button type="submit" class="btn btn-primary w-100" phx-disable-with="Logging in...">
            <%= if @user.confirmed_at, do: "Login", else: "Confirm and Login" %>
          </button>
        </.form>

        <p :if={!@user.confirmed_at} class="text-muted small mt-3 mb-0 text-center">
          You can set a password later from the Settings page.
        </p>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/login")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end

  defp confirmation_action(%{confirmed_at: nil}), do: ~p"/users/login?_action=confirmed"
  defp confirmation_action(_), do: ~p"/users/login"
end
