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

defmodule Prodigy.Server.SessionCleanup do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    Process.flag(:trap_exit, true)

    # Startup sweep: any session still marked open on cold boot is residue
    # from a previous run that didn't complete terminate/2 cleanly (SIGKILL,
    # crash, container rebuild before the shutdown hook drained). Close
    # those rows now so the admin "Who's online" view starts honest.
    # SessionCleanup is the first child in the server supervisor, so by the
    # time this runs the Repo supervisor is up but no new sessions can be
    # accepted yet (Ranch + endpoint come after). We sweep ALL open rows
    # rather than scoping by node, because the BEAM node name is derived
    # from the container hostname and changes across rebuilds.
    case Prodigy.Server.SessionManager.cleanup_all_open_sessions() do
      {count, _} when is_integer(count) and count > 0 ->
        Logger.info("SessionCleanup: swept #{count} stale session(s) from previous run")

      _ ->
        :ok
    end

    {:ok, %{}}
  end

  def terminate(_reason, _state) do
    Logger.info("SessionCleanup terminating, cleaning up all sessions...")

    try do
      # Force synchronous cleanup with a timeout
      Task.async(fn ->
        Prodigy.Server.SessionManager.cleanup_node_sessions(Atom.to_string(node()))
      end)
      |> Task.await(5000)

      Logger.info("Sessions cleaned up")
    rescue
      e ->
        Logger.error("Session cleanup failed: #{inspect(e)}")
    end

    :ok
  end
end