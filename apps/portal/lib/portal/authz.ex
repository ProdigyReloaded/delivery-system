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

defmodule Prodigy.Portal.Authz do
  @moduledoc """
  Scope-based authorization for portal users. One place to:

  * advertise the full scope catalog (`all_scopes/0`) and the
    subsets that matter (`meta_scopes/0`, `forbidden_for_api_keys/0`);
  * compute a user's effective scope set by unioning their role
    memberships and direct scope grants (`effective_scopes/1`);
  * gate an action with `can?/3`;
  * grant or revoke roles and scopes, writing an audit trail and
    enforcing invariants in the same transaction.

  ## Invariants enforced by this module

  1. **At least one platform admin.** After any grant/revoke, at least
     one portal user must hold every scope in `meta_scopes/0`. If a
     change would violate that, the transaction rolls back with
     `{:error, :last_admin}`.

  2. **No self-demotion.** A portal user cannot remove their own
     membership in a role or a direct grant that they currently hold.
     The plan says admin demotion must be performed by another admin;
     invariant 1 independently guarantees such an admin exists.
     Violations return `{:error, :self_demotion}`.

  Audit events are written inside the same transaction as the
  underlying mutation. A rollback from an invariant check wipes the
  audit row too - the log only contains successful operations.
  """

  import Ecto.Query, warn: false

  alias Prodigy.Core.Data.Portal.AuditEvent
  alias Prodigy.Core.Data.Portal.Role
  alias Prodigy.Core.Data.Portal.RoleScope
  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Core.Data.Portal.UserRole
  alias Prodigy.Core.Data.Portal.UserScope
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Accounts.Scope

  # ----------------------------------------------------------------
  # Scope catalog
  # ----------------------------------------------------------------

  @objects_scopes ~w(objects.view objects.upload objects.delete)
  @keywords_scopes ~w(keywords.view keywords.manage keywords.rebuild_index)
  @service_users_scopes ~w(
    service_users.view
    service_users.create
    service_users.edit_profile
    service_users.disconnect
    service_users.delete
    service_users.any_userid
  )
  @portal_users_scopes ~w(
    portal_users.view
    portal_users.invite
    portal_users.disable
    portal_users.delete
  )
  @api_keys_scopes ~w(api_keys.self api_keys.manage_any)
  @roles_scopes ~w(roles.view roles.manage grants.assign grants.revoke)
  @system_scopes ~w(system.view_audit_log system.settings)

  @all_scopes @objects_scopes ++
                @keywords_scopes ++
                @service_users_scopes ++
                @portal_users_scopes ++
                @api_keys_scopes ++
                @roles_scopes ++
                @system_scopes

  # Scopes that, held together, define "platform admin" for invariant 1
  # - the lockout-proof set: as long as one person holds all of these,
  # any misconfiguration is recoverable.
  @meta_scopes ~w(
    roles.manage
    grants.assign
    grants.revoke
    portal_users.invite
    portal_users.disable
    portal_users.delete
    system.settings
  )

  # Scopes that API keys may never carry, regardless of owner. A key
  # should not be able to mint more keys, escalate its owner, or touch
  # other portal accounts.
  @forbidden_for_api_keys ~w(
    api_keys.self
    api_keys.manage_any
    grants.assign
    grants.revoke
    roles.manage
    portal_users.invite
    portal_users.disable
    portal_users.delete
  )

  @doc "Full scope catalog as a list of `resource.action` strings."
  def all_scopes, do: @all_scopes

  @doc "Meta-scope set that defines a platform admin for invariant 1."
  def meta_scopes, do: @meta_scopes

  @doc "Scopes that may never attach to an API key."
  def forbidden_for_api_keys, do: @forbidden_for_api_keys

  @doc """
  Builds a scope string from a resource + action pair. `scope(:objects, :upload)
  #=> "objects.upload"`. Takes strings or atoms.
  """
  def scope(resource, action) do
    "#{resource}.#{action}"
  end

  # ----------------------------------------------------------------
  # Read / check
  # ----------------------------------------------------------------

  @doc """
  Returns the effective scope set for the given user as a `MapSet`
  of strings. Union of (user's role memberships expanded through
  `role_scopes`) and (direct `user_scopes` grants).

  Returns an empty set for `nil` or an unknown user.
  """
  def effective_scopes(nil), do: MapSet.new()

  def effective_scopes(%User{id: user_id}), do: effective_scopes(user_id)

  def effective_scopes(user_id) when is_integer(user_id) do
    from_roles =
      from(ur in UserRole,
        join: rs in RoleScope,
        on: rs.role_id == ur.role_id,
        where: ur.user_id == ^user_id,
        select: rs.scope
      )

    from_direct =
      from(us in UserScope,
        where: us.user_id == ^user_id,
        select: us.scope
      )

    from_roles
    |> union(^from_direct)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns `true` if the subject holds the given scope.

  ## Forms

      can?(%Scope{}, :objects, :upload)
      can?(%User{}, :objects, :upload)
      can?(user_id :: integer, :objects, :upload)
      can?(nil, _, _) #=> false
      can?(scope_string :: String.t(), :objects, :upload)  # literal check
  """
  def can?(subject, resource, action) do
    needed = scope(resource, action)

    case subject do
      nil -> false
      %Scope{user: nil} -> false
      %Scope{scopes: %MapSet{} = scopes} -> MapSet.member?(scopes, needed)
      %MapSet{} = scopes -> MapSet.member?(scopes, needed)
      %User{} = user -> MapSet.member?(effective_scopes(user), needed)
      id when is_integer(id) -> MapSet.member?(effective_scopes(id), needed)
      _ -> false
    end
  end

  @doc """
  Returns `true` if a `MapSet` of effective scopes satisfies the
  meta-set. Used by the invariant-1 query.
  """
  def platform_admin_scopes?(%MapSet{} = scopes) do
    Enum.all?(@meta_scopes, &MapSet.member?(scopes, &1))
  end

  # ----------------------------------------------------------------
  # Role + scope listings
  # ----------------------------------------------------------------

  @doc "Lists every role, builtin + custom, alphabetical by name."
  def list_roles do
    Repo.all(from r in Role, order_by: r.name)
  end

  @doc "Looks up a role by machine name (`\"platform-admin\"`)."
  def get_role_by_name(name) when is_binary(name) do
    Repo.get_by(Role, name: name)
  end

  @doc "Looks up a role by id. Raises if missing."
  def get_role!(id), do: Repo.get!(Role, id)

  @doc "Returns the scopes attached to a role as a sorted list."
  def role_scopes(%Role{id: role_id}) do
    Repo.all(from rs in RoleScope, where: rs.role_id == ^role_id, select: rs.scope, order_by: rs.scope)
  end

  @doc "Returns the role memberships held by a user."
  def list_user_roles(user_id) when is_integer(user_id) do
    Repo.all(
      from ur in UserRole,
        join: r in Role,
        on: r.id == ur.role_id,
        where: ur.user_id == ^user_id,
        order_by: r.name,
        preload: [role: r]
    )
  end

  @doc "Returns the direct scope grants held by a user."
  def list_user_scopes(user_id) when is_integer(user_id) do
    Repo.all(
      from us in UserScope,
        where: us.user_id == ^user_id,
        order_by: us.scope
    )
  end

  # ----------------------------------------------------------------
  # Grants / revokes
  # ----------------------------------------------------------------

  @doc """
  Grants `role` to `target_user_id`, attributed to `actor_id` (nilable
  for bootstrap/system grants). Idempotent - re-granting an existing
  role is a no-op that still writes an audit event for traceability.

  `role` may be a `%Role{}`, a role id, or a role name string.

  Returns `{:ok, %UserRole{}}` or `{:error, reason}`. Enforces
  invariants 1 and 2.
  """
  def grant_role(actor_id, target_user_id, role) do
    with {:ok, %Role{} = role} <- resolve_role(role) do
      Repo.transaction(fn ->
        unless target_user_exists?(target_user_id) do
          Repo.rollback(:target_not_found)
        end

        before_admins = count_platform_admins()
        attrs = %{user_id: target_user_id, role_id: role.id, granted_by_id: actor_id}

        case Repo.insert(UserRole.changeset(attrs), on_conflict: :nothing) do
          {:ok, ur} ->
            write_audit!(actor_id, "grant.role", "portal_user", Integer.to_string(target_user_id), %{
              role: role.name,
              role_id: role.id
            })

            check_invariant!(before_admins)
            ur

          {:error, cs} ->
            Repo.rollback({:changeset, cs})
        end
      end)
    end
  end

  @doc """
  Revokes `role` from `target_user_id`. Returns `{:ok, :revoked}` on
  success or `{:error, reason}`. Refuses self-demotion (invariant 2)
  and refuses the revoke if it would leave the system without a
  platform admin (invariant 1).
  """
  def revoke_role(actor_id, target_user_id, role) do
    with :ok <- refuse_self(actor_id, target_user_id),
         {:ok, %Role{} = role} <- resolve_role(role) do
      Repo.transaction(fn ->
        before_admins = count_platform_admins()

        {deleted, _} =
          Repo.delete_all(
            from ur in UserRole,
              where: ur.user_id == ^target_user_id and ur.role_id == ^role.id
          )

        if deleted == 0 do
          Repo.rollback(:not_granted)
        end

        write_audit!(actor_id, "revoke.role", "portal_user", Integer.to_string(target_user_id), %{
          role: role.name,
          role_id: role.id
        })

        check_invariant!(before_admins)
        :revoked
      end)
    end
  end

  @doc """
  Grants a single scope directly to `target_user_id` (outside of any
  role). Idempotent.
  """
  def grant_scope(actor_id, target_user_id, scope) when is_binary(scope) do
    with :ok <- validate_scope(scope) do
      Repo.transaction(fn ->
        unless target_user_exists?(target_user_id) do
          Repo.rollback(:target_not_found)
        end

        before_admins = count_platform_admins()
        attrs = %{user_id: target_user_id, scope: scope, granted_by_id: actor_id}

        case Repo.insert(UserScope.changeset(attrs), on_conflict: :nothing) do
          {:ok, us} ->
            write_audit!(actor_id, "grant.scope", "portal_user", Integer.to_string(target_user_id), %{
              scope: scope
            })

            check_invariant!(before_admins)
            us

          {:error, cs} ->
            Repo.rollback({:changeset, cs})
        end
      end)
    end
  end

  @doc """
  Revokes a direct scope grant. Refuses self-demotion and enforces
  invariant 1.
  """
  def revoke_scope(actor_id, target_user_id, scope) when is_binary(scope) do
    with :ok <- refuse_self(actor_id, target_user_id) do
      Repo.transaction(fn ->
        before_admins = count_platform_admins()

        {deleted, _} =
          Repo.delete_all(
            from us in UserScope,
              where: us.user_id == ^target_user_id and us.scope == ^scope
          )

        if deleted == 0 do
          Repo.rollback(:not_granted)
        end

        write_audit!(actor_id, "revoke.scope", "portal_user", Integer.to_string(target_user_id), %{
          scope: scope
        })

        check_invariant!(before_admins)
        :revoked
      end)
    end
  end

  # ----------------------------------------------------------------
  # Audit log
  # ----------------------------------------------------------------

  @doc """
  Writes a generic audit event outside of a grant/revoke flow - e.g.
  destructive admin actions like `object.delete` or
  `service_user.disconnect` call this directly after their primary
  mutation. Callers should invoke inside their own `Repo.transaction/1`
  when the audit needs to roll back with the action.

  Returns the inserted event or raises.
  """
  def write_audit!(actor_id, action, target_type, target_id, details \\ %{}) do
    attrs = %{
      actor_id: actor_id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      details: details
    }

    Repo.insert!(AuditEvent.changeset(attrs))
  end

  @doc """
  Lists audit events most-recent-first. Accepts optional filters:

    * `:actor_id` - only events by this actor (or `nil` for system)
    * `:action`   - exact action string
    * `:target_type` / `:target_id` - narrow to a specific target
    * `:since` / `:until` - DateTime bounds on `inserted_at`
    * `:limit`    - page size (default 100)
  """
  def list_audit_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    base =
      from e in AuditEvent,
        order_by: [desc: e.inserted_at],
        limit: ^limit

    base
    |> maybe_filter(:actor_id, opts)
    |> maybe_filter(:action, opts)
    |> maybe_filter(:target_type, opts)
    |> maybe_filter(:target_id, opts)
    |> maybe_filter_range(opts)
    |> Repo.all()
  end

  defp maybe_filter(q, key, opts) do
    case Keyword.fetch(opts, key) do
      :error ->
        q

      {:ok, nil} when key == :actor_id ->
        from e in q, where: is_nil(e.actor_id)

      {:ok, value} ->
        from e in q, where: field(e, ^key) == ^value
    end
  end

  defp maybe_filter_range(q, opts) do
    q =
      case Keyword.fetch(opts, :since) do
        {:ok, %DateTime{} = t} -> from e in q, where: e.inserted_at >= ^t
        _ -> q
      end

    case Keyword.fetch(opts, :until) do
      {:ok, %DateTime{} = t} -> from e in q, where: e.inserted_at <= ^t
      _ -> q
    end
  end

  # ----------------------------------------------------------------
  # Invariants
  # ----------------------------------------------------------------

  # Invariant 1: a mutation may not drop the platform-admin count from
  # >= 1 to 0. A system that starts with no admins (e.g. an empty test
  # sandbox) can bootstrap freely; once at least one admin exists, the
  # last one can't be demoted.
  defp check_invariant!(before_count) do
    after_count = count_platform_admins()

    if before_count >= 1 and after_count < 1 do
      Repo.rollback(:last_admin)
    end

    :ok
  end

  defp count_platform_admins do
    # Materialize (user_id, scope) pairs from both sources, then count
    # users whose effective set covers every meta scope.
    meta_count = length(@meta_scopes)

    query = """
    SELECT COUNT(*) FROM (
      SELECT user_id
      FROM (
        SELECT ur.user_id, rs.scope
        FROM portal_user_roles ur
        JOIN portal_role_scopes rs ON rs.role_id = ur.role_id
        UNION
        SELECT user_id, scope FROM portal_user_scopes
      ) effective
      WHERE scope = ANY($1::text[])
      GROUP BY user_id
      HAVING COUNT(DISTINCT scope) = $2
    ) holders
    """

    %{rows: [[count]]} = Repo.query!(query, [@meta_scopes, meta_count])
    count
  end

  # Invariant 2: a user can't revoke their own capability. Actor must
  # differ from target (unless actor is nil, i.e. system / bootstrap).
  defp refuse_self(nil, _target), do: :ok
  defp refuse_self(actor, target) when actor == target, do: {:error, :self_demotion}
  defp refuse_self(_actor, _target), do: :ok

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # ----------------------------------------------------------------
  # By-email convenience wrappers
  # ----------------------------------------------------------------

  @doc """
  Like `grant_role/3` but takes an email instead of a user_id. Useful
  from release-eval rpc during bootstrap.
  """
  def grant_role_by_email(actor_id, email, role) when is_binary(email) do
    with_user_by_email(email, &grant_role(actor_id, &1, role))
  end

  @doc "Like `revoke_role/3` but keyed by email."
  def revoke_role_by_email(actor_id, email, role) when is_binary(email) do
    with_user_by_email(email, &revoke_role(actor_id, &1, role))
  end

  @doc "Like `grant_scope/3` but keyed by email."
  def grant_scope_by_email(actor_id, email, scope) when is_binary(email) do
    with_user_by_email(email, &grant_scope(actor_id, &1, scope))
  end

  @doc "Like `revoke_scope/3` but keyed by email."
  def revoke_scope_by_email(actor_id, email, scope) when is_binary(email) do
    with_user_by_email(email, &revoke_scope(actor_id, &1, scope))
  end

  defp with_user_by_email(email, fun) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :target_not_found}
      %User{id: id} -> fun.(id)
    end
  end

  defp resolve_role(%Role{} = role), do: {:ok, role}

  defp resolve_role(id) when is_integer(id) do
    case Repo.get(Role, id) do
      nil -> {:error, :role_not_found}
      role -> {:ok, role}
    end
  end

  defp resolve_role(name) when is_binary(name) do
    case get_role_by_name(name) do
      nil -> {:error, :role_not_found}
      role -> {:ok, role}
    end
  end

  defp validate_scope(scope) when is_binary(scope) do
    if scope in @all_scopes, do: :ok, else: {:error, {:unknown_scope, scope}}
  end

  defp target_user_exists?(user_id) when is_integer(user_id) do
    Repo.exists?(from u in User, where: u.id == ^user_id)
  end
end
