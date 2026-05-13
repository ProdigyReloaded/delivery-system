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

defmodule Prodigy.Core.Data.Portal.UserRole do
  @moduledoc """
  Role membership. A portal user may hold any number of roles; their
  effective scopes = union of (expanded role scopes) and direct
  `UserScope` grants.

  `granted_by_id` is nilable - bootstrap seeds have no actor, and the
  granter account may be deleted while the membership lives on.
  The audit log is the authoritative record of who granted what.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "portal_user_roles" do
    belongs_to :user, Prodigy.Core.Data.Portal.User, primary_key: true
    belongs_to :role, Prodigy.Core.Data.Portal.Role, primary_key: true
    belongs_to :granted_by, Prodigy.Core.Data.Portal.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :role_id, :granted_by_id])
    |> validate_required([:user_id, :role_id])
    |> unique_constraint([:user_id, :role_id], name: :portal_user_roles_pkey)
    |> assoc_constraint(:user)
    |> assoc_constraint(:role)
  end
end
