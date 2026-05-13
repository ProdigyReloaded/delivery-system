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

defmodule Prodigy.Core.Data.Repo.Migrations.CreatePortalApiKeys do
  use Ecto.Migration

  def change do
    create table(:portal_api_keys) do
      add :user_id, references(:portal_users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # First 8 chars of the plaintext key (e.g., "pk_abcde"), shown in
      # lists so the user can identify a key without us storing the
      # secret. The real authentication check hashes the full submitted
      # token and compares byte-for-byte against :key_hash.
      add :key_prefix, :string, null: false
      # SHA-256 of the plaintext key. 32 bytes. We don't use bcrypt/pbkdf2
      # because the keys are 128 bits of CSPRNG entropy - a SHA-256
      # preimage search is as expensive as brute-forcing the key itself.
      add :key_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:portal_api_keys, [:user_id])
    create unique_index(:portal_api_keys, [:key_hash])
    # Prefix lookups let the verify plug narrow candidates to a single
    # row (or occasionally two on an 8-char collision) before the
    # constant-time hash compare.
    create index(:portal_api_keys, [:key_prefix])
  end
end
