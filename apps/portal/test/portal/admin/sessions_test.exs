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

defmodule Prodigy.Portal.Admin.SessionsTest do
  use Prodigy.Portal.DataCase, async: false

  alias Prodigy.Core.Data.Service.{Enroller, Session, User}
  alias Prodigy.Portal.Admin.Sessions

  defp subscriber!(id \\ "AAAA11") do
    {:ok, {_household, user}} = Enroller.create_subscriber(id, "SECRET", concurrency_limit: 1)
    user
  end

  defp insert_session!(%User{id: user_id}, attrs \\ %{}) do
    defaults = %{
      user_id: user_id,
      logon_timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      logon_status: 0,
      rs_version: "06.03.17",
      node: to_string(node()),
      pid: pid_to_string(self()),
      source_address: "127.0.0.1",
      source_port: 1234,
      transport: "tcp"
    }

    %Session{}
    |> Session.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp pid_to_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()

  describe "list_online/0" do
    test "returns sessions with logoff_timestamp still nil, preloading user + household" do
      user = subscriber!()
      _online = insert_session!(user)

      assert [row] = Sessions.list_online()
      assert row.user.id == user.id
      assert row.user.household.id == user.household_id
    end

    test "excludes sessions that have already logged off" do
      user = subscriber!()
      insert_session!(user, %{logoff_timestamp: DateTime.utc_now() |> DateTime.truncate(:second)})

      assert Sessions.list_online() == []
    end

    test "orders by logon_timestamp desc (newest first)" do
      user = subscriber!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      older = DateTime.add(now, -60, :second)

      insert_session!(user, %{logon_timestamp: older, pid: pid_to_string(self())})
      # Spawn a second pid so the session rows have distinct pid strings.
      other_pid = spawn(fn -> receive do: (_ -> :ok) end)
      insert_session!(user, %{logon_timestamp: now, pid: pid_to_string(other_pid)})

      [first, second] = Sessions.list_online()
      assert DateTime.compare(first.logon_timestamp, second.logon_timestamp) == :gt
    end
  end

  describe "disconnect/1" do
    test "returns {:error, :no_pid_recorded} when the session has no pid" do
      session = %Session{pid: nil}
      assert Sessions.disconnect(session) == {:error, :no_pid_recorded}
    end

    test "refuses remote-node sessions rather than guessing an RPC call" do
      user = subscriber!()
      remote = insert_session!(user, %{node: "nobody@nowhere"})

      assert {:error, {:remote_node, :"nobody@nowhere"}} = Sessions.disconnect(remote)
    end

    test "stamps logoff + :forced status when the pid is already gone" do
      user = subscriber!()
      # Spawn and let it exit so the pid is stale.
      stale_pid = spawn(fn -> :ok end)
      :timer.sleep(10)
      refute Process.alive?(stale_pid)

      stale = insert_session!(user, %{pid: pid_to_string(stale_pid)})
      assert {:error, :stale} = Sessions.disconnect(stale)

      reloaded = Repo.get!(Session, stale.id)
      assert reloaded.logoff_timestamp != nil
      assert reloaded.logoff_status == 3
    end

    test "stamps :forced and returns :stale when pid_string is malformed" do
      user = subscriber!()
      bogus = insert_session!(user, %{pid: "not a pid"})

      assert {:error, :stale} = Sessions.disconnect(bogus)

      reloaded = Repo.get!(Session, bogus.id)
      assert reloaded.logoff_timestamp != nil
      assert reloaded.logoff_status == 3
    end

    test "signals :shutdown to a live pid and returns :ok" do
      user = subscriber!()

      target =
        spawn(fn ->
          receive do
            _ -> :ok
          end
        end)

      session = insert_session!(user, %{pid: pid_to_string(target)})

      # Monitor so we can wait for the exit without sleeping.
      ref = Process.monitor(target)
      assert Sessions.disconnect(session) == :ok
      assert_receive {:DOWN, ^ref, :process, ^target, :shutdown}, 500
    end
  end
end
