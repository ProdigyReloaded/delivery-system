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

defmodule Prodigy.Server.Service.LogonLogoff.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server
  import Ecto.Changeset

  import Mock

  require Mix
  require Logger

  alias Prodigy.Core.Data.{Household, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router
  alias Prodigy.Server.Service.Logon.Status

  @moduletag :capture_log

  # These tests are all somewhat fragile since they are timing sensitive

  defp epoch do
    {:ok, result} = DateTime.from_unix(0)
    result
  end

  setup_with_mocks([
    {Calendar.DateTime, [], [now_utc: fn -> epoch() end]}
  ]) do
    {:ok, router_pid} = GenServer.start_link(Router, nil)

    [router_pid: router_pid]
  end

  @today DateTime.to_date(DateTime.utc_now())

  test "Router terminates when no logon before authentication timeout", context do
    assert Process.alive?(context.router_pid) == true
    Process.sleep(4000)
    assert Process.alive?(context.router_pid) == false
  end

  test "Authentication timeout remains after failed logon", context do
    assert Process.alive?(context.router_pid) == true

    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert()

    {:ok, _response} = logon(context.router_pid, "AAAA12A", "other", "06.03.11")
    Process.sleep(4000)
    assert Process.alive?(context.router_pid) == false
  end

  test "Authentication timeout canceled after un-enrolled subscriber logon", context do
    assert Process.alive?(context.router_pid) == true

    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F"}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    {:ok, _response} = logon(context.router_pid, "AAAA12A", "foobaz", "06.03.10")

    Process.sleep(4000)
    assert Process.alive?(context.router_pid) == true
  end

  test "Authentication timeout reset after logoff (for re-logon)", context do
    assert Process.alive?(context.router_pid) == true

    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12D", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    assert !logged_on?("AAAA12D")

    {:ok, response} = logon(context.router_pid, "AAAA12D", "test", "06.03.10")

    {:ok,
     %Fm0{payload: <<status, _gender, 0x0::72, "010170000000", 0x0, 0x0::128, "             ">>}} =
      DiaPacket.decode(response)

    assert status == Status.SUCCESS.value()

    Process.sleep(4000)
    assert Process.alive?(context.router_pid) == true

    assert logged_on?("AAAA12D")
    logoff_relogon(context.router_pid)
    assert !logged_on?("AAAA12D")

    Process.sleep(4000)
    assert Process.alive?(context.router_pid) == false
  end

  test "logon fails on unsupported client version", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert()

    {:ok, response} = logon(context.router_pid, "AAAA12A", "other", "06.03.11")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.BAD_VERSION.value()
  end

  test "logon fails on incorrect password", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    {:ok, response} = logon(context.router_pid, "AAAA12A", "FOOBAQ", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.BAD_PASSWORD.value()
  end

  test "logon fails when no such user", context do
    {:ok, response} = logon(context.router_pid, "AAAA12B", "FOOBAR", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.BAD_PASSWORD.value()
  end

  test "logon succeeds for un-enrolled subscriber", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F"}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    {:ok, response} = logon(context.router_pid, "AAAA12A", "foobaz", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.ENROLL_SUBSCRIBER.value()
  end

  test "logon succeeds for un-enrolled member", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12B", gender: "F"}
      |> User.changeset(%{password: "fnord"})
    ])
    |> Repo.insert!()

    {:ok, response} = logon(context.router_pid, "AAAA12B", "fnord", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.ENROLL_OTHER.value()
  end

  test "logon fails for deleted user", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12C", gender: "F", date_deleted: @today}
      |> User.changeset(%{password: "qux"})
    ])
    |> Repo.insert!()

    {:ok, response} = logon(context.router_pid, "AAAA12C", "qux", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.ACCOUNT_PROBLEM.value()
  end

  test "logon fails if account already logged on", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12D", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    {:ok, response} = logon(context.router_pid, "AAAA12D", "test", "06.03.10")

    {:ok,
     %Fm0{payload: <<status, _gender, 0x0::72, "010170000000", 0x0, 0x0::128, "             ">>}} =
      DiaPacket.decode(response)

    assert status == Status.SUCCESS.value()

    {:ok, response} = logon(context.router_pid, "AAAA12D", "test", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.ID_IN_USE.value()
  end

  test "disabled household prohibits logon", context do
    %Household{id: "BBBB12", enabled_date: @today, disabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "BBBB12A", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    {:ok, response} = logon(context.router_pid, "BBBB12A", "test", "06.03.10")

    {:ok, %Fm0{payload: <<status, 0x0::80, "010170000000", 0x0::56>>}} =
      DiaPacket.decode(response)

    assert status == Status.ACCOUNT_PROBLEM.value()
  end

  test "logged_on set on logon and cleared on normal logoff", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12D", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    assert !logged_on?("AAAA12D")

    {:ok, response} = logon(context.router_pid, "AAAA12D", "test", "06.03.10")

    {:ok,
     %Fm0{payload: <<status, _gender, 0x0::72, "010170000000", 0x0, 0x0::128, "             ">>}} =
      DiaPacket.decode(response)

    assert status == Status.SUCCESS.value()

    assert logged_on?("AAAA12D")

    logoff(context.router_pid)

    assert !logged_on?("AAAA12D")
  end

  test "logged_on set on logon and cleared on abnormal logoff", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12D", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert()

    assert !logged_on?("AAAA12D")

    {:ok, response} = logon(context.router_pid, "AAAA12D", "test", "06.03.10")

    {:ok,
     %Fm0{payload: <<status, _gender, 0x0::72, "010170000000", 0x0, 0x0::128, "             ">>}} =
      DiaPacket.decode(response)

    assert status == Status.SUCCESS.value()

    assert logged_on?("AAAA12D")

    # Shutdown the router, which is what would happen in the case of an abnormal reception system
    # disconnect.
    :ok = GenServer.stop(context.router_pid)

    assert !logged_on?("AAAA12D")
  end

  test "authenication timer survives bad password then cancelled with good password", context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12D", gender: "M", date_enrolled: @today}
      |> User.changeset(%{password: "good"})
    ])
    |> Repo.insert()

    assert !logged_on?("AAAA12D")

    {:ok, response} = logon(context.router_pid, "AAAA12D", "bad", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.BAD_PASSWORD.value()

    assert !logged_on?("AAAA12D")

    {:ok, response} = logon(context.router_pid, "AAAA12D", "good", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.SUCCESS.value()

    assert logged_on?("AAAA12D")

    Process.sleep(4000)
    assert Process.alive?(context.router_pid) == true
  end
end
