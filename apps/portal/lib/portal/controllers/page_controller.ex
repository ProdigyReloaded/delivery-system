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

defmodule Prodigy.Portal.PageController do
  use Prodigy.Portal, :controller

  def home(conn, _params) do
    conn
    |> assign(:page, :home)
    |> assign(:page_title, "Prodigy Reloaded")
    |> render(:home)
  end

  def faq(conn, _params) do
    conn
    |> assign(:page, :faq)
    |> assign(:page_title, "Frequently Asked Questions")
    |> render(:faq)
  end

  def history(conn, _params) do
    conn
    |> assign(:page, :history)
    |> assign(:page_title, "History")
    |> render(:history)
  end

  def start(conn, _params) do
    # Pop the signup wizard's one-shot password stash. The sidebar LiveView
    # reads this via its session arg at mount and owns visibility from
    # there; removing it from the session means a refresh shows the
    # "Forgot password?" path rather than the plaintext again - the
    # user can always reroll for another.
    #
    # Multi-account shape: %{service_user_id => password}. Empty/nil =
    # nothing to show. The sidebar reads it once and tracks visibility
    # per-account thereafter.
    fresh_passwords = Plug.Conn.get_session(conn, :fresh_passwords) || %{}

    conn
    |> maybe_delete_fresh_passwords(fresh_passwords)
    |> assign(:page, :start)
    |> assign(:page_title, "Prodigy Reloaded")
    |> assign(:extra_css, :rs)
    |> assign(:body_class, "mx-0 mx-sm-1 px-0 px-sm-1")
    |> assign(:fresh_passwords, fresh_passwords)
    |> render(:start)
  end

  defp maybe_delete_fresh_passwords(conn, fp) when fp == %{}, do: conn

  defp maybe_delete_fresh_passwords(conn, _),
    do: Plug.Conn.delete_session(conn, :fresh_passwords)

  @doc """
  Entry point for the "Want your own account?" flow. Routes authenticated
  visitors straight to `/signup`; sends unauthenticated visitors through
  log-in with a friendly flash (the `:require_authenticated_user` plug's
  default flash reads as an error, which is wrong for onboarding).
  """
  def get_started(conn, _params) do
    case conn.assigns[:current_scope] do
      %{user: %Prodigy.Core.Data.Portal.User{}} ->
        redirect(conn, to: ~p"/signup")

      _ ->
        conn
        |> Plug.Conn.put_session(:user_return_to, ~p"/signup")
        |> put_flash(
          :info,
          "Login or sign up to create your Prodigy account. We'll bring you back here when you're done."
        )
        |> redirect(to: ~p"/users/login")
    end
  end

  @doc """
  Receives the form POST from the signup wizard's reveal step. The LiveView
  can't write the Plug session directly, so the reveal step submits a
  tiny form carrying just the password (user_id always comes from the
  DB), and this action stashes it and redirects to /start. The sidebar
  shows it once; `signup_dismiss/2` clears it, after which /start shows
  a "Forgot password?" button that reruns `signup_forgot/2` to reroll.
  """
  def signup_done(conn, %{"password" => password, "user_id" => user_id})
      when is_binary(password) and is_binary(user_id) do
    # Stash the freshly-revealed password keyed by service-user id so the
    # /start sidebar can show it under the right account card. The map
    # form coexists with multi-account: a later signup_done call merges
    # into it instead of overwriting.
    conn
    |> Plug.Conn.put_session(
      :fresh_passwords,
      Map.put(Plug.Conn.get_session(conn, :fresh_passwords) || %{}, user_id, password)
    )
    |> redirect(to: ~p"/start")
  end

  def signup_done(conn, _), do: redirect(conn, to: ~p"/start")

end
