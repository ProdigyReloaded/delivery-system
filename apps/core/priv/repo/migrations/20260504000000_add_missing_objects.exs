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

defmodule Prodigy.Core.Data.Repo.Migrations.AddMissingObjects do
  use Ecto.Migration

  def change do
    create table(:missing_objects, primary_key: false) do
      add :name, :string, size: 11, null: false, primary_key: true
      add :sequence, :integer, null: false, primary_key: true
      add :type, :integer, null: false, primary_key: true

      add :first_seen, :utc_datetime, null: false
      add :last_seen, :utc_datetime, null: false
      add :last_user_id, :string
      add :last_session_id, references(:session, on_delete: :nilify_all)
      add :hit_count, :integer, null: false, default: 1
    end

    # Read pattern is "top hits" / "most recently seen", so cover both
    # default sort columns. Filtering on name is substring; the PK
    # already covers exact-name lookups so no extra index there.
    create index(:missing_objects, [:hit_count])
    create index(:missing_objects, [:last_seen])
  end
end
