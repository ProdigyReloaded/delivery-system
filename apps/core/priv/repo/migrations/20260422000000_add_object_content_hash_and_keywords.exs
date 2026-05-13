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

defmodule Prodigy.Core.Data.Repo.Migrations.AddObjectContentHashAndKeywords do
  use Ecto.Migration

  @moduledoc """
  Add the schema needed for content-compare + auto-bump + keyword
  indexing in the object upload pipeline:

  * `object.content_hash` - SHA-256 of the canonicalized object blob
    (version bits zeroed). Indexed so "same content?" lookups don't
    scan the table. Nullable at first so the backfill migration can
    populate it row-by-row; made NOT NULL in 20260422000100.
  * `keyword` table - one row per unique keyword. Primary key is the
    keyword text itself; the row points at the (name, sequence, type)
    of the object it navigates to. Version is deliberately NOT stored
    - keywords target the logical object, not a specific version.
    No FK to `object` because the four-part composite PK doesn't
    match our three-part pointer; application-level consistency.
  """

  def change do
    alter table(:object) do
      add(:content_hash, :binary)
    end

    create(index(:object, [:content_hash]))

    create table(:keyword, primary_key: false) do
      add(:keyword, :string, size: 13, primary_key: true)
      add(:object_name, :string, size: 11, null: false)
      add(:object_sequence, :integer, null: false)
      add(:object_type, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:keyword, [:object_name, :object_sequence, :object_type]))
  end
end
