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

defmodule Prodigy.Core.Data.Portal.SignupBlacklist do
  @moduledoc """
  Row on the email-level cooldown list. Written when the recipient
  of a signup / link confirmation clicks "wasn't me," or when an
  address exceeds the invitation rate limit. The Accounts.Blacklist
  context consults this before sending any new invitation.

  Primary key is the email string; an address can appear at most
  once at a time. A re-blacklist of the same address replaces the
  existing row (`on_conflict: :replace_all` at the context level).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:email, :string, []}
  schema "portal_signup_blacklist" do
    field :reason, :string
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_reasons ~w(wasnt_me rate_limited)

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:email, :reason, :expires_at])
    |> validate_required([:email, :reason, :expires_at])
    |> validate_inclusion(:reason, @valid_reasons)
  end

  def valid_reasons, do: @valid_reasons
end
