# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Server.Service.Enrollment.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server
  import Ecto.Changeset

  import Mock

  require Logger

  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router
  alias Prodigy.Server.Service.Logon.Status

  @moduletag :capture_log

  setup_with_mocks([
    {Calendar.DateTime, [], [now_utc: fn -> epoch() end]}
  ]) do
    {:ok, router_pid} = GenServer.start_link(Router, nil)

    [router_pid: router_pid]
  end

  defp epoch do
    {:ok, result} = DateTime.from_unix(0)
    result
  end

  defp enroll(context, user_id, tacs) do
    count = length(tacs)

    payload =
      Enum.reduce(tacs, <<>>, fn entry, buf ->
        {tac, value} = entry
        buf <> <<tac::16-big, byte_size(value), value::binary>>
      end)

    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x2201,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x2, 0x1, 0x1, user_id::binary-size(7), 0::40, count::16-big, payload::binary>>
    })
  end

  test "enrollment", context do
    # create the fixtures
    today = DateTime.to_date(DateTime.utc_now())

    %Household{id: "AAAA12", enabled_date: today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", profile: %{"0157" => "M"}}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert()

    # login with un-enrolled user gets proper response code
    {:ok, response} = logon(context.router_pid, "AAAA12A", "foobaz", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.ENROLL_SUBSCRIBER.value()

    # send enrollment request gets proper response
    # TODO add the right tacs in the make_enrollment_request method below -------------v
    {:ok, response} = enroll(context, "AAAA12A", [{0x157, "M"}])

    {:ok,
     %Fm0{
       payload:
         <<status, _gender, 0x0::72, "010170000000", 0x1, 0x0::128, "             "::binary>>
     }} = DiaPacket.decode(response)

    assert status == Status.SUCCESS.value()

    # assert the user now appears to be logged on
    assert logged_on?("AAAA12A")
    # TODO assert that the database has the TACS sent in the enrollment

    logoff(context.router_pid)
    assert !logged_on?("AAAA12A")

    {:ok, router_pid} = GenServer.start_link(Router, nil)

    {:ok, response} = logon(router_pid, "AAAA12A", "foobaz", "06.03.10")

    # TODO properly mock/assert last logon date/time
    {:ok,
     %Fm0{
       payload: <<status, _gender, 0x0::72, "010170000000", 0x1, 0x0::128, _::binary-size(13)>>
     }} = DiaPacket.decode(response)

    # TODO -> the gender  ---------^ in the response is fixed; fix this to expect whatever was sent in
    #    the enrollment request

    assert status == Status.SUCCESS.value()
  end

  test "enrollment with additional household members creates per-slot User rows", context do
    today = DateTime.to_date(DateTime.utc_now())

    %Household{id: "AAAA14", enabled_date: today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA14A", profile: %{"0157" => "M"}}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert()

    {:ok, response} = logon(context.router_pid, "AAAA14A", "foobaz", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.ENROLL_SUBSCRIBER.value()

    # Subscriber enrollment carrying slot-A (the subscriber) plus
    # members B and C, the way the RS "register more users" prompt does,
    # AND a new subscriber password (TAC 0x014F) - the members must NOT
    # get this new password, they get the subscriber's original one.
    {:ok, response} =
      enroll(context, "AAAA14A", [
        {0x157, "M"},
        {0x11A, "DOE"},
        {0x11B, "JOHN"},
        {0x11D, "MR"},
        {0x123, "DOE"},
        {0x124, "JANE"},
        {0x12C, "ROE"},
        {0x12D, "JIM"},
        {0x12E, "Q"},
        {0x14F, "newpw"}
      ])

    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.SUCCESS.value()

    subscriber = Repo.get(User, "AAAA14A")
    member_b = Repo.get(User, "AAAA14B")
    member_c = Repo.get(User, "AAAA14C")

    # Members B and C now exist as User rows in the household.
    assert member_b.household_id == "AAAA14"
    assert member_c.household_id == "AAAA14"

    # Un-enrolled, so their first logon hits the user-enrollment flow.
    assert member_b.date_enrolled == nil
    assert member_c.date_enrolled == nil

    # Names landed in each member's own name TACs (0x015E/0x015F/0x0160).
    assert member_b.profile["015E"] == "DOE"
    assert member_b.profile["015F"] == "JANE"
    assert member_c.profile["015E"] == "ROE"
    assert member_c.profile["015F"] == "JIM"
    assert member_c.profile["0160"] == "Q"

    household = Repo.get(Household, "AAAA14")
    # Slot-B..F name/title data is NOT mirrored onto household.profile -
    # it lives only on the member rows now.
    refute Map.has_key?(household.profile, "0123")
    refute Map.has_key?(household.profile, "0124")
    refute Map.has_key?(household.profile, "012C")
    # Slot A's mirror onto the household stays (the TCS retrieve path
    # still reads household.profile["011A"] for slot A).
    assert household.profile["011A"] == "DOE"
    assert household.profile["011B"] == "JOHN"

    # And a slot-B retrieve TAC reads through to member B's own row:
    # 0x0123 (PRF_USER_ITEM_LAST_B) -> member B's 0x015E ("DOE").
    assert Prodigy.Server.Service.Profile.get_value(0x0123, subscriber, household) == "DOE"
    assert Prodigy.Server.Service.Profile.get_value(0x0124, subscriber, household) == "JANE"

    # The subscriber's password is the NEW one; the members got the
    # ORIGINAL (welcome-kit) one - not the new one.
    assert Pbkdf2.verify_pass("newpw", subscriber.password)
    refute Pbkdf2.verify_pass("foobaz", subscriber.password)
    assert Pbkdf2.verify_pass("foobaz", member_b.password)
    refute Pbkdf2.verify_pass("newpw", member_b.password)
    assert Pbkdf2.verify_pass("foobaz", member_c.password)

    # And a fresh logon as member B (with the original password) routes
    # to ENROLL_OTHER.
    {:ok, router_pid} = GenServer.start_link(Router, nil)
    {:ok, response} = logon(router_pid, "AAAA14B", "foobaz", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.ENROLL_OTHER.value()
  end

  test "enrollment persists a new password from TAC 0x014F", context do
    today = DateTime.to_date(DateTime.utc_now())

    %Household{id: "AAAA13", enabled_date: today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA13A", profile: %{"0157" => "M"}}
      |> User.changeset(%{password: "oldpass"})
    ])
    |> Repo.insert()

    # Pre-enrollment: logon with the seed password returns ENROLL_SUBSCRIBER.
    {:ok, response} = logon(context.router_pid, "AAAA13A", "oldpass", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.ENROLL_SUBSCRIBER.value()

    # Enrollment payload includes both gender and a new password (TAC 0x14F).
    {:ok, response} = enroll(context, "AAAA13A", [{0x157, "M"}, {0x14F, "newpass"}])
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.SUCCESS.value()

    logoff(context.router_pid)

    # Old password must now fail.
    {:ok, router_pid} = GenServer.start_link(Router, nil)
    {:ok, response} = logon(router_pid, "AAAA13A", "oldpass", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.BAD_PASSWORD.value()

    # New password must succeed.
    {:ok, router_pid} = GenServer.start_link(Router, nil)
    {:ok, response} = logon(router_pid, "AAAA13A", "newpass", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.SUCCESS.value()
  end
end
