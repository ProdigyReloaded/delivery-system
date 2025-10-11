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

defmodule Prodigy.Core.Data.UserClub do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for tracking when a user last read posts in a bulletin board club.
  Only created/updated when the user actually starts reading (via note cursor).
  """

  @primary_key false
  schema "user_club" do
    field(:user_id, :string, primary_key: true)
    field(:club_id, :integer, primary_key: true)
    field(:last_read_date, :utc_datetime)

    belongs_to(:user, Prodigy.Core.Data.User,
      foreign_key: :user_id,
      references: :id,
      define_field: false)
    belongs_to(:club, Prodigy.Core.Data.Club,
      foreign_key: :club_id,
      references: :id,
      define_field: false)

    timestamps()
  end

  def changeset(user_club, attrs) do
    user_club
    |> cast(attrs, [:user_id, :club_id, :last_read_date])
    |> validate_required([:user_id, :club_id, :last_read_date])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:club_id)
    |> unique_constraint([:user_id, :club_id], name: :user_club_pkey)
  end
end
