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

defmodule Prodigy.Portal.MockAuthController do
  @moduledoc """
  Dev-only controller that stands in for a real OAuth provider. It shows a
  tiny form where you pick any email to sign in as, then calls the normal
  `Accounts.get_or_create_user_by_provider/3` + `UserAuth.log_in_user/3`
  path with `provider: :mock`. Bypasses Ueberauth's CSRF state machinery
  since we don't need an external provider.

  Reachable only when `PHX_DEV_ROUTES=true` (the route is inside the `/dev`
  scope). Every action re-checks that flag so even if the route is wired
  in a release without dev_routes, the controller refuses.
  """

  use Prodigy.Portal, :controller

  alias Prodigy.Portal.Accounts
  alias Prodigy.Portal.UserAuth

  plug :require_dev_mode

  def new(conn, _params) do
    html = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8" />
      <title>Mock sign-in (dev only)</title>
      <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.5/dist/css/bootstrap.min.css" rel="stylesheet" />
    </head>
    <body class="p-5">
      <div class="container" style="max-width: 480px;">
        <h1 class="h3">Mock sign-in</h1>
        <p class="text-muted">Dev-only. Pick any email to sign in as that identity.</p>
        <form method="post" action="/dev/mock-login">
          <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}" />
          <div class="mb-3">
            <label class="form-label" for="email">Email</label>
            <input id="email" class="form-control" type="email" name="email" value="dev@example.com" required />
          </div>
          <button class="btn btn-primary" type="submit">Sign in</button>
        </form>
      </div>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  def create(conn, %{"email" => email}) when is_binary(email) and email != "" do
    case current_user(conn) do
      nil ->
        handle_anonymous_mock_login(conn, email)

      user ->
        # Already signed in: this is a link-another-provider click from Settings.
        case Accounts.link_identity_to_user(user, :mock, "mock:" <> email) do
          {:ok, %Prodigy.Core.Data.Portal.Identity{}} ->
            conn
            |> put_flash(:info, "Linked the mock identity for #{email} to your account.")
            |> redirect(to: ~p"/users/settings")

          {:ok, :already_linked} ->
            conn
            |> put_flash(:info, "That mock identity was already linked to your account.")
            |> redirect(to: ~p"/users/settings")

          {:error, :taken_by_another_user} ->
            conn
            |> put_flash(
              :error,
              "That mock identity is already linked to a different portal user."
            )
            |> redirect(to: ~p"/users/settings")

          {:error, changeset} ->
            conn
            |> put_flash(:error, "Could not link: #{inspect(changeset.errors)}")
            |> redirect(to: ~p"/users/settings")
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Mock sign-in needs an email.")
    |> redirect(to: ~p"/dev/mock-login")
  end

  defp handle_anonymous_mock_login(conn, email) do
    case Accounts.process_oauth_callback(:mock, "mock:" <> email, email) do
      {:logged_in, user} ->
        UserAuth.log_in_user(conn, user, %{})

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

  defp require_dev_mode(conn, _opts) do
    if Application.get_env(:portal, :dev_routes) == true do
      conn
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
