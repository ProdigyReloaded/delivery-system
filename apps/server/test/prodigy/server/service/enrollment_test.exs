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

  alias Prodigy.Core.Data.{Household, User}
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
      %User{id: "AAAA12A", gender: "M"}
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
end
