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

defmodule Prodigy.Portal.Accounts.UserNotifier do
  import Swoosh.Email

  alias Prodigy.Portal.Mailer
  alias Prodigy.Core.Data.Portal.User

  # Delivers the email using the application mailer. From-address
  # comes from `:portal, :mail_from` config - a `{name, address}`
  # tuple or bare address string. Dev default is a stub; prod
  # overrides via the MAIL_FROM env var in config/runtime.exs.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(mail_from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp mail_from do
    Application.get_env(:portal, :mail_from, {"Prodigy Reloaded", "contact@example.com"})
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Login instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver a signup invitation: no account exists yet. `confirm_url`
  creates the account on click; `dismiss_url` (the "wasn't me"
  escape hatch) deletes the invitation and blacklists the address.
  """
  def deliver_signup_invitation(email, confirm_url, dismiss_url)
      when is_binary(email) and is_binary(confirm_url) and is_binary(dismiss_url) do
    deliver(email, "Confirm your Prodigy Reloaded account", """

    ==============================

    Someone - hopefully you - asked to sign up for Prodigy Reloaded
    using this email address.

    To finish creating your account, visit:

    #{confirm_url}

    This link expires in 15 minutes. No account will be created
    unless you click the link above.

    If this wasn't you, let us know and we'll stop sending invites
    to this address:

    #{dismiss_url}

    ==============================
    """)
  end

  @doc """
  Deliver a provider-link invitation: an account already exists
  for this email and someone tried to sign in via a different
  OAuth provider. `confirm_url` attaches the new provider to the
  existing account; `dismiss_url` is the "wasn't me" escape hatch.
  The `provider_label` is a human-readable name (e.g. "Google",
  "GitHub") used in the body copy.
  """
  def deliver_provider_link_invitation(email, provider_label, confirm_url, dismiss_url)
      when is_binary(email) and is_binary(provider_label) and
             is_binary(confirm_url) and is_binary(dismiss_url) do
    deliver(email, "Link your #{provider_label} account?", """

    ==============================

    Someone - hopefully you - tried to sign in to Prodigy Reloaded
    with #{provider_label} using this email address, which already
    has an account.

    To link #{provider_label} to your existing account, visit:

    #{confirm_url}

    This link expires in 15 minutes. Nothing will be linked unless
    you click the link above.

    If this wasn't you, let us know and we'll stop sending these
    requests to this address:

    #{dismiss_url}

    ==============================
    """)
  end
end
