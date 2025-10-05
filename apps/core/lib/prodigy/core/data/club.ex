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

defmodule Prodigy.Core.Data.Club do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for Prodigy Bulletin Board clubs
  """

  schema "club" do
    field(:handle, :string)  # 3 character handle
    field(:name, :string)    # Full display name

    has_many(:topics, Prodigy.Core.Data.Topic)

    timestamps()
  end

  def changeset(club, attrs) do
    club
    |> cast(attrs, [:handle, :name])
    |> validate_required([:handle, :name])
    |> validate_length(:handle, is: 3)
    |> unique_constraint(:handle)
  end
end
