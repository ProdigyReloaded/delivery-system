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

defmodule Prodigy.Server.Service.Logon.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Ecto.Changeset

  import Mock
  alias Timex

  require Mix
  require Logger

  alias Prodigy.Core.Data.{Household, User}
  alias Prodigy.Server.Session
  alias Prodigy.Server.Service.Logon
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket

  @moduletag :capture_log

  #  doctest Logon

  setup_with_mocks([
    {Calendar.DateTime, [], [now_utc: fn -> DateTime.from_unix!(0) end]}
  ]) do
    :ok
  end

  @today DateTime.to_date(DateTime.utc_now())

  # TODO make these packets go through the router for best coverage

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

  test "bad version" do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert()

    {:error, %Session{}, response} =
      Logon.handle(make_logon_request("AAAA12A", "other", "06.03.11"))

    Logger.debug("#{inspect(response)}")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.BAD_VERSION.value()
  end

  test "bad password" do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    {:error, %Session{}, response} =
      Logon.handle(make_logon_request("AAAA12A", "FOOBAQ", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.BAD_PASSWORD.value()
  end

  test "no such user" do
    {:error, %Session{}, response} =
      Logon.handle(make_logon_request("AAAA12B", "FOOBAR", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.BAD_PASSWORD.value()
  end

  test "enroll subscriber" do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F"}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    {:ok, %Session{}, response} =
      Logon.handle(make_logon_request("AAAA12A", "foobaz", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.ENROLL_SUBSCRIBER.value()
  end

  test "enroll other" do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12B", gender: "F"}
      |> User.changeset(%{password: "fnord"})
    ])
    |> Repo.insert!()

    {:ok, %Session{}, response} = Logon.handle(make_logon_request("AAAA12B", "fnord", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.ENROLL_OTHER.value()
  end

  test "deleted" do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12C", gender: "F", date_deleted: @today}
      |> User.changeset(%{password: "qux"})
    ])
    |> Repo.insert!()

    {:error, %Session{}, response} =
      Logon.handle(make_logon_request("AAAA12C", "qux", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.ACCOUNT_PROBLEM.value()
  end

  test "success and inuse" do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12D", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    request = make_logon_request("AAAA12D", "test", "06.03.10")
    {:ok, %Session{}, response} = Logon.handle(request)

    {:ok,
     %Fm0{payload: <<status, _gender, 0x0::72, "010170000000", 0x0, 0x0::128, "             ">>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.SUCCESS.value()

    {:error, %Session{}, response} = Logon.handle(request)

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.ID_IN_USE.value()
  end

  test "disabled household prohibits logon" do
    %Household{id: "BBBB12", enabled_date: @today, disabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "BBBB12A", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    {:error, %Session{}, response} =
      Logon.handle(make_logon_request("BBBB12A", "test", "06.03.10"))

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Logon.Status.ACCOUNT_PROBLEM.value()
  end
end
