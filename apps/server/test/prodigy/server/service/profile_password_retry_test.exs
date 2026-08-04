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

defmodule Prodigy.Server.Service.ProfilePasswordRetryTest do
  @moduledoc """
  Server-authoritative change-password retry counter (#340 / 0x0154).

  A service change-password write (Fm0 action 0x04) carries the transient
  verify-old-password TAC 0x015D alongside the new password TAC 0x014F. The
  server verifies the old password against the stored hash, enforces a 3-try
  lockout, increments the counter on a bad verify, and resets it to 0 (via
  User.changeset) on a successful change. These cases exercise the real
  persistence path, so they need DB fixtures.
  """
  use Prodigy.Server.RepoCase

  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Server.Context
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.Profile

  @verify_old_pw_tac 0x015D
  @password_tac 0x014F
  @try_count_key "0154"

  @old_password "OLDPASS"
  @new_password "NEWPASS"
  @user_id "AAAA20B"

  # Build a change-password 0x04 write: verify-old TAC + new-password TAC.
  defp change_password_packet(user_id, old_pw, new_pw) do
    entries = [
      {@verify_old_pw_tac, old_pw},
      {@password_tac, new_pw}
    ]

    body =
      Enum.reduce(entries, <<>>, fn {tac, value}, buf ->
        buf <> <<tac::16-big, byte_size(value), value::binary>>
      end)

    payload =
      <<0x13, 0x04, 0x1, user_id::binary-size(7), 0::40, length(entries)::16-big, body::binary>>

    %Fm0{
      src: 0x0,
      dest: 0x2201,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: payload
    }
  end

  defp handle_status(user, packet) do
    {:ok, _ctx, response} = Profile.handle(packet, %Context{user: user})
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    status
  end

  # Insert a household + subscriber user (slot A) with a known password and
  # the given #340 try count. Returns the reloaded %User{} with household
  # preloaded (the write path reads user.household).
  defp fixture(try_count) do
    today = Date.utc_today()

    {:ok, household} =
      %Household{id: "AAAA20", enabled_date: today}
      |> Household.changeset(%{})
      |> Repo.insert()

    # Insert with the password first (this resets #340 via User.changeset),
    # then set the desired try count as a :profile-only update so it isn't
    # cleared. The counter is a 1-char decimal string; 0 is "0" (see
    # User.reset_password_change_trys).
    # A household member (slot B). The password TAC 0x014F is :user-scoped,
    # so a non-subscriber member is the actor the change-password flow
    # authorizes (matching profile_scope_test's use of slot-B members).
    {:ok, user} =
      %User{id: @user_id, household_id: household.id}
      |> User.changeset(%{password: @old_password, date_enrolled: today})
      |> Repo.insert()

    counter_value = Integer.to_string(try_count)

    {:ok, user} =
      user
      |> User.changeset(%{profile: Map.put(user.profile || %{}, @try_count_key, counter_value)})
      |> Repo.update()

    Repo.preload(user, :household)
  end

  defp reload(user_id), do: Repo.get(User, user_id)

  defp try_count(%User{profile: profile}) do
    case profile && Map.get(profile, @try_count_key) do
      <<d>> when d in ?0..?9 -> d - ?0
      _ -> 0
    end
  end

  test "(a) locked out (#340 >= 3): change-password rejected without verifying, password unchanged" do
    user = fixture(3)
    original_hash = user.password

    # Even with the CORRECT old password, a locked-out user is refused.
    status = handle_status(user, change_password_packet(user.id, @old_password, @new_password))
    assert status == 0x05

    reloaded = reload(user.id)
    assert reloaded.password == original_hash
    # Counter is untouched (no increment, no reset) - the write was refused
    # before any verify or persistence.
    assert try_count(reloaded) == 3
  end

  test "(b) wrong old password: #340 incremented and persisted, write rejected, password unchanged" do
    user = fixture(1)
    original_hash = user.password

    status = handle_status(user, change_password_packet(user.id, "WRONG", @new_password))
    assert status == 0x05

    reloaded = reload(user.id)
    assert reloaded.password == original_hash
    assert try_count(reloaded) == 2
  end

  test "(c) correct old password: password changed AND #340 reset to 0" do
    user = fixture(2)
    original_hash = user.password

    {:ok, _ctx, response} =
      Profile.handle(
        change_password_packet(user.id, @old_password, @new_password),
        %Context{user: user}
      )

    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    # Success returns the original payload echoed back (status byte 0x13).
    assert status == 0x13

    reloaded = reload(user.id)
    refute reloaded.password == original_hash
    assert Pbkdf2.verify_pass(@new_password, reloaded.password)
    assert try_count(reloaded) == 0
  end

  test "(d) admin path: User.changeset(user, %{password: ...}) resets #340 to 0" do
    user = fixture(3)
    assert try_count(user) == 3

    {:ok, updated} =
      user
      |> User.changeset(%{password: "ADMINSET"})
      |> Repo.update()

    assert try_count(updated) == 0
    assert Pbkdf2.verify_pass("ADMINSET", updated.password)
  end

  test "subscriber (slot A) can change their own password (subscriber scope satisfies :user)" do
    today = Date.utc_today()

    {:ok, household} =
      %Household{id: "AAAA21", enabled_date: today}
      |> Household.changeset(%{})
      |> Repo.insert()

    {:ok, sub} =
      %User{id: "AAAA21A", household_id: household.id}
      |> User.changeset(%{password: @old_password, date_enrolled: today})
      |> Repo.insert()

    sub = Repo.preload(sub, :household)

    # Not scope-denied: a subscriber's own password (0x014F, update [:user]) is
    # writable because :subscriber satisfies the :user requirement.
    status = handle_status(sub, change_password_packet("AAAA21A", @old_password, @new_password))
    assert status == 0x13

    reloaded = reload("AAAA21A")
    assert Pbkdf2.verify_pass(@new_password, reloaded.password)
  end

  test "a :profile-only change does NOT reset #340" do
    user = fixture(2)

    {:ok, updated} =
      user
      |> User.changeset(%{profile: Map.put(user.profile, "015E", "SMITH")})
      |> Repo.update()

    assert try_count(updated) == 2
  end
end
