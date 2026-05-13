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

defmodule Prodigy.Core.Data.Service.MissingObject do
  @moduledoc """
  One row per object the TOCS layer was asked for but doesn't have in
  the local DB. Identity is `(name, sequence, type)` - the same triple
  TOCS uses to look an object up. Writers upsert: insert on first
  observation, increment `hit_count` and refresh `last_seen` on each
  subsequent miss for the same identity.

  Surfaced on `/admin/service/objects/deficits` as a roster sorted by
  hit_count desc - "what content is the system missing, ranked by how
  frequently it is requested."

  See `Prodigy.Server.Service.Tocs` for the write site and
  `Prodigy.Portal.Admin.MissingObjects` for the read context.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "missing_objects" do
    field :name, :string, primary_key: true
    field :sequence, :integer, primary_key: true
    field :type, :integer, primary_key: true

    field :first_seen, :utc_datetime
    field :last_seen, :utc_datetime
    field :last_user_id, :string
    field :hit_count, :integer, default: 1

    belongs_to :last_session, Prodigy.Core.Data.Service.Session,
      foreign_key: :last_session_id,
      define_field: true
  end

  @cast_fields [
    :name,
    :sequence,
    :type,
    :first_seen,
    :last_seen,
    :last_user_id,
    :last_session_id,
    :hit_count
  ]

  @doc """
  Build a changeset for the initial insert of a missing-object
  observation. Callers pass this through `Repo.insert/2` with the
  `on_conflict` keyword set so a repeat observation increments
  `hit_count` and refreshes `last_seen` instead of failing on the
  composite primary key.

  Example:

      MissingObject.observation_changeset(%{
        name: "XG680001WND",
        sequence: 0,
        type: 0xE,
        first_seen: now,
        last_seen: now,
        last_user_id: "AAAA11A",
        last_session_id: 42
      })
      |> Repo.insert(
        on_conflict: [
          set: [last_seen: now, last_user_id: "AAAA11A", last_session_id: 42],
          inc: [hit_count: 1]
        ],
        conflict_target: [:name, :sequence, :type]
      )
  """
  def observation_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :sequence, :type, :first_seen, :last_seen])
  end
end
