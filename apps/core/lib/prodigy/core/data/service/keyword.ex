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

defmodule Prodigy.Core.Data.Service.Keyword do
  @moduledoc """
  Schema for the keyword navigation index.

  One row per unique keyword (up to 13 ASCII chars). Each row points
  at the `(name, sequence, type)` of an object - version is
  deliberately *not* stored, because keywords target the logical
  object, not a specific version. When a new version of an object is
  inserted the keyword row is upserted in place.

  No FK to `object`: `object`'s primary key is
  `(name, sequence, type, version)` but the pointer here is only
  three of those columns. The admin upload pipeline enforces
  consistency when it writes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:keyword, :string, []}
  schema "keyword" do
    field(:object_name, :string)
    field(:object_sequence, :integer)
    field(:object_type, :integer)

    timestamps(type: :utc_datetime)
  end

  def changeset(keyword, attrs) do
    keyword
    |> cast(attrs, [:keyword, :object_name, :object_sequence, :object_type])
    |> validate_required([:keyword, :object_name, :object_sequence, :object_type])
    |> validate_length(:keyword, min: 1, max: 13)
    |> unique_constraint(:keyword, name: :keyword_pkey)
  end
end
