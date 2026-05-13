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

defmodule Prodigy.Core.Data.Repo.Migrations.SplitPortalUsersIntoIdentities do
  use Ecto.Migration

  def change do
    create table(:portal_identities) do
      add :user_id, references(:portal_users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_uid, :string
      add :hashed_password, :string

      timestamps()
    end

    create index(:portal_identities, [:user_id])

    # A provider+uid pair uniquely identifies a social login.
    create unique_index(:portal_identities, [:provider, :provider_uid],
             where: "provider_uid IS NOT NULL",
             name: :portal_identities_provider_provider_uid_index
           )

    # At most one :identity (email+password) identity per user - can't end up
    # with two passwords for the same account.
    create unique_index(:portal_identities, [:user_id],
             where: "provider = 'identity'",
             name: :portal_identities_one_identity_per_user_index
           )

    # Copy existing auth methods from portal_users. Captures :identity rows
    # (email+password users), OAuth rows (none yet in production), and :mock
    # rows (dev). Rows with no auth method at all are skipped - they
    # shouldn't exist but won't break anything if present.
    execute """
            INSERT INTO portal_identities (user_id, provider, provider_uid, hashed_password, inserted_at, updated_at)
            SELECT id, provider, provider_uid, hashed_password, inserted_at, updated_at
              FROM portal_users
             WHERE provider = 'identity' OR provider_uid IS NOT NULL
            """,
            """
            TRUNCATE TABLE portal_identities
            """

    # The provider/provider_uid/hashed_password columns on portal_users are
    # superseded; portal_users is now a thin identity-neutral profile.
    drop_if_exists unique_index(:portal_users, [:provider, :provider_uid],
                     name: :portal_users_provider_provider_uid_index
                   )

    alter table(:portal_users) do
      remove :hashed_password, :string
      remove :provider, :string, null: false, default: "identity"
      remove :provider_uid, :string
    end
  end
end
