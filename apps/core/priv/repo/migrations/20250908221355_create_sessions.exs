# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Core.Data.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:session) do
      add :user_id, references(:user, type: :string, on_delete: :nothing), null: false
      add :logon_timestamp, :utc_datetime, null: false
      add :logon_status, :integer, null: false  # 0=success, 1=enroll_other, 2=enroll_subscriber
      add :logoff_timestamp, :utc_datetime
      add :logoff_status, :integer  # 0=normal, 1=abnormal, 2=timeout, 3=forced
      add :rs_version, :string
      add :node, :string, null: false
      add :pid, :string, null: false
      add :source_address, :string
      add :source_port, :integer
      add :last_activity_at, :utc_datetime

      timestamps()
    end

    create index(:session, [:user_id])
    create index(:session, [:logoff_timestamp])
    create index(:session, [:node])

    # Add concurrency_limit to users
    alter table(:user) do
      add :concurrency_limit, :integer, default: 1
    end

    # Remove logged_on from users (or keep it temporarily for rollback safety)
    alter table(:user) do
      remove :logged_on
    end
  end
end
