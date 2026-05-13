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

defmodule Prodigy.Core.Data.Portal.RoleScope do
  @moduledoc """
  Join row binding a scope string to a role. Composite primary key
  `(role_id, scope)` - a scope is either in the role or it isn't.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "portal_role_scopes" do
    belongs_to :role, Prodigy.Core.Data.Portal.Role, primary_key: true
    field :scope, :string, primary_key: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:role_id, :scope])
    |> validate_required([:role_id, :scope])
    |> unique_constraint([:role_id, :scope], name: :portal_role_scopes_pkey)
    |> assoc_constraint(:role)
  end
end
