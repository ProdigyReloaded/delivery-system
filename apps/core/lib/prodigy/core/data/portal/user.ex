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

defmodule Prodigy.Core.Data.Portal.User do
  @moduledoc """
  A portal user is a profile: one email, one confirmation state. Auth methods
  (email+password, Google, GitHub, dev-mock) live on the associated
  `Prodigy.Core.Data.Portal.Identity` rows. A user may have zero or many
  identities; password-related changesets live on the Identity module.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "portal_users" do
    field :email, :string
    field :confirmed_at, :naive_datetime
    field :authenticated_at, :naive_datetime, virtual: true
    # How many service accounts this portal user may hold. Default 1.
    # Bumped by an admin (psql or admin UI) to allow for testing, primarily.
    # The /start sidebar shows a "+" widget when count < quota and quota > 1.
    field :service_user_quota, :integer, default: 1

    # How many invitations this portal user may have outstanding (the
    # cap, not a remaining-count). Default 0 - admins grant explicitly.
    # Available = invite_quota - count(non-revoked invites). See
    # Prodigy.Core.Data.Portal.Invite for redemption semantics.
    field :invite_quota, :integer, default: 0

    has_many :identities, Prodigy.Core.Data.Portal.Identity
    # A portal account can own zero or more service accounts (subscriber + members).
    # Nullable on the service side, so absence here just means "no service users linked yet".
    has_many :service_users, Prodigy.Core.Data.Service.User, foreign_key: :portal_user_id

    timestamps()
  end

  @doc """
  Changeset for creating a user or changing their email.

  ## Options
    * `:validate_unique` - default true. Set false to skip the uniqueness
      probe (useful for live-validation previews that would otherwise
      hit the DB on every keystroke).
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  @doc """
  Marks the email as confirmed. Used by magic-link and OAuth callbacks.
  """
  def confirm_changeset(user) do
    now = NaiveDateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Admin-only: change how many service accounts this portal user may
  hold.  Check preventing decrement below current in-use count
  lives in the admin context (`Prodigy.Portal.Admin.PortalUsers.set_quota/3`).
  """
  def quota_changeset(user, attrs) do
    user
    |> cast(attrs, [:service_user_quota])
    |> validate_required([:service_user_quota])
    |> validate_number(:service_user_quota,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 10       # abitrary
    )
  end

  @doc """
  Admin-only: change how many invitations this portal user may hold.
  Check preventing decrement below outstanding invite count
  lives in the `Prodigy.Portal.Invites` admin context.
  """
  def invite_quota_changeset(user, attrs) do
    user
    |> cast(attrs, [:invite_quota])
    |> validate_required([:invite_quota])
    |> validate_number(:invite_quota,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 50       # arbitrary
    )
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Prodigy.Core.Data.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end
end
