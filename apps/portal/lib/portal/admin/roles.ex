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

defmodule Prodigy.Portal.Admin.Roles do
  @moduledoc """
  Admin-facing CRUD for the `portal_roles` table and its
  `role_scopes` companion. All mutations are audited.

  Builtin roles (`builtin: true`) are immutable through this API -
  the schema changeset refuses edits and the delete path short-
  circuits with `:builtin`. Custom roles support full CRUD and can
  freely change their scope set.
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Portal.Role
  alias Prodigy.Core.Data.Portal.RoleScope
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Authz

  @doc """
  Creates a custom role with the given attrs and scope list.

  Returns `{:ok, role}` or `{:error, changeset}`. Audits the
  creation on success.
  """
  def create_role(actor_id, attrs, scopes) when is_list(scopes) do
    Repo.transaction(fn ->
      with :ok <- validate_scopes(scopes),
           {:ok, role} <- Repo.insert(Role.create_changeset(attrs)) do
        insert_role_scopes!(role.id, scopes)

        Authz.write_audit!(actor_id, "create.role", "role", Integer.to_string(role.id), %{
          name: role.name,
          scopes: Enum.sort(scopes)
        })

        role
      else
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback({:changeset, cs})
        {:error, other} -> Repo.rollback(other)
      end
    end)
    |> case do
      {:ok, role} -> {:ok, role}
      {:error, {:changeset, cs}} -> {:error, cs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates a custom role's label/description and resets its scope
  set to the provided list. Refuses on a builtin role.
  """
  def update_role(_actor_id, %Role{builtin: true}, _attrs, _scopes), do: {:error, :builtin}

  def update_role(actor_id, %Role{} = role, attrs, scopes) when is_list(scopes) do
    Repo.transaction(fn ->
      with :ok <- validate_scopes(scopes),
           {:ok, updated} <- Repo.update(Role.update_changeset(role, attrs)) do
        Repo.delete_all(from rs in RoleScope, where: rs.role_id == ^role.id)
        insert_role_scopes!(role.id, scopes)

        Authz.write_audit!(actor_id, "update.role", "role", Integer.to_string(role.id), %{
          name: updated.name,
          scopes: Enum.sort(scopes)
        })

        updated
      else
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback({:changeset, cs})
        {:error, other} -> Repo.rollback(other)
      end
    end)
    |> case do
      {:ok, role} -> {:ok, role}
      {:error, {:changeset, cs}} -> {:error, cs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a custom role. Refuses if the role is builtin or if any
  portal user currently holds it - the grants would cascade, which
  would open up invariant-1 exposure on platform-admin and surprise
  the owner of a content-operator-typed role with sudden capability
  loss.
  """
  def delete_role(_actor_id, %Role{builtin: true}), do: {:error, :builtin}

  def delete_role(actor_id, %Role{} = role) do
    Repo.transaction(fn ->
      holders =
        Repo.aggregate(
          from(ur in Prodigy.Core.Data.Portal.UserRole, where: ur.role_id == ^role.id),
          :count
        )

      if holders > 0 do
        Repo.rollback({:in_use, holders})
      end

      {:ok, _} = Repo.delete(role)

      Authz.write_audit!(actor_id, "delete.role", "role", Integer.to_string(role.id), %{
        name: role.name
      })

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_scopes(scopes) do
    catalog = MapSet.new(Authz.all_scopes())

    Enum.find_value(scopes, :ok, fn s ->
      if MapSet.member?(catalog, s), do: nil, else: {:error, {:unknown_scope, s}}
    end)
  end

  defp insert_role_scopes!(role_id, scopes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      scopes
      |> Enum.uniq()
      |> Enum.map(fn s -> %{role_id: role_id, scope: s, inserted_at: now} end)

    if rows != [] do
      Repo.insert_all(RoleScope, rows, on_conflict: :nothing)
    end
  end
end
