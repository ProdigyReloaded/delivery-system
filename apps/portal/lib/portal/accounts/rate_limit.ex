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

defmodule Prodigy.Portal.Accounts.RateLimit do
  @moduledoc """
  Sliding-window rate limiter for the unified-auth flow. Gates
  expensive / noisy actions so an attacker (or a bug) can't flood
  the mailer or the portal-user table.

  Three canonical limits:

    * `:invitation` - 3 signup / link invitations per email per hour.
    * `:login` - 10 magic-link login emails per email per hour.
    * `:ip` - 30 submissions per IP per minute, across the whole form.

  Over the limit returns `:blocked` and the caller is expected to
  silently drop the request so the UI response remains uniform with
  the happy path (no enumeration oracle).

  Storage is an ETS table owned by this GenServer. The limiter is
  approximate - two concurrent requests can both pass under the
  same count if they race between the lookup and the insert - but
  for an admin console's volume that slack is fine. For a stricter
  count, switch the per-key update to `:ets.update_counter/3` with
  a decaying-counter scheme.
  """
  use GenServer

  @table __MODULE__

  @invitation_limit 3
  @invitation_window_ms 60 * 60 * 1_000

  @login_limit 10
  @login_window_ms 60 * 60 * 1_000

  @ip_limit 30
  @ip_window_ms 60 * 1_000

  # --- public API ----------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns `:ok` if the request may proceed, `:blocked` otherwise."
  def check(kind, key, limit, window_ms)
      when is_atom(kind) and is_binary(key) and is_integer(limit) and is_integer(window_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms
    bucket_key = {kind, key}

    recent =
      case :ets.lookup(@table, bucket_key) do
        [{^bucket_key, list}] -> Enum.filter(list, &(&1 > cutoff))
        [] -> []
      end

    if length(recent) >= limit do
      :blocked
    else
      :ets.insert(@table, {bucket_key, [now | recent]})
      :ok
    end
  end

  @doc "3 signup / link invitations per email per hour."
  def check_invitation(email) when is_binary(email) do
    check(:invitation, normalize(email), @invitation_limit, @invitation_window_ms)
  end

  @doc "10 magic-link login emails per email per hour."
  def check_login(email) when is_binary(email) do
    check(:login, normalize(email), @login_limit, @login_window_ms)
  end

  @doc "30 submissions per IP per minute, across the whole form."
  def check_ip(ip) when is_binary(ip) do
    check(:ip, ip, @ip_limit, @ip_window_ms)
  end

  @doc false
  # Test-only knob; clears the table so per-test state doesn't leak.
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  # --- GenServer -----------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table,
      [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
    )

    # Periodic sweep to prune stale bucket keys entirely. Without
    # this, keys that have stopped seeing traffic accumulate in the
    # table forever.
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep do
    now = System.monotonic_time(:millisecond)
    # Longest window we track is the invitation/login hour; anything
    # older than that can be dropped unconditionally.
    cutoff = now - @invitation_window_ms

    :ets.foldl(
      fn {key, list}, _acc ->
        kept = Enum.filter(list, &(&1 > cutoff))
        if kept == [], do: :ets.delete(@table, key), else: :ets.insert(@table, {key, kept})
        nil
      end,
      nil,
      @table
    )

    :ok
  end

  defp schedule_sweep do
    # Every 5 minutes is plenty - the buckets prune themselves on
    # access, this only trims keys that nobody's checking anymore.
    Process.send_after(self(), :sweep, 5 * 60 * 1_000)
  end

  defp normalize(s), do: s |> String.trim() |> String.downcase()
end
