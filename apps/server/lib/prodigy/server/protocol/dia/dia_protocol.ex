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

defmodule Prodigy.Server.Protocol.Dia do
  @moduledoc """
  The DIA Protocol (Network & Transport Layers)

  DIA packet structures are described in:
  * `Prodigy.Server.Protocol.Dia.Packet.Fm0`
  * `Prodigy.Server.Protocol.Dia.Packet.Fm4`
  * `Prodigy.Server.Protocol.Dia.Packet.Fm9`
  * `Prodigy.Server.Protocol.Dia.Packet.Fm64`

  The DIA protocol is responsible for:
  * Consuming consecutive `Prodigy.Server.Protocol.Tcs.Packet` structures always beginning with a
  `Prodigy.Server.Protocol.Tcs.Packet.Type.UD1ACK` and followed by 0 or more
  `Prodigy.Server.Protocol.Tcs.Packet.Type.UD2ACK` until the length specified in the
  `Prodigy.Server.Protocol.Dia.Packet.Fm0` has been reached.
  * Utilizing `Prodigy.Server.Protocol.Dia.Packet.decode/1` function to decode the buffer and produce packet structures
  * Passing decoded packets along to the `Prodigy.Server.Router`
  """

  require Logger
  use EnumType
  use GenServer

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Protocol.Tcs.Packet, as: TcsPacket

  defmodule Options do
    @moduledoc "An options module used for mocking `Prodigy.Server.Router` in tests"
    alias Prodigy.Server.Router
    defstruct router_module: Router
  end

  defmodule State do
    @moduledoc false
    defstruct router_module: Prodigy.Server.Router, router_pid: nil, buffer: <<>>
  end

  def handle_packet(pid, %TcsPacket{} = packet) do
    GenServer.call(pid, {:packet, packet.payload})
  end

  def get_router_pid(pid) do
    GenServer.call(pid, :get_router_pid)
  end

  @impl GenServer
  def init(%Options{router_module: router_module}) do
    Logger.debug("DIA protocol server initializing")
    Process.flag(:trap_exit, true)

    Logger.debug("DIA server starting a router")
    {:ok, router_pid} = GenServer.start_link(router_module, nil)
    {:ok, %State{router_module: router_module, router_pid: router_pid}}
  end

  @impl GenServer
  def init(_) do
    init(%Options{})
  end

  @impl GenServer
  def handle_call(:get_router_pid, _from, state) do
    {:reply, {:ok, state.router_pid}, state}
  end

  @doc """
  Receive function for DIA packets.

  handle_call is called by `Prodigy.Server.Protocol.Tcs` with complete TCS packets, concatenates these packets
  together as necessary, decodes them into DIA packet structures, then passes the resulting packet along to
  `Prodigy.Server.Router` for dispatch to the relevant Service.

  Any response from the Service will be returned here.  It is the responsibility of the Service to encode the
  response as response protocols may differ.  (E.g., `Prodigy.Server.Service.Tocs` replies with a
  `Prodigy.Server.Protocol.Tocs.Packet`, whereas `Prodigy.Server.Service.Messaging` replies with a
  `Prodigy.Server.Protocol.Dia.Fm0`.
  """
  @impl GenServer
  def handle_call({:packet, payload}, _from, %State{buffer: buffer} = state) do
    Logger.debug("DIA server got a packet")
    state = %{state | buffer: buffer <> payload}

    res =
      case DiaPacket.decode(state.buffer) do
        {:ok, packet} -> process_packet(packet, state)
        {:fragment, need: need, have: have} -> handle_fragment(need, have, state)
        {:error, reason} -> handle_error(reason, state)
      end

    case res do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:ok, response, new_state} ->
        {:reply, {:ok, response}, new_state}
    end
  end

  defp process_packet(%Fm0{} = packet, %State{} = state) do
    case state.router_module.handle_packet(state.router_pid, packet) do
      {:ok, response} -> {:ok, response, %{state | buffer: <<>>}}
      _ -> {:ok, %{state | buffer: <<>>}}
    end
  end

  defp handle_fragment(need, have, state) do
    Logger.debug("DIA server got a dia fragment; need #{need} bytes, have #{have} bytes")
    {:ok, state}
  end

  defp handle_error(:no_match, state) do
    Logger.error("DIA server unable to decode dia packet")
    # ignore the error for now
    {:ok, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("DIA server shutting down: #{inspect(reason)}")
    #    Process.exit(state.router_pid, :shutdown)
    :normal
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end
end
