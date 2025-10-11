# Copyright 2022-2025, Phillip Heller
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

defmodule Prodigy.Core.Data.Topic do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for Bulletin Board topics within clubs
  """

  # Using id type which will map to smallserial in the migration
  schema "topic" do
    belongs_to(:club, Prodigy.Core.Data.Club)
    field(:title, :string)
    field(:closed, :boolean, default: false)  # Flag to close topic to new posts

    has_many(:posts, Prodigy.Core.Data.Post)

    timestamps()
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [:club_id, :title, :closed])
    |> validate_required([:club_id, :title])
    |> foreign_key_constraint(:club_id)
  end
end
