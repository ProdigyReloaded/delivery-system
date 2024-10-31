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

defmodule Prodigy.Server.Protocol.Tcs do
  @moduledoc """
  The TCS Protocol (Data Link Layer)

  TCS packet structure is described in Prodigy.Server.Protocl.Tcs.Packet

  The TCS protocol is responsible for:
  * append bytes from the reception system (in this case, via TCP connection) to a buffer
  * utilizing Prodigy.Server.Protocol.Tcs.Packet to decode the buffer and produce packet structures
  * handle protocol packets (Supervisory functions; send / receive ACKs, WACKs, etc)
  * pass data packets along to the DIA Protocol
  """

  require Logger
  use GenServer
  use EnumType

  alias Prodigy.Server.Protocol.Tcs.Packet
  alias Prodigy.Server.Protocol.Tcs.Packet.Type

  @behaviour :ranch_protocol
  @timeout 6_000_000
  @max_payload_size 128

  defmodule Options do
    @moduledoc "An options module used for mocking the DIA protocol instance in tests"
    alias Prodigy.Server.Protocol.Dia, as: DiaProtocol
    defstruct dia_module: DiaProtocol, ranch_module: :ranch
  end

  defmodule State do
    @moduledoc "A structure containing the state utilized through the lifecycle of a TCS connection"
    @enforce_keys [:socket, :transport, :dia_module, :dia_pid]
    defstruct [:socket, :transport, :dia_module, dia_pid: nil, buffer: <<>>, tx_seq: 0, rx_seq: 0]
  end

  @impl true
  def start_link(ref, transport, options) do
    Logger.debug("TCS Connection Opened")
    {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, options}])}
  end

  @impl GenServer
  def init({ref, transport, %Options{} = options}) do
    Logger.debug("TCS server initializing")
    Process.flag(:trap_exit, true)

    Logger.debug("TCS server spawning dia process")
    {:ok, dia_pid} = GenServer.start_link(options.dia_module, nil)

    Logger.debug("TCS server completing the client handshake")
    {:ok, socket} = options.ranch_module.handshake(ref)
    # results in what appears to be an RS hangup, but it isn't - it's that the socket doesn't
    # continue to poll - need active true to poll continuously
    :ok = transport.setopts(socket, active: true)

    Logger.debug("TCS server entering genserver loop")

    :gen_server.enter_loop(__MODULE__, [], %State{
      socket: socket,
      transport: transport,
      dia_module: options.dia_module,
      dia_pid: dia_pid
    })
  end

  @impl GenServer
  def handle_call(:get_dia_pid, _from, state) do
    {:reply, state.dia_pid, state}
  end

  defp next_seq(seq) do
    Integer.mod(seq + 1, 256)
  end

  defp binary_chunk_every(payload, chunk_size, buffer \\ []) do
    len = byte_size(payload)

    if len <= chunk_size do
      buffer ++ [payload]
    else
      binary_chunk_every(
        :binary.part(payload, chunk_size, len - chunk_size),
        chunk_size,
        buffer ++ [:binary.part(payload, 0, chunk_size)]
      )
    end
  end

  @impl GenServer
  def handle_info({:tcp, _socket, data}, %State{socket: socket, transport: transport} = state) do
    {new_buffer, new_tx_seq, new_rx_seq} =
      case Packet.decode(state.buffer <> data) do
        {:ok, packet, excess} ->
          handle_packet_in({packet, excess}, packet.type, state)

        # data packet

        {:error, :crc, seq, excess} ->
          transport.send(socket, Packet.nakcce(seq))
          {excess, state.tx_seq, state.rx_seq}

        {:fragment, excess} ->
          {excess, state.tx_seq, state.rx_seq}
      end

    {:noreply, %{state | buffer: new_buffer, tx_seq: new_tx_seq, rx_seq: new_rx_seq}, @timeout}
  end

  @impl GenServer
  def handle_info({:tcp_closed, socket}, %State{transport: transport} = state) do
    Logger.debug("TCS connection closed")
    transport.close(socket)
    {:stop, :shutdown, state}
  end

  @impl GenServer
  def handle_info(code, %State{transport: transport} = state) do
    Logger.debug("TCS server got ranch error: #{inspect(code)}")
    transport.close(state.socket)
    {:stop, :shutdown, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_packet_in({packet, excess}, packet_type, state)
      when packet_type in [Type.UD1ACK, Type.UD1NAK, Type.UD2ACK, Type.UD2NAK] do
    if packet.seq != state.rx_seq do
      Logger.debug("incorrect receive sequence #{packet.seq}; expected #{state.rx_seq}")
      state.transport.send(state.socket, Packet.nakncc(packet.seq))
      {excess, state.tx_seq, state.rx_seq}
    else
      new_rx_seq = next_seq(state.rx_seq)

      Logger.debug("received packet in sequence, next expected receive sequence #{new_rx_seq}")

      if packet.type in [Type.UD1ACK, Type.UD2ACK] do
        Logger.debug("sending ack of packet sequence #{packet.seq}")
        state.transport.send(state.socket, Packet.ackpkt(packet.seq))
      end

      new_tx_seq = handle_packet_out(packet, state)
      {excess, new_tx_seq, new_rx_seq}
    end
  end

  def handle_packet_in({_packet, excess}, Type.ACKPKT, state) do
    Logger.debug("ackpkt")
    {excess, state.tx_seq, state.rx_seq}
  end

  def handle_packet_in({_packet, excess}, Type.NAKCCE, state) do
    Logger.error("nakcce")
    {excess, state.tx_seq, state.rx_seq}
  end

  def handle_packet_in({_packet, excess}, Type.NAKNCC, state) do
    Logger.error("nakncc")
    {excess, state.tx_seq, state.rx_seq}
  end

  def handle_packet_in({_packet, excess}, Type.RXMITP, state) do
    Logger.error("rxmitp")
    {excess, state.tx_seq, state.rx_seq}
  end

  def handle_packet_in({packet, excess}, Type.WACKPK, state) do
    Logger.error("wackpk")
    state.transport.send(state.socket, Packet.rxmitp(packet.seq))
    {excess, state.tx_seq, state.rx_seq}
  end

  def handle_packet_in({_packet, excess}, Type.TXABOD, state) do
    Logger.error("txabod")
    {excess, state.tx_seq, state.rx_seq}
  end

  def handle_packet_out(packet, state) do
    case state.dia_module.handle_packet(state.dia_pid, packet) do
      :ok ->
        Logger.debug("nothing to return to client")
        state.tx_seq

      {:ok, response} ->
        [first | rest] = binary_chunk_every(response, @max_payload_size)
        out_packet = %Packet{seq: state.tx_seq, type: Type.UD1ACK, payload: first}

        Logger.debug("sending packet: #{inspect(out_packet, base: :hex, limit: :infinity)}")

        state.transport.send(state.socket, Packet.encode(out_packet))

        new_tx_seq = next_seq(state.tx_seq)

        Enum.reduce(rest, new_tx_seq, fn chunk, tx_seq ->
          out_packet = %Packet{seq: tx_seq, type: Type.UD2ACK, payload: chunk}

          Logger.debug("sending packet: #{inspect(out_packet, base: :hex, limit: :infinity)}")

          state.transport.send(state.socket, Packet.encode(out_packet))
          next_seq(tx_seq)
        end)
    end
  end

  @impl GenServer
  def terminate(reason, _state) do
    Logger.debug("TCS server shutting down: #{inspect(reason)}")
    :normal
  end
end
