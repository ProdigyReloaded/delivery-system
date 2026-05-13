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

defmodule Prodigy.Server.TcsWebSocket do
  @moduledoc """
  WebSock handler that terminates a TCS-over-WebSocket connection from a
  browser-hosted DOSBox WASM client. Spawns a linked TCS protocol
  GenServer configured with `Prodigy.Server.Transport.Websocket`,
  forwards inbound binary frames to it as `{:data_in, data}` messages,
  and turns the GenServer's outbound `{:tcs_out, iodata}` messages into
  binary frames back out the socket.

  Not to be confused with `Prodigy.Server.TcsListener` (the raw-TCP Ranch
  listener for real hardware DOS clients, still live on port 25234).
  """

  require Logger

  alias Prodigy.Server.Protocol.Tcs

  @behaviour WebSock

  # Server-side ping cadence. Must be less than the idle_timeout set on
  # the WebSockAdapter.upgrade call in TcsUpgradeController, so a living
  # client always has an opportunity to respond before Cowboy treats the
  # connection as stale.
  @ping_interval_ms 30_000

  @impl WebSock
  def init(opts) do
    Logger.debug("TCS WebSocket: handler init, spawning protocol GenServer")
    # Trap exits so we can turn the linked TCS process's termination into
    # a clean WebSocket close frame instead of a hard crash.
    Process.flag(:trap_exit, true)

    peer_info =
      case opts do
        list when is_list(list) -> Keyword.get(list, :peer_info, %{})
        _ -> %{}
      end

    handler_pid = self()

    tcs_pid =
      :proc_lib.spawn_link(fn ->
        Tcs.enter_loop_for_websocket(handler_pid, peer_info)
      end)

    schedule_ping()

    {:ok, %{tcs_pid: tcs_pid}}
  end

  @impl WebSock
  def handle_in({data, [opcode: :binary]}, %{tcs_pid: tcs_pid} = state) do
    send(tcs_pid, {:data_in, data})
    {:ok, state}
  end

  def handle_in({_data, [opcode: other]}, state) do
    Logger.warning("TCS WebSocket: ignoring #{inspect(other)} frame (expected :binary)")
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:tcs_out, data}, state) do
    {:push, {:binary, IO.iodata_to_binary(data)}, state}
  end

  def handle_info(:tcs_close, state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{tcs_pid: pid} = state) do
    Logger.debug("TCS WebSocket: protocol GenServer exited (#{inspect(reason)}); closing")
    {:stop, :normal, state}
  end

  # Periodic application-level ping. Cowboy answers inbound pings itself;
  # this one goes the other way - a dead client won't return the pong,
  # no frames will arrive, and the idle_timeout set on upgrade will fire
  # and close the socket within the window.
  def handle_info(:send_ping, state) do
    schedule_ping()
    {:push, {:ping, ""}, state}
  end

  def handle_info(other, state) do
    Logger.debug("TCS WebSocket: ignored message #{inspect(other)}")
    {:ok, state}
  end

  defp schedule_ping, do: Process.send_after(self(), :send_ping, @ping_interval_ms)

  @impl WebSock
  def terminate(_reason, %{tcs_pid: tcs_pid}) do
    if Process.alive?(tcs_pid), do: Process.exit(tcs_pid, :shutdown)
    :ok
  end
end
