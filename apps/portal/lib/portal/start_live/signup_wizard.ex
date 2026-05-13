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

defmodule Prodigy.Portal.StartLive.SignupWizard do
  @moduledoc """
  Full-page wizard that provisions a Prodigy service account (7-char
  user id + password) for a signed-in portal user. Gated at the router
  by `:require_authenticated_user` + `on_mount :require_authenticated`,
  so unauthenticated visitors never reach the LiveView - they get stashed
  into the log-in round-trip and come back here after.

  Steps:

    * `:choose` - "randomly assign me one" vs "I'll pick my own."
    * `:pick`   - random preview OR 6-char input with inline validation.
    * `:reveal` - display the assigned id + password as plain text.
      The snap-pack reveal animation is a possible future polish.

  On `:reveal`'s "I've got it" button, the wizard commits the household
  via `Enroller.create_subscriber` (already committed at :pick -> :reveal
  transition) and redirects to `/start` so the user can sign in with
  their fresh credentials.
  """
  use Prodigy.Portal, :live_view

  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Enroller
  alias Prodigy.Core.Data.Service.User, as: ServiceUser
  alias Prodigy.Portal.SignupIds

  @impl true
  def mount(_params, _session, socket) do
    portal_user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if portal_user && account_count(portal_user.id) >= portal_user.service_user_quota do
      # Defence in depth: the sidebar hides "+" once the user is at quota,
      # but a determined visitor can navigate to /signup directly. Bounce.
      {:ok,
       socket
       |> Phoenix.LiveView.put_flash(
         :info,
         "You've reached the limit of Prodigy accounts on this portal user."
       )
       |> Phoenix.LiveView.redirect(to: ~p"/start")}
    else
      {:ok,
       assign(socket,
         step: :choose,
         mode: nil,
         # Random path:
         candidate_id: nil,
         # Custom path:
         typed_id: "",
         typed_error: nil,
         # Reveal path (set once Enroller returns):
         committed_user_id: nil,
         committed_password: nil,
         committing?: false
       )}
    end
  end

  defp account_count(portal_user_id) do
    today = Date.utc_today()

    Repo.aggregate(
      from(u in ServiceUser,
        where: u.portal_user_id == ^portal_user_id,
        where: is_nil(u.date_deleted) or u.date_deleted > ^today
      ),
      :count
    )
  end

  # --- choose step -------------------------------------------------

  @impl true
  def handle_event("choose", %{"mode" => "random"}, socket) do
    case SignupIds.generate() do
      {:ok, household_id} ->
        {:noreply,
         assign(socket,
           step: :pick,
           mode: :random,
           candidate_id: household_id,
           typed_error: nil
         )}

      {:error, :exhausted} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "We couldn't find a free user id right now - unusual. Please try again."
         )}
    end
  end

  def handle_event("choose", %{"mode" => "custom"}, socket) do
    {:noreply,
     assign(socket,
       step: :pick,
       mode: :custom,
       typed_id: "",
       typed_error: nil
     )}
  end

  # --- pick step: random path --------------------------------------

  def handle_event("regenerate", _params, socket) do
    case SignupIds.generate() do
      {:ok, household_id} ->
        {:noreply, assign(socket, candidate_id: household_id)}

      {:error, :exhausted} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't find another free id - try again.")}
    end
  end

  # --- pick step: custom path --------------------------------------

  def handle_event("validate_typed", %{"household_id" => raw}, socket) do
    normalized = SignupIds.normalize(raw)

    error =
      case SignupIds.validate_custom(normalized, validate_opts(socket)) do
        :ok -> nil
        {:error, reason} -> reason
      end

    {:noreply,
     assign(socket,
       typed_id: normalized,
       typed_error: error
     )}
  end

  # --- pick -> commit ------------------------------------------------

  def handle_event("commit", _params, socket) do
    household_id =
      case socket.assigns.mode do
        :random -> socket.assigns.candidate_id
        :custom -> socket.assigns.typed_id
      end

    # Double-check on commit. The random path already filtered, but a
    # custom id the user last saw as valid could race with a concurrent
    # signup; the Enroller's household-exists check and the uniqueness
    # validation both protect us, but surface the error cleanly here.
    case SignupIds.validate_custom(household_id, validate_opts(socket)) do
      :ok ->
        do_commit(socket, household_id)

      {:error, reason} ->
        {:noreply, assign(socket, typed_error: reason, step: :pick)}
    end
  end

  # Callers holding service_users.any_userid bypass the reserved-prefix
  # list (operator names, call signs, etc). Profanity always refuses.
  defp validate_opts(socket) do
    [bypass_reserved: Prodigy.Portal.Authz.can?(socket.assigns[:current_scope], :service_users, :any_userid)]
  end

  defp do_commit(socket, household_id) do
    password = SignupIds.generate_password()
    portal_user = socket.assigns.current_scope.user

    # Deliberately *not* pre-enrolling - the new subscriber should hit
    # the RS client's enrollment prompts (name, gender, etc.) on first
    # logon so the experience matches what a 1990s Prodigy user got.
    # portal_user_id links the two sides so the admin UI shows the
    # relationship.
    opts = [
      concurrency_limit: 1,
      portal_user_id: portal_user.id
    ]

    case Enroller.create_subscriber(household_id, password, opts) do
      {:ok, {_household, user}} ->
        {:noreply,
         assign(socket,
           step: :reveal,
           committed_user_id: user.id,
           committed_password: password
         )}

      {:error, :household_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, "That id was just taken by someone else. Try another.")
         |> assign(step: :pick, typed_error: :taken)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Couldn't create that account: #{inspect(reason)}"
         )
         |> assign(step: :pick)}
    end
  end

  # --- render ------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="container py-4" style="max-width: 640px;">
        <header class="mb-4">
          <h1 class="h3 mb-1">Create your Prodigy account</h1>
          <p class="text-muted mb-0">
            A few quick steps and you'll have your own 7-character user id
            and password. We'll drop you back at the
            <a href={~p"/start"}>quick-start page</a> when we're done.
          </p>
        </header>

        <div class="card shadow-sm">
          <div class="card-body">
            <%= case @step do %>
              <% :choose -> %>
                {choose_step(assigns)}
              <% :pick -> %>
                {pick_step(assigns)}
              <% :reveal -> %>
                {reveal_step(assigns)}
            <% end %>
          </div>
        </div>

        <div :if={@step != :reveal} class="text-center mt-3">
          <a href={~p"/start"} class="small text-muted">
            Never mind, take me back to the demo
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp choose_step(assigns) do
    ~H"""
    <p class="mb-3">
      How would you like your Prodigy user id assigned?
    </p>

    <div class="d-grid gap-2">
      <button type="button" class="btn btn-primary" phx-click="choose" phx-value-mode="random">
        Pick one for me
      </button>
      <button type="button" class="btn btn-outline-primary" phx-click="choose" phx-value-mode="custom">
        Let me choose
      </button>
    </div>

    <p class="small text-muted mt-3 mb-0">
      Either way you'll end up with something like <code>ABCD12A</code> -
      four letters, two digits, and a trailing <code>A</code> that
      identifies you as the head of a household. Up to five family
      members can be added later.
    </p>
    """
  end

  defp pick_step(%{mode: :random} = assigns) do
    ~H"""
    <p class="mb-3">
      We've picked this one for you. Happy with it, or want another?
    </p>

    <div class="text-center my-4">
      <code class="display-5">{@candidate_id}A</code>
    </div>

    <div class="d-flex gap-2">
      <button type="button" class="btn btn-outline-secondary" phx-click="regenerate">
        Try another
      </button>
      <button type="button" class="btn btn-primary ms-auto" phx-click="commit" disabled={@committing?}>
        Use this id
      </button>
    </div>
    """
  end

  defp pick_step(%{mode: :custom} = assigns) do
    ~H"""
    <p class="mb-3">
      Enter a 6-character household id - four letters followed by two
      digits. We'll add the trailing <code>A</code>.
    </p>

    <form phx-change="validate_typed" phx-submit="commit" autocomplete="off">
      <div class="mb-2">
        <div class="input-group">
          <input
            id="signup-id-input"
            type="text"
            name="household_id"
            value={@typed_id}
            maxlength="6"
            minlength="6"
            pattern="[A-Z]{4}[0-9]{2}"
            class={[
              "form-control font-monospace text-center fs-4",
              @typed_error && "is-invalid"
            ]}
            placeholder="ABCD12"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="150"
            phx-hook="SignupIdMask"
            required
          />
          <span class="input-group-text font-monospace fs-4">A</span>
        </div>
        <div :if={@typed_error} class="invalid-feedback d-block">
          {custom_error_text(@typed_error)}
        </div>
      </div>
      <div class="d-flex gap-2">
        <button
          type="button"
          class="btn btn-outline-secondary"
          phx-click="choose"
          phx-value-mode="random"
        >
          Actually, surprise me
        </button>
        <button
          type="submit"
          class="btn btn-primary ms-auto"
          disabled={@typed_id == "" or @typed_error != nil or @committing?}
        >
          Use this id
        </button>
      </div>
    </form>
    """
  end

  defp reveal_step(assigns) do
    ~H"""
    <div class="text-center">
      <h2 class="h5 mb-3">You're set. Welcome to Prodigy.</h2>
      <p class="text-muted small mb-4">
        Write these down - you'll need both to log on from the DOS client.
      </p>

      <div class="mb-3">
        <div class="small text-muted">User id</div>
        <code class="fs-3">{@committed_user_id}</code>
      </div>

      <div class="mb-4">
        <div class="small text-muted">Password</div>
        <code class="fs-3">{@committed_password}</code>
      </div>

      <form action={~p"/signup/done"} method="post" class="mb-0">
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="hidden" name="password" value={@committed_password} />
        <input type="hidden" name="user_id" value={@committed_user_id} />
        <button type="submit" class="btn btn-primary btn-lg">
          Take me to the sign-on screen
        </button>
      </form>
    </div>
    """
  end

  defp custom_error_text(:bad_format), do: "Use exactly 4 letters followed by 2 digits."
  # Reserved / profanity / taken all collapse to a single generic message -
  # the specific reason shouldn't be disclosed (e.g. telling someone their
  # pick is profane is its own kind of leak).
  defp custom_error_text(_), do: "That id is not available. Try another."
end
