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

    Logger.debug("TCS server completing the Ranch client handshake")
    {:ok, socket} = options.ranch_module.handshake(ref)
    # Ranch-specific: put the socket into active mode so data arrives as
    # {:tcp, socket, data} messages. The WebSocket path does not do this -
    # its handler delivers {:data_in, data} instead.
    :ok = transport.setopts(socket, active: true)

    peer_info = peer_info_from_tcp(transport, socket)

    {:ok, dia_pid} =
      GenServer.start_link(
        options.dia_module,
        %Prodigy.Server.Protocol.Dia.Options{
          peer_info: peer_info,
          transport_type: "tcp"
        }
      )

    enter_loop(normalize_transport(transport), socket, options, dia_pid)
  end

  defp peer_info_from_tcp(transport, socket) do
    case transport.peername(socket) do
      {:ok, {ip, port}} -> %{address: ip_to_string(ip), port: port}
      _ -> %{address: nil, port: nil}
    end
  end

  defp ip_to_string(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp ip_to_string(other) when is_binary(other), do: other
  defp ip_to_string(_), do: nil

  # Maps the Ranch-supplied `:ranch_tcp` atom to our named wrapper module
  # so the TCS state machine speaks to transports through a Prodigy-owned
  # surface. Other values (TestTransport in the test suite, etc.) pass
  # through unchanged so existing mocks keep working.
  defp normalize_transport(:ranch_tcp), do: Prodigy.Server.Transport.Tcp
  defp normalize_transport(other), do: other

  @doc """
  Entry point for non-Ranch transports (currently: WebSocket). Called from
  the WebSock handler after it upgrades the HTTP connection. Bypasses the
  Ranch handshake and active-mode setopts and walks straight into the
  GenServer loop with the supplied transport + socket. `peer_info` is a
  map `%{address: ip_string | nil, port: integer | nil}` extracted by the
  upgrade controller from the HTTP conn.
  """
  def enter_loop_for_websocket(handler_pid, peer_info \\ %{}, %Options{} = options \\ %Options{})
      when is_pid(handler_pid) and is_map(peer_info) do
    Logger.debug("TCS server initializing (WebSocket transport)")
    Process.flag(:trap_exit, true)

    {:ok, dia_pid} =
      GenServer.start_link(
        options.dia_module,
        %Prodigy.Server.Protocol.Dia.Options{
          peer_info: peer_info,
          transport_type: "websocket"
        }
      )

    enter_loop(Prodigy.Server.Transport.Websocket, handler_pid, options, dia_pid)
  end

  defp enter_loop(transport_mod, socket, options, dia_pid) when is_atom(transport_mod) do
    error_config = configure_error_injection()

    {:ok, tx_pid} =
      Transmitter.start_link(%{
        transport: transport_mod,
        socket: socket,
        from: self(),
        error_injection: error_config
      })

    :gen_server.enter_loop(__MODULE__, [], %State{
      socket: socket,
      transport: transport_mod,
      dia_module: options.dia_module,
      rx_buffer: ReceiveBuffer.new(2, 0),
      dia_pid: dia_pid,
      tx_pid: tx_pid,
      error_injection: error_config
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

  # Shared helper used by both the TCP and WebSocket ingress paths.
  defp process_incoming_bytes(data, %State{socket: socket, transport: transport} = state) do
    _corrupted_data =
      ErrorInjector.maybe_corrupt(
        data,
        Map.get(state, :error_injection, %ErrorInjector{enabled: false}),
        :receive
      )

    {new_buffer, new_tx_seq, new_rx_seq, rx_buffer} =
      case Packet.decode(state.buffer <> data) do
        {:ok, %Packet{} = packet, excess} ->
          handle_packet_in({packet, excess}, packet.type, state)

        {:error, :crc, _seq, excess} ->
          # Don't trust seq from corrupted packet.
          # Send NAKCCE for next expected sequence.
          next_expected = state.rx_buffer.next_expected

          Logger.debug(
            "TCS: CRC error in packet, sending NAKCCE for expected seq=#{next_expected}"
          )

          transport.send(socket, Packet.nakcce(next_expected))
          {excess, state.tx_seq, state.rx_seq, state.rx_buffer}

        {:fragment, excess} ->
          {excess, state.tx_seq, state.rx_seq, state.rx_buffer}
      end

    {:noreply,
     %{state | buffer: new_buffer, tx_seq: new_tx_seq, rx_seq: new_rx_seq, rx_buffer: rx_buffer},
     @timeout}
  end

  # Shared helper for both transport-close signals.
  defp handle_transport_closed(%State{transport: transport, socket: socket} = state) do
    Logger.debug("TCS connection closed")
    transport.close(socket)
    {:stop, :shutdown, state}
  end

  # Incoming bytes from the transport. Two message shapes reach this
  # GenServer: {:tcp, socket, data} when TCP-active-mode delivers from
  # Ranch, and {:data_in, data} when the WebSock handler forwards a
  # binary frame. Both feed the same decoder state.
  @impl GenServer
  def handle_info({:tcp, _socket, data}, state), do: process_incoming_bytes(data, state)

  @impl GenServer
  def handle_info({:data_in, data}, state), do: process_incoming_bytes(data, state)

  @impl GenServer
  def handle_info({:wp_limit_exceeded, _socket}, state) do
    Logger.debug("Too many wackpk packets sent, closing connection")
    handle_transport_closed(state)
  end

  # Peer close. TCP delivers {:tcp_closed, socket}; the WebSock handler
  # delivers the bare atom :data_closed.
  @impl GenServer
  def handle_info({:tcp_closed, _socket}, state), do: handle_transport_closed(state)

  @impl GenServer
  def handle_info(:data_closed, state), do: handle_transport_closed(state)

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

  @impl GenServer
  def handle_info({:rxmitp_reset_needed, sequence}, state) do
    Logger.debug("TCS: Transmission reset needed from sequence #{sequence}")

    # Reset our transmission sequence
    new_state = %{state | tx_seq: sequence}

    # Optionally notify DIA layer to resend data if needed
    # This depends on your protocol - you might need to:
    # 1. Clear any pending DIA packets
    # 2. Request retransmission from DIA layer

    {:noreply, new_state}
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
