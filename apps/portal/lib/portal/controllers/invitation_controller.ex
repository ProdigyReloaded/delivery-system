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

defmodule Prodigy.Portal.InvitationController do
  @moduledoc """
  Handles the confirm + dismiss round-trip for the invitation tokens
  minted by the unified auth flow. Two contexts:

    * `:signup_invitation` - new email. Confirming creates the
      portal user, attaches any provider identity the token
      carried (OAuth-seeded signup), marks the user confirmed,
      and logs them in.
    * `:provider_link_invitation` - existing user, new provider.
      Confirming attaches the provider identity to the user and
      logs them in.

  Dismissing either kind of token runs through `dismiss_invitation/1`
  in `Prodigy.Portal.Accounts`: the token is deleted, the email is
  blacklisted for 30 days with reason `"wasnt_me"`, and a uniform
  "request cancelled" landing page is shown. The landing page is
  deliberately the same regardless of whether the token was valid -
  an expired or forged token produces the same page so nothing leaks
  about token validity.
  """
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.Accounts
  alias Prodigy.Portal.UserAuth

  def confirm(conn, %{"token" => token}) when is_binary(token) do
    case Accounts.consume_signup_invitation(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome! Your account is ready.")
        |> UserAuth.log_in_user(user, %{})

      {:error, :invalid} ->
        case Accounts.consume_provider_link_invitation(token) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "Linked the account.")
            |> UserAuth.log_in_user(user, %{})

          {:error, :invalid} ->
            render_invalid_page(conn)
        end
    end
  end

  def dismiss(conn, %{"token" => token}) when is_binary(token) do
    :ok = Accounts.dismiss_invitation(token)
    render_dismissed_page(conn)
  end

  defp render_invalid_page(conn) do
    html = landing_page("Link expired or invalid", """
    <p>This link is no longer valid. Invitation links expire 15 minutes
    after they're sent.</p>

    <p>If you still want to sign in or create an account, start again
    from the <a href="/users/login">login page</a>.</p>
    """)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp render_dismissed_page(conn) do
    html = landing_page("Request cancelled", """
    <p>OK. We've cancelled that request and won't email this address
    again for 30 days.</p>

    <p>If you keep getting messages like this, reply to the original
    email to get in touch.</p>
    """)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp landing_page(title, body_html) do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>#{title} - Prodigy Reloaded</title>
      <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.5/dist/css/bootstrap.min.css" rel="stylesheet" />
    </head>
    <body class="p-5">
      <div class="container" style="max-width: 520px;">
        <h1 class="h3">#{title}</h1>
        #{body_html}
      </div>
    </body>
    </html>
    """
  end
end
