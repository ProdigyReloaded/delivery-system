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

defmodule Prodigy.Core.Data.Repo.Migrations.CreatePortalUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:portal_users) do
      add :email, :citext, null: false
      add :hashed_password, :string
      add :confirmed_at, :naive_datetime

      timestamps()
    end

    create unique_index(:portal_users, [:email])

    create table(:portal_users_tokens) do
      add :user_id, references(:portal_users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :naive_datetime

      timestamps(updated_at: false)
    end

    create index(:portal_users_tokens, [:user_id])
    create unique_index(:portal_users_tokens, [:context, :token])
  end
end
