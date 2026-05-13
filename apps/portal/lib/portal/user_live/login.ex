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

defmodule Prodigy.Portal.UserLive.Login do
  @moduledoc """
  Unified entry point for `/users/login`. One email field; on submit
  the backend either emails a magic-link login (existing user) or a
  signup-invitation with a wasn't-me escape hatch (new email). The
  UI response is the same in either case so nothing about the form
  reveals whether the email is registered.

  A discreet "Already have a password?" link toggles a separate
  password form that POSTs to `UserSessionController` - the only
  affordance differing from a first-time visitor is the one the
  user themselves clicked, so there's no server-side oracle.

  OAuth buttons sit below in a uniform order (no per-user
  personalisation). The Mock button only appears when
  `:portal, :dev_routes` is true.
  """
  use Prodigy.Portal, :live_view

  alias Prodigy.Portal.Accounts
  alias Prodigy.Portal.Invites
  alias Prodigy.Portal.Settings

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card
        title={if @current_scope && @current_scope.user, do: "Re-authenticate", else: "Login or Sign Up"}
        subtitle={
          cond do
            @current_scope && @current_scope.user ->
              "Confirm it's you to continue with sensitive actions on your account."

            mail_disabled?() ->
              "Sign in with GitHub to continue."

            true ->
              "We'll email you a link. If you don't have an account, one will be created when you click it."
          end
        }
      >
        <div :if={local_mail_adapter?()} class="alert alert-info small mb-3">
              Dev mode: view sent mail at
              <.link href="/dev/mailbox" class="alert-link">/dev/mailbox</.link>.
            </div>

            <div :if={@pending_invite} class="alert alert-success small mb-3">
              You have been invited to join Prodigy Reloaded. Sign in below to claim
              your account.
            </div>

            <div
              :if={@invitation_only? and is_nil(@pending_invite) and is_nil(@current_scope && @current_scope.user)}
              class="card border-info mb-3"
            >
              <div class="card-body">
                <h6 class="card-title">First time here?</h6>
                <p class="small text-muted mb-2">
                  Sign-up is invite-only. If you have an invitation code, paste
                  it below to continue. Already have an account? Use one of the
                  sign-in buttons below as usual.
                </p>
                <form action={~p"/users/invite/submit"} method="post" class="d-flex gap-2 mb-0">
                  <input
                    type="hidden"
                    name="_csrf_token"
                    value={Plug.CSRFProtection.get_csrf_token()}
                  />
                  <input
                    type="text"
                    name="code"
                    class="form-control form-control-sm font-monospace"
                    placeholder="invitation code"
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <button type="submit" class="btn btn-sm btn-primary">Continue</button>
                </form>
              </div>
            </div>

            <%= if @sent_to do %>
              <div class="alert alert-success mb-3" id="login_form_sent_state">
                <p class="mb-1"><strong>We sent a link to {@sent_to}.</strong></p>
                <p class="mb-0 small">
                  Check your inbox to continue. The link is valid for 15 minutes.
                  If you don't see it, check spam.
                </p>
              </div>
              <p class="text-center small mb-0">
                <.link phx-click="reset" class="text-muted">Use a different email</.link>
              </p>
            <% else %>
              <%= unless mail_disabled?() do %>
              <.form
                :let={f}
                for={@form}
                id="login_form"
                action={~p"/users/login"}
                phx-change="validate"
                phx-submit="submit_form"
                phx-trigger-action={@trigger_submit}
              >
                <.input
                  readonly={!!(@current_scope && @current_scope.user)}
                  field={f[:email]}
                  type="email"
                  label="Email"
                  autocomplete="username"
                  spellcheck="false"
                  required
                  phx-mounted={JS.focus()}
                />

                <div :if={@password_mode}>
                  <.input
                    field={@form[:password]}
                    type="password"
                    label="Password"
                    autocomplete="current-password"
                    spellcheck="false"
                    required
                  />
                  <div class="form-check mb-3">
                    <input
                      class="form-check-input"
                      type="checkbox"
                      id="login_form_remember_me"
                      name="user[remember_me]"
                      value="true"
                    />
                    <label class="form-check-label" for="login_form_remember_me">
                      Stay logged in on this device
                    </label>
                  </div>
                </div>

                <button type="submit" class="btn btn-primary w-100">
                  {if @password_mode, do: "Login", else: "Continue"}
                </button>
              </.form>

              <p class="text-center small mt-3 mb-0">
                <%= if @password_mode do %>
                  <.link phx-click="use_magic_link">Email me a link instead</.link>
                <% else %>
                  <.link phx-click="use_password">Already have a password?</.link>
                <% end %>
              </p>
              <% end %>

              <div :if={@oauth_providers != [] or @dev_mock?}>
                <div :if={not mail_disabled?()} class="d-flex align-items-center my-3">
                  <hr class="flex-grow-1 my-0" />
                  <span class="mx-2 small text-muted">or</span>
                  <hr class="flex-grow-1 my-0" />
                </div>
                <div class="d-grid gap-2">
                  <a
                    :for={{provider_id, label} <- @oauth_providers}
                    href={~p"/auth/#{Atom.to_string(provider_id)}"}
                    class="btn btn-outline-secondary"
                  >
                    Continue with {label}
                  </a>
                  <a :if={@dev_mock?} href="/dev/mock-login" class="btn btn-outline-warning">
                    Mock (dev only)
                  </a>
                </div>
              </div>
        <% end %>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")
    sent_to = Phoenix.Flash.get(socket.assigns.flash, :login_sent_to)

    pending_invite =
      case session["pending_invite_code"] do
        code when is_binary(code) -> Invites.get_by_code(code)
        _ -> nil
      end

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       password_mode: false,
       sent_to: sent_to,
       oauth_providers: Prodigy.Portal.available_oauth_providers(),
       dev_mock?: Application.get_env(:portal, :dev_routes) == true,
       invitation_only?: Settings.invitation_only?(),
       pending_invite: pending_invite
     )}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    # No real validation here - this event exists so the server knows
    # what the user has typed across re-renders. Without it, any
    # `assign`-driven re-render would emit `value=""` and clobber the
    # input the user just typed into.
    {:noreply, assign(socket, :form, to_form(params, as: "user"))}
  end

  def handle_event("use_password", _params, socket) do
    {:noreply, assign(socket, :password_mode, true)}
  end

  def handle_event("use_magic_link", _params, socket) do
    {:noreply, assign(socket, :password_mode, false)}
  end

  def handle_event("reset", _params, socket) do
    form = to_form(%{"email" => nil}, as: "user")
    {:noreply, assign(socket, sent_to: nil, password_mode: false, form: form)}
  end

  def handle_event("submit_form", params, socket) do
    if socket.assigns.password_mode do
      # Hand the form off to the classic POST /users/login endpoint -
      # UserSessionController.create matches on email+password and
      # writes the session + remember_me cookie.
      {:noreply, assign(socket, :trigger_submit, true)}
    else
      %{"user" => %{"email" => email}} = params
      normalized = email |> to_string() |> String.trim()

      :ok =
        Accounts.request_access(normalized,
          login: &url(~p"/users/login/#{&1}"),
          confirm: &url(~p"/users/confirm/#{&1}"),
          dismiss: &url(~p"/users/dismiss/#{&1}")
        )

      {:noreply, assign(socket, sent_to: display_email(normalized))}
    end
  end

  defp display_email(""), do: "your address"
  defp display_email(email), do: email

  defp local_mail_adapter? do
    Application.get_env(:portal, Prodigy.Portal.Mailer)[:adapter] == Swoosh.Adapters.Local and
      Application.get_env(:portal, :dev_routes, false)
  end

  # Email-based signup/signin is hidden when the only configured mail adapter
  # is Local AND /dev/mailbox isn't reachable - i.e. there is no way for an
  # email link to actually arrive. The login page falls back to OAuth-only.
  defp mail_disabled? do
    Application.get_env(:portal, Prodigy.Portal.Mailer)[:adapter] == Swoosh.Adapters.Local and
      not Application.get_env(:portal, :dev_routes, false)
  end
end
