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

defmodule Prodigy.Core.Data.Repo.Migrations.CreateDataCollectionEvents do
  use Ecto.Migration

  # One row per parsed record from the RS client's data-collection
  # stream (DIA dest 0x00D200, payload prefix 0x04). Two kinds today:
  # `"object"` rows carry `(object_name, sequence, type)` and the
  # elapsed time the user spent on that object; `"function"` rows
  # carry a function-class code + elapsed time. Both share the
  # `session_id` + `user_id` + duration columns so queries filter
  # uniformly.
  def change do
    create table(:data_collection_event) do
      add :session_id, references(:session, on_delete: :nilify_all)
      add :user_id, :string, null: false
      add :kind, :string, null: false

      # object-kind fields; null on function rows
      add :object_name, :string
      add :object_sequence, :integer
      add :object_type, :integer
      add :record_type, :integer

      # function-kind fields; null on object rows
      add :function_class, :integer

      # common to both
      add :duration_seconds, :integer, null: false

      # original binary of the record, for debug / decoder updates
      add :raw_record, :binary

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:data_collection_event, [:user_id])
    create index(:data_collection_event, [:session_id])
    create index(:data_collection_event, [:inserted_at])
    create index(:data_collection_event, [:kind])
  end
end
