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

defmodule Prodigy.Portal.Accounts.Blacklist do
  @moduledoc """
  Email-level cooldown gate for the unified auth flow. Every
  signup-invitation and provider-link-invitation mint checks
  `blacklisted?/1` first and silently drops when the address is in
  the list. Entries are inserted by the "wasn't me" landing page
  (30-day cooldown, `"wasnt_me"` reason) and by the invitation
  rate limiter (1-hour cooldown, `"rate_limited"` reason).
  """
  import Ecto.Query

  alias Prodigy.Core.Data.Portal.SignupBlacklist
  alias Prodigy.Core.Data.Repo

  # 30 days for wasnt_me, 1 hour for rate-limit cooldowns. Both
  # expressed in seconds.
  @default_durations %{
    "wasnt_me" => 30 * 24 * 60 * 60,
    "rate_limited" => 60 * 60
  }

  @doc """
  True if the email is currently blacklisted. Normalized before
  comparison so case-only differences don't slip past.
  """
  def blacklisted?(email) when is_binary(email) do
    now = DateTime.utc_now()
    normalized = normalize(email)

    Repo.exists?(
      from b in SignupBlacklist,
        where: b.email == ^normalized and b.expires_at > ^now
    )
  end

  def blacklisted?(_), do: false

  @doc """
  Add an email to the blacklist with the supplied reason. Accepts
  `"wasnt_me"` or `"rate_limited"`. Replaces an existing entry for
  the same email - useful for "repeated wasnt_me on an already-
  blacklisted address should renew the cooldown."

  Optional `:duration_seconds` overrides the default expiry window.
  """
  def add(email, reason, opts \\ []) when is_binary(email) and reason in ["wasnt_me", "rate_limited"] do
    duration = Keyword.get(opts, :duration_seconds, Map.fetch!(@default_durations, reason))
    expires_at = DateTime.utc_now() |> DateTime.add(duration, :second)

    attrs = %{
      email: normalize(email),
      reason: reason,
      expires_at: expires_at
    }

    # Upsert by PK - replace reason + expires_at on a re-blacklist.
    SignupBlacklist.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:reason, :expires_at]},
      conflict_target: :email
    )
  end

  @doc """
  Remove the blacklist entry for an email. Returns `{:ok, :removed}`
  if a row was deleted, `:not_found` if there was nothing to remove.
  Useful for the future admin "unblacklist" action.
  """
  def remove(email) when is_binary(email) do
    {count, _} =
      Repo.delete_all(
        from b in SignupBlacklist,
          where: b.email == ^normalize(email)
      )

    if count > 0, do: {:ok, :removed}, else: :not_found
  end

  @doc """
  Delete blacklist rows whose cooldown has elapsed. Call from a
  periodic job (once an hour is plenty). Returns the count deleted.
  """
  def expire_old do
    now = DateTime.utc_now()

    {count, _} =
      Repo.delete_all(from b in SignupBlacklist, where: b.expires_at <= ^now)

    count
  end

  defp normalize(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end
end
