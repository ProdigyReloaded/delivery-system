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
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm2}
  alias Prodigy.Server.Protocol.Tcs.Packet, as: TcsPacket

  defmodule Options do
    @moduledoc "An options module used for mocking `Prodigy.Server.Router` in tests"
    alias Prodigy.Server.Router
    # peer_info and transport_type are populated by TCS.init from the
    # underlying socket / WebSock upgrade, passed down to Router so the
    # Context carries the fields the admin "Who's online" tab surfaces.
    defstruct router_module: Router, peer_info: nil, transport_type: nil
  end

  defmodule State do
    @moduledoc false
    # fm2_blocks: accumulated application-text payloads for an in-flight
    # multi-block FM2 message. Per the DIA spec (section 3.1.2) a logical
    # message > 1K is sent as a series of DIA packets each carrying its
    # own Fm0 + Fm2 header; only the block_num varies. We buffer until
    # the last block arrives, then concatenate and dispatch.
    defstruct router_module: Prodigy.Server.Router,
              router_pid: nil,
              buffer: <<>>,
              fm2_blocks: <<>>
  end

  def handle_packet(pid, %TcsPacket{} = packet) do
    GenServer.call(pid, {:packet, packet.payload})
  end

  def get_router_pid(pid) do
    GenServer.call(pid, :get_router_pid)
  end

  @impl GenServer
  def init(%Options{router_module: router_module} = options) do
    Logger.debug("DIA protocol server initializing")
    Process.flag(:trap_exit, true)

    Logger.debug("DIA server starting a router")

    router_opts = %{
      peer_info: options.peer_info || %{},
      transport_type: options.transport_type
    }

    {:ok, router_pid} = GenServer.start_link(router_module, router_opts)
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

  # Multi-block FM2: not the final block. Buffer this block's payload
  # and clear the TCS-level buffer so the next packet decodes fresh.
  # Send no response - the client doesn't expect one per intermediate
  # block (a server reply would trip the same OMCM 10 "out of sequence
  # message received" path documented in fm0_packet.ex).
  defp process_packet(
         %Fm0{fm2: %Fm2{num_blocks: num_blocks, block_num: block_num}, payload: payload},
         %State{} = state
       )
       when num_blocks > 1 and block_num < num_blocks do
    Logger.debug("DIA Fm2: received block #{block_num} of #{num_blocks}, buffering")
    {:ok, %{state | buffer: <<>>, fm2_blocks: state.fm2_blocks <> payload}}
  end

  # Multi-block FM2: final block. Concatenate any buffered earlier blocks
  # with this one and dispatch the reassembled application text as a
  # single logical packet. The packet handed to the router carries the
  # final Fm0/Fm2 metadata; downstream services see the full payload.
  defp process_packet(
         %Fm0{fm2: %Fm2{num_blocks: num_blocks, block_num: block_num}, payload: payload} =
           packet,
         %State{} = state
       )
       when num_blocks > 0 and block_num == num_blocks do
    Logger.debug("DIA Fm2: received final block #{block_num} of #{num_blocks}, dispatching")

    reassembled = %Fm0{packet | payload: state.fm2_blocks <> payload}

    case state.router_module.handle_packet(state.router_pid, reassembled) do
      {:ok, response} -> {:ok, response, %{state | buffer: <<>>, fm2_blocks: <<>>}}
      _ -> {:ok, %{state | buffer: <<>>, fm2_blocks: <<>>}}
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
  def terminate(reason, _state) do
    Logger.debug("DIA server shutting down: #{inspect(reason)}")
    #    Process.exit(state.router_pid, :shutdown)
    :normal
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end
end
