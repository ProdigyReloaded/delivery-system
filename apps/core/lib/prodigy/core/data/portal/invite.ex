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

defmodule Prodigy.Core.Data.Portal.Invite do
  @moduledoc """
  Invitation code issued by a portal user out of their `invite_quota`.
  An invite has three terminal states, all derived from the presence/absence
  of timestamp columns (no separate `status` enum to drift out of sync):

    * **pending**  - `redeemed_at IS NULL AND revoked_at IS NULL`
    * **redeemed** - `redeemed_at IS NOT NULL` (the redeemer's
      portal_user_id is on the row)
    * **revoked**  - `revoked_at IS NOT NULL`

  Redeemed and revoked are mutually exclusive by app rule (the
  redemption transaction refuses an already-revoked invite).

  Quota accounting is **derived**: a portal user's available invites
  is `invite_quota - count(non-revoked invites)`. Issuance never
  decrements `invite_quota`; revocation never refunds it. Admin
  bumps the cap to grant more.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "portal_invites" do
    field :code, :string
    field :redeemed_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :inviter, Prodigy.Core.Data.Portal.User,
      foreign_key: :inviter_id,
      define_field: true

    belongs_to :redeemer, Prodigy.Core.Data.Portal.User,
      foreign_key: :redeemer_id,
      define_field: true

    belongs_to :revoked_by, Prodigy.Core.Data.Portal.User,
      foreign_key: :revoked_by_id,
      define_field: true

    timestamps()
  end

  @doc """
  Initial-creation changeset. Caller supplies `inviter_id` and `code`;
  redemption / revocation columns stay nil and get populated later via
  the dedicated changesets in `Prodigy.Portal.Invites`.
  """
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:code, :inviter_id])
    |> validate_required([:code, :inviter_id])
    |> unique_constraint(:code)
  end

  @doc """
  Returns the invite's status as one of `:pending`, `:redeemed`, `:revoked`.
  """
  def status(%__MODULE__{redeemed_at: nil, revoked_at: nil}), do: :pending
  def status(%__MODULE__{redeemed_at: ts}) when not is_nil(ts), do: :redeemed
  def status(%__MODULE__{revoked_at: ts}) when not is_nil(ts), do: :revoked
end
