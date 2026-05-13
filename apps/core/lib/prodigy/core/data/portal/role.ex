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

defmodule Prodigy.Core.Data.Portal.Role do
  @moduledoc """
  A named bundle of scope strings. Portal users are granted roles
  (or individual scopes) to compose their effective permission set;
  see `Prodigy.Portal.Authz` for the expansion + check logic.

  The four builtin roles (viewer, content-operator, support-operator,
  platform-admin) are seeded by migration and marked `builtin: true`,
  which blocks rename/delete from the Roles admin UI.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "portal_roles" do
    field :name, :string
    field :label, :string
    field :description, :string
    field :builtin, :boolean, default: false

    has_many :role_scopes, Prodigy.Core.Data.Portal.RoleScope,
      on_delete: :delete_all,
      on_replace: :delete

    many_to_many :users, Prodigy.Core.Data.Portal.User,
      join_through: Prodigy.Core.Data.Portal.UserRole

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a user-defined role. Builtins are created
  by migration directly and never go through this changeset.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :label, :description])
    |> validate_required([:name, :label])
    |> validate_length(:name, min: 1, max: 64)
    |> validate_length(:label, min: 1, max: 80)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase alphanumeric with hyphens or underscores"
    )
    |> unique_constraint(:name)
    |> put_change(:builtin, false)
  end

  @doc """
  Changeset for editing a user-defined role's label or description.
  Name is immutable (it's a machine identifier); builtins refuse all
  edits.
  """
  def update_changeset(%__MODULE__{builtin: true}, _attrs) do
    change(%__MODULE__{})
    |> add_error(:builtin, "builtin roles cannot be edited")
  end

  def update_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [:label, :description])
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: 80)
  end
end
