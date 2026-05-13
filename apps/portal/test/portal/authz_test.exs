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

defmodule Prodigy.Portal.AuthzTest do
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Core.Data.Portal.AuditEvent
  alias Prodigy.Core.Data.Portal.Role
  alias Prodigy.Core.Data.Portal.UserRole
  alias Prodigy.Core.Data.Portal.UserScope
  alias Prodigy.Portal.Accounts.Scope
  alias Prodigy.Portal.Authz

  import Prodigy.Portal.AccountsFixtures

  describe "scope catalog" do
    test "all_scopes/0 covers every resource family" do
      all = Authz.all_scopes()

      for prefix <- ~w(objects keywords service_users portal_users api_keys roles grants system) do
        assert Enum.any?(all, &String.starts_with?(&1, prefix <> ".")),
               "catalog missing any scope starting with #{prefix}."
      end
    end

    test "meta_scopes/0 is a subset of all_scopes/0" do
      all = MapSet.new(Authz.all_scopes())

      for m <- Authz.meta_scopes() do
        assert MapSet.member?(all, m), "meta scope #{m} not in catalog"
      end
    end

    test "forbidden_for_api_keys/0 includes api_keys.* and the meta destructive subset" do
      forbidden = Authz.forbidden_for_api_keys()
      assert "api_keys.self" in forbidden
      assert "api_keys.manage_any" in forbidden
      assert "grants.assign" in forbidden
      assert "grants.revoke" in forbidden
      assert "roles.manage" in forbidden
      assert "portal_users.invite" in forbidden
      assert "portal_users.disable" in forbidden
      assert "portal_users.delete" in forbidden
    end

    test "scope/2 joins resource and action" do
      assert Authz.scope(:objects, :upload) == "objects.upload"
      assert Authz.scope("keywords", "manage") == "keywords.manage"
    end
  end

  describe "seeded builtins" do
    test "the four default roles exist with builtin = true" do
      for name <- ~w(viewer content-operator support-operator platform-admin) do
        role = Authz.get_role_by_name(name)
        assert %Role{builtin: true} = role, "missing or non-builtin role #{name}"
      end
    end

    test "platform-admin covers every meta scope" do
      role = Authz.get_role_by_name("platform-admin")
      scopes = MapSet.new(Authz.role_scopes(role))
      assert Authz.platform_admin_scopes?(scopes)
    end

    test "viewer is read-only (every scope ends in .view or .view_audit_log)" do
      role = Authz.get_role_by_name("viewer")

      for s <- Authz.role_scopes(role) do
        assert String.ends_with?(s, ".view") or s == "system.view_audit_log",
               "viewer has non-read scope #{s}"
      end
    end

    test "content-operator grants object + keyword write + api_keys.self" do
      role = Authz.get_role_by_name("content-operator")
      scopes = MapSet.new(Authz.role_scopes(role))

      for needed <- ~w(objects.upload objects.delete keywords.manage keywords.rebuild_index api_keys.self) do
        assert MapSet.member?(scopes, needed), "content-operator missing #{needed}"
      end

      refute MapSet.member?(scopes, "grants.assign"),
             "content-operator should not have meta scopes"
    end
  end

  describe "effective_scopes/1" do
    test "is empty for a user with no grants" do
      user = user_fixture()
      assert MapSet.size(Authz.effective_scopes(user)) == 0
    end

    test "returns role-expanded scopes for a granted role" do
      user = user_fixture()
      {:ok, _} = Authz.grant_role(nil, user.id, "viewer")

      scopes = Authz.effective_scopes(user)
      assert MapSet.member?(scopes, "objects.view")
      assert MapSet.member?(scopes, "keywords.view")
      refute MapSet.member?(scopes, "objects.upload")
    end

    test "returns direct scope grants" do
      user = user_fixture()
      {:ok, _} = Authz.grant_scope(nil, user.id, "objects.upload")

      scopes = Authz.effective_scopes(user)
      assert scopes == MapSet.new(["objects.upload"])
    end

    test "unions role-expanded + direct scopes" do
      user = user_fixture()
      {:ok, _} = Authz.grant_role(nil, user.id, "viewer")
      {:ok, _} = Authz.grant_scope(nil, user.id, "objects.upload")

      scopes = Authz.effective_scopes(user)
      assert MapSet.member?(scopes, "objects.view")
      assert MapSet.member?(scopes, "objects.upload")
    end

    test "nil returns an empty MapSet" do
      assert Authz.effective_scopes(nil) == MapSet.new()
    end
  end

  describe "can?/3" do
    setup do
      user = user_fixture()
      {:ok, _} = Authz.grant_role(nil, user.id, "content-operator")
      %{user: user}
    end

    test "returns true for a granted scope", %{user: user} do
      assert Authz.can?(user, :objects, :upload)
    end

    test "returns false for a scope outside the grant", %{user: user} do
      refute Authz.can?(user, :grants, :assign)
    end

    test "returns false for nil subject" do
      refute Authz.can?(nil, :objects, :upload)
    end

    test "works for a Scope struct", %{user: user} do
      scope = Scope.for_user(user)
      assert Authz.can?(scope, :objects, :upload)
      refute Authz.can?(scope, :portal_users, :delete)
    end

    test "returns false for a Scope with nil user" do
      refute Authz.can?(%Scope{user: nil}, :objects, :upload)
    end

    test "accepts an integer user id", %{user: user} do
      assert Authz.can?(user.id, :objects, :upload)
    end
  end

  describe "grant_role/3" do
    test "inserts the membership and writes an audit event" do
      admin = admin_user_fixture()
      target = user_fixture()

      assert {:ok, %UserRole{}} = Authz.grant_role(admin.id, target.id, "viewer")

      assert Repo.exists?(from ur in UserRole, where: ur.user_id == ^target.id)

      [event] =
        Repo.all(from e in AuditEvent, where: e.action == "grant.role" and e.target_id == ^Integer.to_string(target.id))

      assert event.actor_id == admin.id
      assert event.details["role"] == "viewer"
    end

    test "is idempotent - second grant of the same role is a no-op" do
      admin = admin_user_fixture()
      target = user_fixture()

      assert {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")
      assert {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")

      count =
        Repo.aggregate(
          from(ur in UserRole, where: ur.user_id == ^target.id),
          :count
        )

      assert count == 1
    end

    test "rejects an unknown role name" do
      target = user_fixture()
      assert {:error, :role_not_found} = Authz.grant_role(nil, target.id, "no-such-role")
    end

    test "rejects an unknown target user" do
      assert {:error, :target_not_found} = Authz.grant_role(nil, 999_999_999, "viewer")
    end
  end

  describe "revoke_role/3" do
    test "removes the membership and writes an audit event" do
      admin = admin_user_fixture()
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")

      assert {:ok, :revoked} = Authz.revoke_role(admin.id, target.id, "viewer")

      refute Repo.exists?(from ur in UserRole, where: ur.user_id == ^target.id)

      [event] =
        Repo.all(from e in AuditEvent, where: e.action == "revoke.role" and e.target_id == ^Integer.to_string(target.id))

      assert event.actor_id == admin.id
      assert event.details["role"] == "viewer"
    end

    test "returns :not_granted when the user didn't hold the role" do
      admin = admin_user_fixture()
      target = user_fixture()
      assert {:error, :not_granted} = Authz.revoke_role(admin.id, target.id, "viewer")
    end
  end

  describe "grant_scope/3 and revoke_scope/3" do
    test "grant + revoke round-trip" do
      admin = admin_user_fixture()
      target = user_fixture()

      assert {:ok, %UserScope{}} = Authz.grant_scope(admin.id, target.id, "objects.upload")
      assert Authz.can?(target, :objects, :upload)

      assert {:ok, :revoked} = Authz.revoke_scope(admin.id, target.id, "objects.upload")
      refute Authz.can?(target, :objects, :upload)
    end

    test "rejects an unknown scope string" do
      target = user_fixture()
      assert {:error, {:unknown_scope, "no.such"}} = Authz.grant_scope(nil, target.id, "no.such")
    end
  end

  describe "invariant 1 - at least one platform admin" do
    test "refuses a revoke that would leave zero admins" do
      admin = admin_user_fixture()
      other = admin_user_fixture()

      # `admin_user_fixture` uses the legacy :admin flag; the bootstrap
      # migration grants platform-admin to those rows, so both already
      # hold the role. Revoking one leaves one admin - fine.
      assert {:ok, :revoked} = Authz.revoke_role(other.id, admin.id, "platform-admin")

      # Revoking the last admin's role must fail even if a different
      # actor performs it.
      some_other_actor = user_fixture()

      assert {:error, :last_admin} =
               Authz.revoke_role(some_other_actor.id, other.id, "platform-admin")

      # The role membership must still be present after the rollback.
      platform_admin = Authz.get_role_by_name("platform-admin")

      assert Repo.exists?(
               from ur in UserRole,
                 where: ur.user_id == ^other.id and ur.role_id == ^platform_admin.id
             )

      # And no revoke.role audit should have been written for the
      # refused call.
      events_for_other =
        Repo.all(
          from e in AuditEvent,
            where: e.action == "revoke.role" and e.target_id == ^Integer.to_string(other.id)
        )

      assert events_for_other == []
    end

    test "a user who cobbles together the meta set via direct grants also counts as an admin" do
      # One direct-grant admin. Prove they satisfy the invariant -
      # no membership needed, no platform-admin role.
      user = user_fixture()

      for scope <- Authz.meta_scopes() do
        {:ok, _} = Authz.grant_scope(nil, user.id, scope)
      end

      # Now confirm: removing one meta scope drops the admin count to
      # zero and invariant 1 fires.
      assert {:error, :last_admin} =
               Authz.revoke_scope(nil, user.id, "roles.manage")
    end
  end

  describe "invariant 2 - no self-demotion" do
    test "a user cannot revoke their own role" do
      admin = admin_user_fixture()
      assert {:error, :self_demotion} = Authz.revoke_role(admin.id, admin.id, "platform-admin")
    end

    test "a user cannot revoke their own direct scope" do
      user = user_fixture()
      {:ok, _} = Authz.grant_scope(nil, user.id, "objects.upload")
      assert {:error, :self_demotion} = Authz.revoke_scope(user.id, user.id, "objects.upload")
    end

    test "system (actor_id = nil) can revoke anyone - bootstrap uses this" do
      admin = admin_user_fixture()
      other = admin_user_fixture()
      # Two admins means we can revoke one without hitting invariant 1.
      assert {:ok, :revoked} = Authz.revoke_role(nil, other.id, "platform-admin")
      _ = admin
    end
  end

  describe "by-email wrappers" do
    test "grant_role_by_email/3 resolves the email and delegates" do
      target = user_fixture()
      assert {:ok, _} = Authz.grant_role_by_email(nil, target.email, "viewer")
      assert Repo.exists?(from ur in UserRole, where: ur.user_id == ^target.id)
    end

    test "returns :target_not_found for an unknown email" do
      assert {:error, :target_not_found} =
               Authz.grant_role_by_email(nil, "ghost@example.com", "viewer")
    end

    test "revoke_scope_by_email/3 round-trips" do
      target = user_fixture()
      {:ok, _} = Authz.grant_scope_by_email(nil, target.email, "objects.upload")
      assert Authz.can?(target, :objects, :upload)

      assert {:ok, :revoked} =
               Authz.revoke_scope_by_email(nil, target.email, "objects.upload")

      refute Authz.can?(target, :objects, :upload)
    end
  end

  describe "list_audit_events/1" do
    test "returns events most-recent-first with limit" do
      admin = admin_user_fixture()
      target = user_fixture()

      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")
      {:ok, _} = Authz.grant_scope(admin.id, target.id, "objects.upload")

      events = Authz.list_audit_events(limit: 10)
      actions = Enum.map(events, & &1.action)
      assert "grant.role" in actions
      assert "grant.scope" in actions
    end

    test "filters by actor_id" do
      admin = admin_user_fixture()
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")

      events = Authz.list_audit_events(actor_id: admin.id)
      assert Enum.all?(events, &(&1.actor_id == admin.id))
    end

    test "filters by action" do
      admin = admin_user_fixture()
      target = user_fixture()
      {:ok, _} = Authz.grant_role(admin.id, target.id, "viewer")
      {:ok, _} = Authz.grant_scope(admin.id, target.id, "objects.upload")

      events = Authz.list_audit_events(action: "grant.scope")
      assert Enum.all?(events, &(&1.action == "grant.scope"))
    end
  end
end
