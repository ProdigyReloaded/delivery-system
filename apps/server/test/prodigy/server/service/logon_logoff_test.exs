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

defmodule Prodigy.Server.Service.LogonLogoff.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server
  import Ecto.Changeset

  import Mock

  require Mix
  require Logger

  alias Prodigy.Core.Data.{Household, Session, User}
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

  test "user with unlimited concurrency can have multiple sessions", _context do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today, concurrency_limit: 0}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert!()

    # Start multiple router processes to simulate multiple sessions
    {:ok, router1} = GenServer.start_link(Router, nil)
    {:ok, router2} = GenServer.start_link(Router, nil)
    {:ok, router3} = GenServer.start_link(Router, nil)

    # All three logons should succeed
    {:ok, response1} = logon(router1, "AAAA12A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status1, _rest::binary>>}} = DiaPacket.decode(response1)
    assert status1 == Status.SUCCESS.value()

    {:ok, response2} = logon(router2, "AAAA12A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status2, _rest::binary>>}} = DiaPacket.decode(response2)
    assert status2 == Status.SUCCESS.value()

    {:ok, response3} = logon(router3, "AAAA12A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status3, _rest::binary>>}} = DiaPacket.decode(response3)
    assert status3 == Status.SUCCESS.value()

    # Verify all three sessions are active
    active_count =
      from(s in Session,
        where: s.user_id == "AAAA12A",
        where: is_nil(s.logoff_timestamp)
      )
      |> Repo.aggregate(:count)

    assert active_count == 3

    # Clean up
    GenServer.stop(router1)
    GenServer.stop(router2)
    GenServer.stop(router3)
  end

  test "user with concurrency_limit=2 allows exactly 2 sessions", _context do
    %Household{id: "AAAA13", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA13A", gender: "M", date_enrolled: @today, concurrency_limit: 2}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert!()

    {:ok, router1} = GenServer.start_link(Router, nil)
    {:ok, router2} = GenServer.start_link(Router, nil)
    {:ok, router3} = GenServer.start_link(Router, nil)

    # First two should succeed
    {:ok, response1} = logon(router1, "AAAA13A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status1, _rest::binary>>}} = DiaPacket.decode(response1)
    assert status1 == Status.SUCCESS.value()

    {:ok, response2} = logon(router2, "AAAA13A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status2, _rest::binary>>}} = DiaPacket.decode(response2)
    assert status2 == Status.SUCCESS.value()

    # Third should fail with ID_IN_USE
    {:ok, response3} = logon(router3, "AAAA13A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status3, _rest::binary>>}} = DiaPacket.decode(response3)
    assert status3 == Status.ID_IN_USE.value()

    # Clean up
    GenServer.stop(router1)
    GenServer.stop(router2)
    GenServer.stop(router3)
  end

  test "user session is marked abnormal when server terminates unexpectedly", _context do
    %Household{id: "AAAA14", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA14A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert!()

    # Start a new router for this test - don't link it to avoid crash propagation
    {:ok, router_pid} = GenServer.start(Router, nil)

    # Log the user on
    {:ok, response} = logon(router_pid, "AAAA14A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    assert status == Status.SUCCESS.value()

    # Verify session is active
    session =
      from(s in Session,
        where: s.user_id == "AAAA14A",
        where: is_nil(s.logoff_timestamp)
      )
      |> Repo.one!()

    assert session.logoff_timestamp == nil
    assert session.logon_status == 0  # success

    # Monitor the router so we know when it's done
    ref = Process.monitor(router_pid)

    # Stop the router (this will trigger terminate/2)
    GenServer.stop(router_pid)

    # Wait for the DOWN message
    assert_receive {:DOWN, ^ref, :process, ^router_pid, _reason}, 1000

    # Give it a moment to complete database operations
    Process.sleep(100)

    # Verify session was closed with abnormal status
    updated_session = Repo.get!(Session, session.id)
    assert updated_session.logoff_timestamp != nil
    assert updated_session.logoff_status == 1  # abnormal
  end

  test "concurrency_limit nil defaults to 1", _context do
    %Household{id: "AAAA16", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA16A", gender: "F", date_enrolled: @today, concurrency_limit: nil}
      |> User.changeset(%{password: "test"})
    ])
    |> Repo.insert!()

    {:ok, router1} = GenServer.start_link(Router, nil)
    {:ok, router2} = GenServer.start_link(Router, nil)

    # First should succeed
    {:ok, response1} = logon(router1, "AAAA16A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status1, _rest::binary>>}} = DiaPacket.decode(response1)
    assert status1 == Status.SUCCESS.value()

    # Second should fail
    {:ok, response2} = logon(router2, "AAAA16A", "test", "06.03.10")
    {:ok, %Fm0{payload: <<status2, _rest::binary>>}} = DiaPacket.decode(response2)
    assert status2 == Status.ID_IN_USE.value()

    # Clean up
    GenServer.stop(router1)
    GenServer.stop(router2)
  end
end
