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

defmodule Prodigy.Portal.Invites do
  @moduledoc """
  Mint, list, look up, redeem, and revoke invitation codes.

  Quota accounting is derived: a portal user's `available/1` count is
  `invite_quota - count(non-revoked invites issued by this user)`.
  Issuance and revocation never mutate `invite_quota` - there's no
  double-bookkeeping, so the counter can't drift.

  Codes are short (12 url-safe base64 characters), generated via
  `:crypto.strong_rand_bytes/1`. Collision is astronomically unlikely
  but the `code` column is uniquely indexed and `mint!/1` retries on
  conflict just in case.

  Redeem and revoke transitions are idempotent against their target
  state - calling `redeem` on an already-redeemed invite returns
  `{:error, :already_redeemed}`, and similarly for revoke. The
  redemption itself is meant to live inside the user-creation
  transaction in `Prodigy.Portal.Accounts.process_oauth_callback/3`,
  so we expose `redeem_changeset/2` (a changeset, not a Repo write)
  for that integration; `redeem/2` is a convenience wrapper for the
  iex / non-transactional case.
  """
  import Ecto.Query

  alias Prodigy.Core.Data.Portal.Invite
  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Authz

  @code_bytes 9

  @doc """
  Mint a new invitation for `inviter`. Returns `{:ok, invite}` or
  `{:error, :over_quota}` if issuing it would exceed the inviter's
  `invite_quota`. Other DB-level errors propagate as
  `{:error, changeset}`.

  Audited as `mint.invite` against the inviter's portal_user row.
  """
  def mint(%User{} = inviter) do
    if available(inviter) <= 0 do
      {:error, :over_quota}
    else
      with {:ok, invite} <- insert_with_unique_code(inviter) do
        Authz.write_audit!(
          inviter.id,
          "mint.invite",
          "portal_invite",
          Integer.to_string(invite.id),
          %{code: invite.code}
        )

        {:ok, invite}
      end
    end
  end

  defp insert_with_unique_code(inviter, attempts_left \\ 5) do
    code = generate_code()

    %Invite{}
    |> Invite.create_changeset(%{code: code, inviter_id: inviter.id})
    |> Repo.insert()
    |> case do
      {:ok, _} = ok -> ok
      {:error, %Ecto.Changeset{errors: errors}} when attempts_left > 0 ->
        if Keyword.has_key?(errors, :code) do
          insert_with_unique_code(inviter, attempts_left - 1)
        else
          {:error, %Ecto.Changeset{} = build_error_changeset(errors, inviter, code)}
        end

      err ->
        err
    end
  end

  defp build_error_changeset(errors, inviter, code) do
    %Ecto.Changeset{
      data: %Invite{},
      params: %{"code" => code, "inviter_id" => inviter.id},
      errors: errors,
      valid?: false
    }
  end

  defp generate_code do
    :crypto.strong_rand_bytes(@code_bytes)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns the count of invitations this portal user has available to
  mint right now: `invite_quota - non_revoked_count`.
  """
  def available(%User{id: portal_user_id, invite_quota: quota}) when is_integer(quota) do
    used = non_revoked_count(portal_user_id)
    max(quota - used, 0)
  end

  @doc """
  Counts every invite this portal user has issued that hasn't been
  revoked (i.e. pending + redeemed). This is the figure the
  Portal Users admin table uses to render `N of M`.
  """
  def non_revoked_count(portal_user_id) when is_integer(portal_user_id) do
    Repo.aggregate(
      from(i in Invite,
        where: i.inviter_id == ^portal_user_id,
        where: is_nil(i.revoked_at)
      ),
      :count
    )
  end

  @doc """
  Look up an invite by code. Returns the row preloaded with inviter
  and redeemer (if any). Used both by the gating plug at sign-in and
  by the admin Invites tab.
  """
  def get_by_code(code) when is_binary(code) do
    Repo.one(
      from i in Invite,
        where: i.code == ^code,
        preload: [:inviter, :redeemer]
    )
  end

  @doc """
  Lists invitations issued by `portal_user_id`, newest first. Surfaced
  on the admin Portal User profile modal's Invites tab.
  """
  def list_for_inviter(portal_user_id) when is_integer(portal_user_id) do
    Repo.all(
      from i in Invite,
        where: i.inviter_id == ^portal_user_id,
        order_by: [desc: i.inserted_at],
        preload: [:redeemer]
    )
  end

  @doc """
  Returns true if `invite` is in the `:pending` terminal-state bucket
  AND can therefore still be redeemed. Convenience used by the
  invite-required login plug.
  """
  def redeemable?(%Invite{} = invite), do: Invite.status(invite) == :pending
  def redeemable?(_), do: false

  @doc """
  Build a changeset that, when applied, marks `invite` as redeemed by
  `redeemer`. Returned without being persisted so the caller can run
  it inside the user-creation transaction (the redemption and the
  user insert must commit together).
  """
  def redeem_changeset(%Invite{} = invite, %User{} = redeemer) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    invite
    |> Ecto.Changeset.change(%{
      redeemed_at: now,
      redeemer_id: redeemer.id
    })
  end

  @doc """
  Convenience: applies `redeem_changeset/2` against the Repo. Use
  this for iex / one-off scripts; the sign-in flow should run the
  changeset inside its own transaction alongside user creation.
  """
  def redeem(%Invite{} = invite, %User{} = redeemer) do
    cond do
      not is_nil(invite.redeemed_at) -> {:error, :already_redeemed}
      not is_nil(invite.revoked_at) -> {:error, :revoked}
      true ->
        invite
        |> redeem_changeset(redeemer)
        |> Repo.update()
    end
  end

  @doc """
  Mark `invite` revoked by `actor`. Refuses if already redeemed -
  redemption is final. Idempotent against an already-revoked invite
  (returns `{:error, :already_revoked}`). Audited.
  """
  def revoke(%Invite{} = invite, %User{} = actor) do
    cond do
      not is_nil(invite.redeemed_at) -> {:error, :already_redeemed}
      not is_nil(invite.revoked_at) -> {:error, :already_revoked}
      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        result =
          invite
          |> Ecto.Changeset.change(%{revoked_at: now, revoked_by_id: actor.id})
          |> Repo.update()

        with {:ok, _} <- result do
          Authz.write_audit!(
            actor.id,
            "revoke.invite",
            "portal_invite",
            Integer.to_string(invite.id),
            %{code: invite.code, inviter_id: invite.inviter_id}
          )
        end

        result
    end
  end
end
