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

defmodule Prodigy.Server.Service.ProfileReloadTest do
  @moduledoc """
  The profile service reloads the user from the DB at the top of handle/2, so a
  cached context.user cannot be used to bypass - or falsely trigger - the
  server-side change-password lockout. context.user is captured once at logon
  and can go stale while another connection (or an admin in the portal) moves
  the #340 (0x0154) counter. These cases hold a deliberately stale user and
  prove the reload, not the stale copy, governs enforcement.
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
  @user_id "AAAA30B"

  defp change_password_packet(user_id, old_pw, new_pw) do
    entries = [{@verify_old_pw_tac, old_pw}, {@password_tac, new_pw}]

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

  # Enrolled slot-B member with a known password and the given #340 count.
  defp fixture(try_count) do
    today = Date.utc_today()

    {:ok, household} =
      %Household{id: "AAAA30", enabled_date: today}
      |> Household.changeset(%{})
      |> Repo.insert()

    {:ok, user} =
      %User{id: @user_id, household_id: household.id}
      |> User.changeset(%{password: @old_password, date_enrolled: today})
      |> Repo.insert()

    {:ok, user} =
      user
      |> User.changeset(%{
        profile: Map.put(user.profile || %{}, @try_count_key, Integer.to_string(try_count))
      })
      |> Repo.update()

    Repo.preload(user, :household)
  end

  # Move the PERSISTED counter without touching the in-memory `user` the caller
  # still holds - simulating a context.user that went stale after logon.
  defp set_persisted_counter(user, count) do
    fresh = Repo.get(User, user.id)

    fresh
    |> User.changeset(%{profile: Map.put(fresh.profile, @try_count_key, Integer.to_string(count))})
    |> Repo.update!()
  end

  test "a stale under-limit context.user cannot bypass a lockout applied in the DB" do
    stale = fixture(0)
    set_persisted_counter(stale, 3)

    # Correct old password, but the reload sees the lock -> refused, unchanged.
    assert handle_status(stale, change_password_packet(@user_id, @old_password, @new_password)) ==
             0x05

    assert Pbkdf2.verify_pass(@old_password, Repo.get(User, @user_id).password)
  end

  test "a stale still-locked context.user is honored once the DB counter is cleared" do
    stale = fixture(3)
    set_persisted_counter(stale, 0)

    # The reload sees the cleared counter -> the change is allowed.
    assert handle_status(stale, change_password_packet(@user_id, @old_password, @new_password)) ==
             0x13

    assert Pbkdf2.verify_pass(@new_password, Repo.get(User, @user_id).password)
  end
end
