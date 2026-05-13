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

defmodule Prodigy.Portal.InviteController do
  @moduledoc """
  Invite-flow plain controller endpoints. Stays separate from
  UserLive.Login because LVs can't write to the conn session - every
  invite-stash transition has to bounce through here so the cookie
  session record can be updated.

  Actions:

    * `land/2` - `GET /users/invite/:code`. The "click an invite URL"
      landing. Validates + stashes the code in session, redirects to
      `/users/login` with a flash banner.
    * `submit/2` - `POST /users/invite/submit`. The "I have a code,
      let me type it" path used both by the invite-required page and
      by the invite-only login page's prompt. Same validate-and-stash
      semantics; failure routes back to invite-required with a flash.
    * `required/2` - `GET /users/invite/required`. The landing page
      OAuth bounces to when invitation-only mode is on but no valid
      invite was in session.
    * `new/2` - `GET /users/invite/new`. Authenticated-only. Mints
      a fresh invite for the current portal user (consuming a slot
      out of their `invite_quota`) and renders the share page with
      the one-time URL + bare code + copy-to-clipboard.
  """
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.Invites
  alias Prodigy.Portal.Settings

  # GET /users/invite/:code - visitor lands via a shared invitation URL.
  def land(conn, %{"code" => code}) do
    stash_and_redirect(conn, code)
  end

  # POST /users/invite/submit - visitor pasted a code into a form.
  def submit(conn, %{"code" => code}) when is_binary(code) do
    stash_and_redirect(conn, String.trim(code))
  end

  def submit(conn, _params) do
    conn
    |> put_flash(:error, "Please enter your invitation code.")
    |> redirect(to: ~p"/users/invite/required")
  end

  defp stash_and_redirect(conn, code) do
    case Invites.get_by_code(code) do
      nil ->
        conn
        |> put_flash(:error, "That invitation code isn't valid.")
        |> redirect(to: ~p"/users/invite/required")

      invite ->
        if Invites.redeemable?(invite) do
          conn
          |> Plug.Conn.put_session(:pending_invite_code, invite.code)
          |> put_flash(:info, "Invitation accepted - sign in below to claim your account.")
          |> redirect(to: ~p"/users/login")
        else
          conn
          |> put_flash(:error, "That invitation has already been used or revoked.")
          |> redirect(to: ~p"/users/invite/required")
        end
    end
  end

  # GET /users/invite/required - terminal landing for OAuth-without-invite
  # in invitation-only mode, plus the "manually enter your code" surface
  # for visitors who lost the URL.
  def required(conn, _params) do
    conn
    |> assign(:page_title, "Invitation required")
    |> render(:required)
  end

  # GET/POST /users/invite/new - authenticated; mints + reveals an
  # invite. Lives in the unauthenticated route scope so its path
  # ordering vs the dynamic `/users/invite/:code` is stable; the
  # action itself enforces auth.
  #
  # Content negotiation: `Accept: application/json` returns
  # `{"url": ..., "code": ...}` so a JS modal in the navbar can mint
  # without navigating away from /start (which would tear down the
  # DOSBox session). HTML accept renders the share page as a
  # full-page fallback for non-JS contexts.
  def new(conn, _params) do
    user = conn.assigns[:current_scope] && conn.assigns.current_scope.user

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, "Sign in to issue invitations.")
        |> redirect(to: ~p"/users/login")

      not Settings.invitation_only?() ->
        respond(conn, :error, "The system isn't in invitation-only mode; no invite needed.")

      Invites.available(user) <= 0 ->
        respond(
          conn,
          :error,
          "You don't have any invitations available. Ask an admin to bump your invite quota."
        )

      true ->
        case Invites.mint(user) do
          {:ok, invite} ->
            url =
              Phoenix.VerifiedRoutes.url(
                Prodigy.Portal.Endpoint,
                ~p"/users/invite/#{invite.code}"
              )

            if json_request?(conn) do
              json(conn, %{url: url, code: invite.code})
            else
              conn
              |> assign(:invite, invite)
              |> assign(:invite_url, url)
              |> assign(:page_title, "Invitation issued")
              |> render(:new)
            end

          {:error, :over_quota} ->
            respond(conn, :error, "You're at your invite quota.")

          {:error, _changeset} ->
            respond(conn, :error, "Couldn't generate an invitation. Try again.")
        end
    end
  end

  defp respond(conn, kind, message) do
    if json_request?(conn) do
      conn
      |> put_status(if kind == :error, do: 422, else: 200)
      |> json(%{error: message})
    else
      conn
      |> put_flash(kind, message)
      |> redirect(to: ~p"/start")
    end
  end

  defp json_request?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> String.contains?(accept, "application/json")
      _ -> false
    end
  end
end
