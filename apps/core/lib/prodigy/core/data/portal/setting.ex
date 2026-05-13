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

defmodule Prodigy.Core.Data.Portal.Setting do
  @moduledoc """
  One row per system-level setting in the `portal_settings` key/value
  store.

  Values are stored as JSON-encoded strings - booleans, integers,
  short lists all serialize cleanly. Read access goes through
  `Prodigy.Portal.Settings.get/2`; writes through
  `Prodigy.Portal.Settings.put/3` so every change is attributed to an
  actor and timestamped.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, []}
  schema "portal_settings" do
    field :value, :string

    belongs_to :updated_by, Prodigy.Core.Data.Portal.User,
      foreign_key: :updated_by_id,
      define_field: true

    timestamps()
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :updated_by_id])
    |> validate_required([:key, :value])
  end
end
