# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Server.Service.Enrollment.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Ecto.Changeset

  import Mock

  require Logger

  alias Prodigy.Core.Data.{Household, User}
  alias Prodigy.Server.Session
  alias Prodigy.Server.Service.{Logon, Logoff, Enrollment}
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket

  @moduletag :capture_log

  setup_with_mocks([
    {Calendar.DateTime, [], [now_utc: fn -> epoch() end]}
  ]) do
    :ok
  end

  defp epoch() do
    {:ok, result} = DateTime.from_unix(0)
    result
  end

  # TODO figure out why I can't pull these two methods in from the LogonTest module
  def make_logon_request(user, pass, ver) do
    %Fm0{
      src: 0x0,
      dest: 0x2200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x1, user::binary, String.length(pass)::8, pass::binary, ver::binary>>
    }
  end

  def make_logoff_request(_user) do
    %Fm0{src: 0x0, dest: 0xD201, logon_seq: 0, message_id: 0, function: Fm0.Function.APPL_0}
  end

  defp make_enrollment_request(user_id, tacs) do
    count = length(tacs)

    payload =
      Enum.reduce(tacs, <<>>, fn entry, buf ->
        {tac, value} = entry
        buf <> <<tac::16-big, byte_size(value), value::binary>>
      end)

    %Fm0{
      src: 0x0,
      dest: 0x2201,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x2, 0x1, 0x1, user_id::binary-size(7), 0::40, count::16-big, payload::binary>>
    }
  end

  test "enrollment" do
    # create the fixtures
    today = DateTime.to_date(DateTime.utc_now())

    %Household{id: "AAAA12", enabled_date: today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "M"}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert()

    # login with unenrolled user gets proper response code
    {:ok, %Session{} = session, response} =
      Logon.handle(make_logon_request("AAAA12A", "foobaz", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.ENROLL_SUBSCRIBER.value()

    # send enrollment request gets proper response

    # TODO add the right tacs in the make_enrollment_request method below -------------v
    {:ok, %Session{}, response} =
      Enrollment.handle(make_enrollment_request("AAAA12A", [{0x157, "M"}]), session)

    {:ok,
     %Fm0{
       payload:
         <<status, _gender, 0x0::72, "010170000000", 0x1, 0x0::128, "             "::binary>>
     }} = DiaPacket.decode(response)

    assert status == Logon.Status.SUCCESS.value()

    # assert database has right things

    # logoff

    user =
      User
      |> Ecto.Query.where([u], u.id == "AAAA12A")
      |> Ecto.Query.first()
      |> Repo.one()

    assert user.logged_on == true

    request = make_logoff_request("AAAA12A")
    {:disconnect, %Session{}, _response} = Logoff.handle(request, %Session{user: user})

    _user =
      User
      |> Ecto.Query.where([u], u.id == "AAAA12A")
      |> Ecto.Query.first()
      |> Repo.one()

    # login with same account gets proper response
    {:ok, %Session{}, response} =
      Logon.handle(make_logon_request("AAAA12A", "foobaz", "06.03.10"))

    # TODO properly mock/assert last logon date/time
    {:ok,
     %Fm0{
       payload: <<status, _gender, 0x0::72, "010170000000", 0x1, 0x0::128, _::binary-size(13)>>
     }} = DiaPacket.decode(response)

    # TODO -> the gender  ---------^ in the response is fixed; fix this to expect whatever was sent in
    #    the enrollment request

    assert status == Logon.Status.SUCCESS.value()
  end
end
