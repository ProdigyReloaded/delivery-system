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

defmodule Prodigy.Core.Data.Repo.Migrations.AddInvitationTokenSupport do
  use Ecto.Migration

  # Unified auth flow needs two new token contexts:
  #
  #   * "signup_invitation" - carries an email (via sent_to) with no
  #     portal_user row yet. Clicking the confirm link creates the
  #     user and logs them in; clicking the dismiss link deletes the
  #     token and blacklists the email.
  #
  #   * "provider_link_invitation" - carries an existing user_id plus
  #     a provider identity {provider, uid} pending link, via a new
  #     `data` jsonb column. Replaces the in-session password-confirm
  #     flow at /users/link, which was an enumeration oracle.
  #
  # Two schema changes to the existing portal_users_tokens table:
  #
  #   * user_id becomes nullable (signup invitations have no user).
  #   * new `data` jsonb column for invitation-specific payload.

  def change do
    alter table(:portal_users_tokens) do
      modify :user_id, references(:portal_users, on_delete: :delete_all),
        null: true,
        from: {references(:portal_users, on_delete: :delete_all), null: false}

      add :data, :map
    end
  end
end
