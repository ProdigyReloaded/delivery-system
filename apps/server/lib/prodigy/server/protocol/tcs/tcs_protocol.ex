# Copyright 2022-2025, Phillip Heller & Ralph Richard Cook
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

  alias Prodigy.Server.Protocol.Tcs.{ErrorInjector, Packet}
  alias Prodigy.Server.Protocol.Tcs.Packet.Type
  alias Prodigy.Server.Protocol.Tcs.ReceiveBuffer
  alias Prodigy.Server.Protocol.Tcs.Transmitter

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
    defstruct [
      :socket,
      :transport,
      :dia_module,
      :rx_buffer,
      dia_pid: nil,
      tx_pid: nil,
      buffer: <<>>,
      tx_seq: 0,
      rx_seq: 0,
      error_injection: nil
    ]
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
    :ok = transport.setopts(socket, active: true)

    Logger.debug("TCS server entering genserver loop")

    # Configure error injection from environment
    error_config = configure_error_injection()

    {:ok, tx_pid} = Transmitter.start_link(%{
      transport: transport,
      socket: socket,
      from: self(),
      error_injection: error_config
    })

    :gen_server.enter_loop(__MODULE__, [], %State{
      socket: socket,
      transport: transport,
      dia_module: options.dia_module,
      rx_buffer: ReceiveBuffer.new(2, 0),
      dia_pid: dia_pid,
      tx_pid: tx_pid,
      error_injection: error_config  # Store for receive-side errors
    })
  end

  defp configure_error_injection do
    case System.get_env("TCS_ERROR_INJECTION") do
      nil ->
        ErrorInjector.init(enabled: false)

      "light" ->
        Logger.warning("TCS: Error injection enabled - LIGHT (1% error rate)")
        ErrorInjector.init(
          enabled: true,
          error_rate: 0.01,
          error_types: [:bit_flip],
          target: :both
        )

      "moderate" ->
        Logger.warning("TCS: Error injection enabled - MODERATE (5% error rate)")
        ErrorInjector.init(
          enabled: true,
          error_rate: 0.05,
          error_types: [:bit_flip, :byte_corruption],
          target: :both
        )

      "heavy" ->
        Logger.warning("TCS: Error injection enabled - HEAVY (10% error rate)")
        ErrorInjector.init(
          enabled: true,
          error_rate: 0.10,
          error_types: [:bit_flip, :byte_corruption, :truncation],
          target: :both
        )

      "chaos" ->
        Logger.warning("TCS: Error injection enabled - CHAOS MODE (25% error rate)")
        ErrorInjector.init(
          enabled: true,
          error_rate: 0.25,
          error_types: [:bit_flip, :byte_corruption, :truncation, :noise],
          target: :both
        )

      _ ->
        ErrorInjector.init(enabled: false)
    end
  end


  @impl GenServer
  def handle_call(:get_dia_pid, _from, state) do
    {:reply, state.dia_pid, state}
  end

  @spec next_seq(integer()) :: integer()
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
    # Apply error injection to received data if configured
    _corrupted_data = ErrorInjector.maybe_corrupt(
      data,
      Map.get(state, :error_injection, %ErrorInjector{enabled: false}),
      :receive
    )

    {new_buffer, new_tx_seq, new_rx_seq, rx_buffer} =
      case Packet.decode(state.buffer <> data) do
        {:ok, %Packet{} = packet, excess} ->
          handle_packet_in({packet, excess}, packet.type, state)

        {:error, :crc, _seq, excess} ->
          # Don't trust seq from corrupted packet
          # Send NAKCCE for next expected sequence
          next_expected = state.rx_buffer.next_expected
          Logger.debug("TCS: CRC error in packet, sending NAKCCE for expected seq=#{next_expected}")
          transport.send(socket, Packet.nakcce(next_expected))
          {excess, state.tx_seq, state.rx_seq, state.rx_buffer}

        {:fragment, excess} ->
          {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
      end

    {:noreply,
      %{state | buffer: new_buffer, tx_seq: new_tx_seq, rx_seq: new_rx_seq, rx_buffer: rx_buffer},
      @timeout}
  end

  @impl GenServer
  def handle_info({:wp_limit_exceeded, socket}, state) do
    Logger.debug("Too many wackpk packets sent, closing connection")
    send(self(), {:tcp_closed, socket})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:tcp_closed, socket}, %State{transport: transport} = state) do
    Logger.debug("TCS connection closed")
    transport.close(socket)
    {:stop, :shutdown, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(code, %State{transport: transport} = state) do
    Logger.debug("TCS server got ranch error: #{inspect(code)}")
    transport.close(state.socket)
    {:stop, :shutdown, state}
  end

  @doc """
  Handle incoming data packets
  """
  def handle_packet_in({%Packet{} = packet, excess}, packet_type, state)
      when packet_type in [Type.UD1ACK, Type.UD1NAK, Type.UD2ACK, Type.UD2NAK] do

    Logger.debug("TCS: Received data packet type=#{packet_type}, seq=#{packet.seq}")

    case ReceiveBuffer.add_packet(state.rx_buffer, packet) do
      {:ok, updated_buffer} ->
        missing_seqs = ReceiveBuffer.get_missing_sequences(updated_buffer)

        if Enum.empty?(missing_seqs) do
          {packets, new_buffer} = ReceiveBuffer.take_sequential_packets(updated_buffer)

          if not Enum.empty?(packets) do
            Enum.each(packets, fn pkt ->
              if pkt.type in [Type.UD1ACK, Type.UD2ACK] do
                Logger.debug("TCS: Sending ACKPKT for seq=#{pkt.seq}")
                state.transport.send(state.socket, Packet.ackpkt(pkt.seq))
              end
            end)

            {new_tx_seq, final_buffer} =
              Enum.reduce(packets, {state.tx_seq, new_buffer}, fn pkt, {tx_seq, buf} ->
                process_packet_to_dia(pkt, state, buf, tx_seq)
              end)

            new_rx_seq = final_buffer.next_expected
            {excess, new_tx_seq, new_rx_seq, final_buffer}
          else
            {excess, state.tx_seq, state.rx_seq, updated_buffer}
          end
        else
          Logger.debug("TCS: Missing packets in window: #{inspect(missing_seqs)}, sending NACKNCCs")

          Enum.each(missing_seqs, fn seq ->
            Logger.debug("TCS: Sending NAKNCC for missing seq=#{seq}")
            state.transport.send(state.socket, Packet.nakncc(seq))
          end)

          {excess, state.tx_seq, state.rx_seq, updated_buffer}
        end

      {:error, :outside_window, window_start} ->
        Logger.debug("TCS: Packet seq=#{packet.seq} outside window, sending RXMITP for seq=#{window_start}")
        state.transport.send(state.socket, Packet.rxmitp(window_start))

        new_buffer = ReceiveBuffer.reset(state.rx_buffer, window_start)
        {excess, state.tx_seq, window_start, new_buffer}
    end
  end

  def handle_packet_in({packet, excess}, Type.ACKPKT, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.debug("TCS: Received ACKPKT for seq=#{payload_seq}")
    Transmitter.send_code(state.tx_pid, :ackpkt, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
  end

  def handle_packet_in({packet, excess}, Type.NAKCCE, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.debug("TCS: Received NAKCCE for seq=#{payload_seq}, resending packet")
    Transmitter.send_code(state.tx_pid, :nakcce, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
  end

  def handle_packet_in({packet, excess}, Type.NAKNCC, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.debug("TCS: Received NAKNCC for seq=#{payload_seq}")
    Transmitter.send_code(state.tx_pid, :nakncc, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
  end

  def handle_packet_in({packet, excess}, Type.RXMITP, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.debug("TCS: Received RXMITP for seq=#{payload_seq}, retransmitting from that sequence")
    Transmitter.send_code(state.tx_pid, :rxmitp, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
  end

  def handle_packet_in({packet, excess}, Type.WACKPK, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.debug("TCS: Received WACKPK for seq=#{payload_seq}")

    case ReceiveBuffer.get_packet_status(state.rx_buffer, payload_seq) do
      :received ->
        # In window and received, send ACK
        Logger.debug("TCS: Packet seq=#{payload_seq} was received, sending ACKPKT")
        state.transport.send(state.socket, Packet.ackpkt(payload_seq))
        {excess, state.tx_seq, state.rx_seq, state.rx_buffer}

      :pending ->
        # In window but not received, send NAKNCC
        Logger.debug("TCS: Packet seq=#{payload_seq} NOT received, sending NAKNCC")
        state.transport.send(state.socket, Packet.nakncc(payload_seq))
        {excess, state.tx_seq, state.rx_seq, state.rx_buffer}

      :outside_window ->
        # Outside window, send RXMITP for next expected sequence
        next_expected = state.rx_buffer.next_expected
        Logger.debug("TCS: WACKPK for seq=#{payload_seq} outside window, sending RXMITP for seq=#{next_expected}")
        state.transport.send(state.socket, Packet.rxmitp(next_expected))
        {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
    end
  end

  def handle_packet_in({_packet, excess}, Type.TXABOD, state) do
    Logger.debug("TCS: Received TXABOD - transmission aborted by remote")
    {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
  end

  defp process_packet_to_dia(packet, state, rx_buffer, tx_seq) do
    case state.dia_module.handle_packet(state.dia_pid, packet) do
      :ok ->
        Logger.debug("Nothing to return to client")
        {tx_seq, rx_buffer}

      {:ok, response} ->
        [first | rest] = binary_chunk_every(response, @max_payload_size)
        out_packet = %Packet{seq: tx_seq, type: Type.UD1ACK, payload: first}

        Logger.debug("TCS: Sending data packet type=UD1ACK, seq=#{tx_seq}, queuing for transmission")

        encoded_packet = Packet.encode(out_packet)
        Transmitter.transmit_packet(state.tx_pid, encoded_packet, tx_seq)

        new_tx_seq = next_seq(tx_seq)

        last_tx_seq =
          Enum.reduce(rest, new_tx_seq, fn chunk, current_tx_seq ->
            out_packet = %Packet{seq: current_tx_seq, type: Type.UD2ACK, payload: chunk}

            Logger.debug("TCS: Sending data packet type=UD2ACK, seq=#{current_tx_seq}, queuing for transmission")

            encoded_packet = Packet.encode(out_packet)
            Transmitter.transmit_packet(state.tx_pid, encoded_packet, current_tx_seq)

            next_seq(current_tx_seq)
          end)

        {last_tx_seq, rx_buffer}
    end
  end


  @impl GenServer
  def terminate(reason, _state) do
    Logger.debug("TCS server shutting down: #{inspect(reason)}")
    :normal
  end
end