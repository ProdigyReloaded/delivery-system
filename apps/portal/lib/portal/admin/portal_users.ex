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

defmodule Prodigy.Portal.Admin.PortalUsers do
  @moduledoc """
  Admin context for the `/admin/portal/users` surface. Surfaces each
  portal user with their identities, role memberships, direct scope
  grants, owned service-user count, and effective scope set so the
  LiveView can render the whole table in one shot.

  Role / scope mutations are delegated to `Prodigy.Portal.Authz` so
  invariants and audit logging run through a single code path.
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Portal.Identity
  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Core.Data.Portal.UserToken
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Authz
  alias Prodigy.Portal.Endpoint

  @doc """
  Lists every portal user with the derived fields the admin table
  wants - one DB round per table section, composed in memory.
  """
  def list do
    users = Repo.all(from u in User, order_by: u.email)
    ids = Enum.map(users, & &1.id)

    identities_by_user = group_identities(ids)
    roles_by_user = group_roles(ids)
    direct_by_user = group_direct_scopes(ids)
    service_counts = service_user_counts(ids)
    invite_counts = invite_counts(ids)

    for user <- users do
      roles = Map.get(roles_by_user, user.id, [])
      direct = Map.get(direct_by_user, user.id, [])

      %{
        user: user,
        identities: Map.get(identities_by_user, user.id, []),
        roles: roles,
        direct_scopes: direct,
        effective_scopes: Authz.effective_scopes(user.id),
        service_user_count: Map.get(service_counts, user.id, 0),
        # Non-revoked invite count = pending + redeemed. Surfaced on
        # the Portal Users row as `N of M` against invite_quota.
        invite_count: Map.get(invite_counts, user.id, 0)
      }
    end
  end

  @doc """
  Adjusts a portal user's `service_user_quota`. Validates against the
  user's current in-use count (re-derived server-side) so the new
  quota can't drop below how many accounts they actually hold.
  Schema-level 1..10 bounds are enforced by `User.quota_changeset/2`.
  Audits the change.

  Returns `{:ok, %User{}}` on success, `{:error, :below_count}` if
  `new_quota` is less than the current count, or
  `{:error, %Ecto.Changeset{}}` for schema-validation failures.
  """
  def set_quota(actor_id, %User{} = user, new_quota)
      when is_integer(actor_id) and is_integer(new_quota) do
    count = current_service_user_count(user.id)

    cond do
      new_quota < count ->
        {:error, :below_count}

      new_quota == user.service_user_quota ->
        {:ok, user}

      true ->
        with {:ok, updated} <-
               user
               |> User.quota_changeset(%{service_user_quota: new_quota})
               |> Repo.update() do
          Authz.write_audit!(
            actor_id,
            "set.service_user_quota",
            "portal_user",
            Integer.to_string(user.id),
            %{before: user.service_user_quota, after: new_quota}
          )

          {:ok, updated}
        end
    end
  end

  defp current_service_user_count(portal_user_id) do
    today = Date.utc_today()

    Repo.aggregate(
      from(s in Prodigy.Core.Data.Service.User,
        where: s.portal_user_id == ^portal_user_id,
        where: is_nil(s.date_deleted) or s.date_deleted > ^today
      ),
      :count
    )
  end

  @doc """
  Adjusts a portal user's `invite_quota`. Refuses if the new cap is
  below the user's count of non-revoked outstanding invites (pending
  + redeemed) - those rows have to be revoked first if you really want
  to drop someone's quota that low. Schema-level 0..50 bounds enforced
  by `User.invite_quota_changeset/2`. Audited.
  """
  def set_invite_quota(actor_id, %User{} = user, new_quota)
      when is_integer(actor_id) and is_integer(new_quota) do
    count = Prodigy.Portal.Invites.non_revoked_count(user.id)

    cond do
      new_quota < count ->
        {:error, :below_count}

      new_quota == user.invite_quota ->
        {:ok, user}

      true ->
        with {:ok, updated} <-
               user
               |> User.invite_quota_changeset(%{invite_quota: new_quota})
               |> Repo.update() do
          Authz.write_audit!(
            actor_id,
            "set.invite_quota",
            "portal_user",
            Integer.to_string(user.id),
            %{before: user.invite_quota, after: new_quota}
          )

          {:ok, updated}
        end
    end
  end

  @doc "Force-logs-out a portal user by deleting their session tokens and broadcasting to any live LiveView sockets."
  def force_logout(%User{} = user, actor_id) do
    tokens =
      Repo.all(
        from t in UserToken,
          where: t.user_id == ^user.id and t.context == "session",
          select: %{token: t.token}
      )

    disconnect_live_sockets(tokens)

    {count, _} =
      Repo.delete_all(
        from t in UserToken,
          where: t.user_id == ^user.id and t.context == "session"
      )

    Authz.write_audit!(
      actor_id,
      "force_logout",
      "portal_user",
      Integer.to_string(user.id),
      %{token_count: count}
    )

    :ok
  end

  # --- helpers -------------------------------------------------------

  defp group_identities(ids) do
    from(i in Identity, where: i.user_id in ^ids, order_by: [desc: i.inserted_at])
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
  end

  defp group_roles(ids) do
    from(ur in Prodigy.Core.Data.Portal.UserRole,
      join: r in Prodigy.Core.Data.Portal.Role,
      on: r.id == ur.role_id,
      where: ur.user_id in ^ids,
      select: {ur.user_id, r}
    )
    |> Repo.all()
    |> Enum.group_by(fn {uid, _} -> uid end, fn {_, role} -> role end)
  end

  defp group_direct_scopes(ids) do
    from(us in Prodigy.Core.Data.Portal.UserScope,
      where: us.user_id in ^ids,
      select: {us.user_id, us.scope}
    )
    |> Repo.all()
    |> Enum.group_by(fn {uid, _} -> uid end, fn {_, scope} -> scope end)
  end

  defp service_user_counts(ids) do
    from(s in Prodigy.Core.Data.Service.User,
      where: s.portal_user_id in ^ids,
      group_by: s.portal_user_id,
      select: {s.portal_user_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp invite_counts(ids) do
    from(i in Prodigy.Core.Data.Portal.Invite,
      where: i.inviter_id in ^ids,
      where: is_nil(i.revoked_at),
      group_by: i.inviter_id,
      select: {i.inviter_id, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp disconnect_live_sockets(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      topic = "users_sessions:#{Base.url_encode64(token)}"
      Endpoint.broadcast(topic, "disconnect", %{})
    end)
  end
end
