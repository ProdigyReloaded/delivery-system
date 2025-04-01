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
  alias Prodigy.Server.Protocol.Tcs.Window
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
      :rx_window,
      dia_pid: nil,
      tx_pid: nil,
      buffer: <<>>,
      tx_seq: 0,
      rx_seq: 0
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
    # results in what appears to be an RS hangup, but it isn't - it's that the socket doesn't
    # continue to poll - need active true to poll continuously
    :ok = transport.setopts(socket, active: true)

    Logger.debug("TCS server entering genserver loop")

    {:ok, tx_pid} = Transmitter.start_link(%{transport: transport, socket: socket, from: self()})

    :gen_server.enter_loop(__MODULE__, [], %State{
      socket: socket,
      transport: transport,
      dia_module: options.dia_module,
      rx_window: Window.init(0, Window.receive_window_size()),
      dia_pid: dia_pid,
      tx_pid: tx_pid
    })
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
    {new_buffer, new_tx_seq, new_rx_seq, rx_window} =
      case Packet.decode(state.buffer <> data) do
        # complete packet, handle to see if in sequence, if it completes a DIA, etc.
        {:ok, %Packet{} = packet, excess} ->
          handle_packet_in({packet, excess}, packet.type, state)

        # complete but bad crc, scrambled, try again
        {:error, :crc, seq, excess} ->
          Logger.error("CRC error in incoming packet #{seq}, length: #{byte_size(excess)}")
          transport.send(socket, Packet.nakcce(seq))
          {excess, state.tx_seq, state.rx_seq, state.rx_window}

        # not a complete packet yet, get more bytes
        {:fragment, excess} ->
          {excess, state.tx_seq, state.rx_seq, state.rx_window}
      end

    {:noreply,
     %{state | buffer: new_buffer, tx_seq: new_tx_seq, rx_seq: new_rx_seq, rx_window: rx_window},
     @timeout}
  end

  @impl GenServer
  def handle_info({:wp_limit_exceeded, socket}, state) do
    Logger.error("Too many wackpk packets sent, closing connection")
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
  def handle_info(code, %State{transport: transport} = state) do
    Logger.debug("TCS server got ranch error: #{inspect(code)}")
    transport.close(state.socket)
    {:stop, :shutdown, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @doc """
  Called when handle_info has a complete TCS packet. The TCS packet is passed to send_tcs_packet_to_dia
  which will determine if this completes a DIA packet or if we need more TCS packets.
  Checks on the receive window are done here and acks or nacks, or 'we need more packets' are
  sent from here.
  """
  def handle_packet_in({%Packet{} = packet, excess}, packet_type, state)
      when packet_type in [Type.UD1ACK, Type.UD1NAK, Type.UD2ACK, Type.UD2NAK] do
    new_rx_window =
      case Window.add_packet(state.rx_window, state.rx_seq, packet) do
        {:ok, window} ->
          Logger.debug("Packet inside window range, added to window")
          window

        {:error, :outside_window, window_first} ->
          Logger.debug("Packet was outside window, receive sequence is #{window_first}")
          state.transport.send(state.socket, Packet.rxmitp(window_first))
          # We believe the RS is all messed up, with the rxmitp we tell it to start over
          Window.init(state.rx_window.window_start, Window.receive_window_size())
      end

    # Check to see if there are any out of sequence packets. If so, ask for them again
    packet_error_list = Window.check_packets(new_rx_window)
    # Logger.debug("Packet sequence errors this round is #{packet_error_list}")

    if !Enum.empty?(packet_error_list) do
      # XXX Logger.debug("incorrect receive sequence #{packet.seq}; expected #{state.rx_seq}")
      error_seqs = Enum.map(packet_error_list, &elem(&1, 0))
      Logger.warning("Out of sequence packets: #{error_seqs}")

      Enum.each(packet_error_list, fn {seq, function_atom} ->
        Logger.warning("Sending a #{function_atom} packet for #{seq}")
        state.transport.send(state.socket, apply(Packet, function_atom, [seq]))
      end)

      {excess, state.tx_seq, state.rx_seq, new_rx_window}
    else
      new_rx_seq = next_seq(state.rx_seq)

      Logger.debug("received packet in sequence, next expected receive sequence #{new_rx_seq}")

      if packet.type in [Type.UD1ACK, Type.UD2ACK] do
        Logger.debug("sending and caching ack of packet sequence #{packet.seq}")
        Cachex.put(:ack_tracker, {self(), packet.seq}, true)
        state.transport.send(state.socket, Packet.ackpkt(packet.seq))
      end

      {new_tx_seq, new_window} = send_tcs_packet_to_dia(packet, state, new_rx_window)
      {excess, new_tx_seq, new_rx_seq, new_window}
    end
  end

  # XXX put cache delete here
  def handle_packet_in({packet, excess}, Type.ACKPKT, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload

    Logger.debug(
      "incoming ackpkt of # #{payload_seq}, #{inspect(packet.payload, binaries: :as_binaries, limit: :infinity)}"
    )

    Transmitter.send_code(state.tx_pid, :ackpkt, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_window}
  end

  def handle_packet_in({packet, excess}, Type.NAKCCE, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.error("incoming nakcce on packet # #{payload_seq}, resending packet")

    Transmitter.send_code(state.tx_pid, :nakcce, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_window}
  end

  def handle_packet_in({packet, excess}, Type.NAKNCC, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.error("incoming nakncc on packet # #{payload_seq}")
    Transmitter.send_code(state.tx_pid, :nakncc, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_window}
  end

  def handle_packet_in({packet, excess}, Type.RXMITP, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload
    Logger.error("incoming rxmitp on packet # #{payload_seq}")
    Transmitter.send_code(state.tx_pid, :rxmitp, payload_seq)
    {excess, state.tx_seq, state.rx_seq, state.rx_window}
  end

  def handle_packet_in({packet, excess}, Type.WACKPK, state) do
    <<payload_seq::integer-size(8), _rest::binary>> = packet.payload

    Logger.error(
      "incoming wackpk on packet # #{payload_seq}, rx window start is  #{state.rx_window.window_start}"
    )
    {:ok, value} = Cachex.get(:ack_tracker, {self(), payload_seq})
    if (value) do
      Logger.debug("wackpk received for sequence: #{payload_seq}, but ack was sent")
      state.transport.send(state.socket, Packet.ackpkt(:binary.decode_unsigned(packet.payload)))
    else
      Logger.debug("wackpk received for sequence: #{payload_seq}, resending")
      state.transport.send(state.socket, Packet.nakncc(:binary.decode_unsigned(packet.payload)))
    end
    {excess, state.tx_seq, state.rx_seq, state.rx_window}
  end

  def handle_packet_in({_packet, excess}, Type.TXABOD, state) do
    Logger.error("txabod")
    {excess, state.tx_seq, state.rx_seq, state.rx_window}
  end

  @doc """
  Send a TCS packet to the DIA handler. The DIA handler will determine if this packet
  completes a DIA packet. An :ok means it needs more TCS packets for a complete DIA,
  {:ok, response} means that this completed a DIA packet and it handled the command.
  """
  def send_tcs_packet_to_dia(packet, state, in_window) do
    case state.dia_module.handle_packet(state.dia_pid, packet) do
      :ok ->
        Logger.debug("nothing to return to client")
        {state.tx_seq, in_window}

      {:ok, response} ->
        [first | rest] = binary_chunk_every(response, @max_payload_size)
        out_packet = %Packet{seq: state.tx_seq, type: Type.UD1ACK, payload: first}

        Logger.debug(
          "queuing packet # #{state.tx_seq}: #{inspect(out_packet, base: :hex, limit: :infinity)}"
        )

        encoded_packet = Packet.encode(out_packet)
        Transmitter.transmit_packet(state.tx_pid, encoded_packet, state.tx_seq)

        new_tx_seq = next_seq(state.tx_seq)

        last_tx_seq =
          Enum.reduce(rest, new_tx_seq, fn chunk, tx_seq ->
            out_packet = %Packet{seq: tx_seq, type: Type.UD2ACK, payload: chunk}

            Logger.debug(
              "queuing packet # #{tx_seq}: #{inspect(out_packet, base: :hex, limit: :infinity)}"
            )

            encoded_packet = Packet.encode(out_packet)
            Transmitter.transmit_packet(state.tx_pid, encoded_packet, tx_seq)

            next_seq(tx_seq)
          end)

        num_received_packets = Window.tcs_packets_used(in_window)

        {last_tx_seq,
         Window.init(in_window.window_start + num_received_packets, Window.receive_window_size())}
    end
  end

  @impl GenServer
  def terminate(reason, _state) do
    Logger.debug("TCS server shutting down: #{inspect(reason)}")
    :normal
  end
end
