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

defmodule Prodigy.Portal.AuthController do
  @moduledoc """
  Handles Ueberauth callbacks for Google / GitHub (and later other providers).
  The `:request` action is handled by the Ueberauth plug itself, which
  redirects to the provider. The `:callback` action resolves the provider
  identity against the portal user table and either:

    * logs the user in (identity already linked), or
    * emails a provider-link invitation (email matches an existing portal
      user under a different provider), or
    * emails a signup invitation with the provider identity pre-attached
      to the token (brand-new email).

  All three outbound cases (other than the immediate log-in) surface the
  same uniform "Check your inbox" response so the response doesn't leak
  whether the email is registered.
  """
  use Prodigy.Portal, :controller

  plug Ueberauth

  alias Prodigy.Portal.Accounts
  alias Prodigy.Portal.UserAuth

  def request(conn, _params) do
    # Ueberauth intercepts before this runs. Reaching here means the provider
    # name in the URL isn't one we've configured.
    conn
    |> put_flash(:error, "Unknown authentication provider.")
    |> redirect(to: ~p"/users/login")
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    msg =
      failure.errors
      |> Enum.map_join(", ", & &1.message)

    conn
    |> put_flash(:error, "Authentication failed: #{msg}")
    |> redirect(to: ~p"/users/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    email = auth.info.email
    provider = auth.provider
    uid = to_string(auth.uid)

    cond do
      is_nil(email) ->
        conn
        |> put_flash(
          :error,
          "The #{provider} account didn't share an email address; can't create a portal account from it."
        )
        |> redirect(to: ~p"/users/login")

      current_user(conn) ->
        # Already signed in - this is a "link another provider" request
        # from the Settings page, not a login.
        link_to_current_user(conn, provider, uid)

      true ->
        handle_oauth_callback(conn, provider, uid, email)
    end
  end

  defp handle_oauth_callback(conn, provider, uid, email) do
    invite_code = Plug.Conn.get_session(conn, :pending_invite_code)

    case Accounts.process_oauth_callback(provider, uid, email, invite_code: invite_code) do
      {:logged_in, user} ->
        # Clear the invite from session whether we used it or not - once
        # the user has an account, the pending-invite slot is done its
        # job. Either it was redeemed (invitation-only mode) or it was
        # ignored (open mode / re-auth).
        conn
        |> Plug.Conn.delete_session(:pending_invite_code)
        |> UserAuth.log_in_user(user, %{})

      :invite_required ->
        # Invitation-only mode + new email + no valid pending invite.
        # No portal user was created; bounce them to the invite-required
        # page where they can paste a code (or contact someone who can
        # send them one).
        conn
        |> Plug.Conn.delete_session(:pending_invite_code)
        |> put_flash(
          :error,
          "Sign-up is currently invite-only. Enter your invitation code to continue."
        )
        |> redirect(to: ~p"/users/invite/required")

      :blocked ->
        conn
        |> put_flash(:error, "Authentication failed.")
        |> redirect(to: ~p"/users/login")
    end
  end

  defp current_user(conn) do
    case conn.assigns do
      %{current_scope: %{user: user}} when not is_nil(user) -> user
      _ -> nil
    end
  end

  defp link_to_current_user(conn, provider, uid) do
    user = current_user(conn)

    case Accounts.link_identity_to_user(user, provider, uid) do
      {:ok, %Prodigy.Core.Data.Portal.Identity{}} ->
        # First-time link - fresh identity row, also rotate the session
        # token so the add-a-provider flow counts as a re-auth for
        # sudo mode.
        conn
        |> Phoenix.Controller.clear_flash()
        |> put_flash(:info, "Linked #{provider} to your account.")
        |> UserAuth.log_in_user(user, %{})

      {:ok, :already_linked} ->
        # The provider identity was already on this account - typically
        # means the user is bouncing off the sudo-mode gate on
        # /users/settings. Treat it as a re-authentication: rotate the
        # session token (fresh authenticated_at) so sudo mode refreshes
        # instead of looping through the log-in page forever.
        conn
        |> Phoenix.Controller.clear_flash()
        |> put_flash(:info, "Re-authenticated via #{provider}.")
        |> UserAuth.log_in_user(user, %{})

      {:error, :taken_by_another_user} ->
        conn
        |> put_flash(
          :error,
          "That #{provider} account is already linked to a different portal user."
        )
        |> redirect(to: ~p"/users/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Could not link #{provider}: #{inspect_changeset_errors(changeset)}")
        |> redirect(to: ~p"/users/settings")
    end
  end

  defp inspect_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end
end
