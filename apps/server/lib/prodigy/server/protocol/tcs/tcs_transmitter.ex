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

defmodule Prodigy.Server.Protocol.Tcs.Transmitter do
  use GenServer
  require Logger

  alias Prodigy.Server.Protocol.Tcs.{ErrorInjector, Packet}
  alias Prodigy.Server.Protocol.Tcs.TransmitBuffer
  alias Prodigy.Server.Protocol.Tcs.TransmitBuffer.PacketState

  @rs_buffer_size 8
  @wack_threshold 4
  # in seconds
  @default_wack_interval 10  # in seconds
  @default_run_interval 250

  # Public API

  def start_link(initial_state \\ %{}) do
    GenServer.start_link(__MODULE__, initial_state)
  end

  def send_code(pid, code, sequence) do
    GenServer.cast(pid, {code, sequence})
  end

  def transmit_packet(pid, packet, sequence) do
    GenServer.cast(pid, {:packet, packet, sequence})
  end

  # GenServer Callbacks

  @impl true
  def init(initial_state) do
    packet_queue = :queue.new()
    tx_buffer = TransmitBuffer.new(@rs_buffer_size)

    wack_interval = Map.get(initial_state, :wack_interval, @default_wack_interval)
    run_interval = Map.get(initial_state, :run_interval, @default_run_interval)

    # Initialize error injection if configured
    error_config = Map.get(initial_state, :error_injection, ErrorInjector.init())

    new_state = Map.merge(initial_state, %{
      packet_queue: packet_queue,
      tx_buffer: tx_buffer,
      wack_interval: wack_interval,
      run_interval: run_interval,
      error_injection: error_config
    })
    {:ok, new_state, {:continue, :schedule_run_checks}}
  end

  @impl true
  def handle_cast({:packet, packet, sequence}, state) do
    Logger.debug("Queuing packet with sequence: #{sequence}")
    new_queue = :queue.in({packet, sequence}, state.packet_queue)
    {:noreply, %{state | packet_queue: new_queue}, {:continue, :schedule_run_checks}}
  end

  @impl true
  def handle_cast({:ackpkt, sequence}, state) do
    Logger.debug("TCS TX: Processing ACKPKT for seq=#{sequence}")

    # Log current buffer state
    unacked_before = TransmitBuffer.get_unacked_sequences(state.tx_buffer)
    Logger.debug("TCS TX: Buffer before ACK - unacked sequences: #{inspect(unacked_before)}")

    new_buffer = TransmitBuffer.mark_acked(state.tx_buffer, sequence)

    unacked_after = TransmitBuffer.get_unacked_sequences(new_buffer)
    Logger.debug("TCS TX: Buffer after ACK - unacked sequences: #{inspect(unacked_after)}")

    send(self(), :run_checks)
    {:noreply, %{state | tx_buffer: new_buffer}}
  end

  @impl true
  def handle_cast({:nakcce, sequence}, state) do
    Logger.debug("TCS TX: Processing NAKCCE for seq=#{sequence}")

    case TransmitBuffer.get_by_sequence(state.tx_buffer, sequence) do
      %PacketState{packet: packet} = _packet_state ->
        Logger.debug("TCS TX: Resending packet seq=#{sequence} due to CRC error")
        state.transport.send(state.socket, packet)

        new_buffer = TransmitBuffer.update_by_sequence(state.tx_buffer, sequence, fn ps ->
          %{ps | nakcce_received: true}
        end)
        {:noreply, %{state | tx_buffer: new_buffer}}

      nil ->
        Logger.debug("TCS TX: NAKCCE for seq=#{sequence}, but no packet in buffer")
        {:noreply, state}
    end
  end
  @impl true
  def handle_cast({:nakncc, sequence}, state) do
    Logger.debug("NAKNCC received for sequence: #{sequence}")

    case TransmitBuffer.get_by_sequence(state.tx_buffer, sequence) do
      %PacketState{nakcce_received: true} ->
        Logger.debug("NAKNCC for sequence #{sequence}, but NAKCCE already handled")
        {:noreply, state}

      %PacketState{packet: packet} ->
        Logger.debug("Resending packet #{sequence} due to NAKNCC")
        state.transport.send(state.socket, packet)
        {:noreply, state}

      nil ->
        Logger.debug("NAKNCC for sequence: #{sequence}, but no packet in buffer")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:rxmitp, sequence}, state) do
    Logger.debug("TCS TX: RXMITP received for sequence #{sequence}")

    # Log current buffer state
    all_packets = TransmitBuffer.get_all_packets(state.tx_buffer)
    buffer_seqs = Enum.map(all_packets, fn {seq, _} -> seq end) |> Enum.sort()
    Logger.debug("TCS TX: Current buffer contains sequences: #{inspect(buffer_seqs)}")

    # Check if we have the requested sequence
    case TransmitBuffer.get_by_sequence(state.tx_buffer, sequence) do
      nil ->
        Logger.debug("TCS TX: Sequence #{sequence} NOT in buffer")
        # Log what we DO have
        Logger.debug("TCS TX: Buffer state - available sequences: #{inspect(buffer_seqs)}")
        {:noreply, state}

      %PacketState{packet: packet} ->
        Logger.debug("TCS TX: Found sequence #{sequence} in buffer, retransmitting")
        state.transport.send(state.socket, packet)

        # Also retransmit subsequent unacked packets
        all_packets
        |> Enum.filter(fn {seq, ps} -> seq > sequence and not ps.acked end)
        |> Enum.sort_by(fn {seq, _} -> seq end)
        |> Enum.each(fn {seq, %PacketState{packet: pkt}} ->
          Logger.debug("TCS TX: Also retransmitting sequence #{seq}")
          state.transport.send(state.socket, pkt)
        end)

        {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:schedule_run_checks, state) do
    Process.send_after(self(), :run_checks, state.run_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_checks, state) do
    # Check for packets needing WACK
    state = check_wack_timeouts(state)

    # Try to send new packets if buffer has space
    state = try_send_from_queue(state)

    {:noreply, state, {:continue, :schedule_run_checks}}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.debug("#{inspect(self())} Transmitter shutting down")
    :ok
  end

  # Private functions

  defp check_wack_timeouts(state) do
    now = DateTime.utc_now()
    unacked_seqs = TransmitBuffer.get_unacked_sequences(state.tx_buffer)

    new_buffer = Enum.reduce(unacked_seqs, state.tx_buffer, fn sequence, buffer ->
      case TransmitBuffer.get_by_sequence(buffer, sequence) do
        %PacketState{wack_count: wack_count, sent_time: sent_time} = ps when sent_time != nil ->
          if DateTime.diff(now, sent_time) >= state.wack_interval do
            handle_wack_timeout(state, buffer, sequence, ps, wack_count, now)
          else
            buffer
          end

        _ ->
          Logger.debug("No packet state or sent_time for unacked sequence #{sequence}")
          buffer
      end
    end)

    %{state | tx_buffer: new_buffer}
  end

  defp handle_wack_timeout(state, buffer, sequence, _packet_state, wack_count, now) do
    if wack_count >= @wack_threshold do
      Logger.debug("TCS TX: WACK threshold reached for seq=#{sequence}, aborting transmission")
      send(state.from, {:wp_limit_exceeded, state.socket})
      buffer
    else
      Logger.debug("TCS TX: Sending WACKPK for seq=#{sequence}, attempt #{wack_count}")
      state.transport.send(state.socket, Packet.wackpk(sequence))

      TransmitBuffer.update_by_sequence(buffer, sequence, fn ps ->
        %{ps | wack_count: wack_count + 1, sent_time: now}
      end)
    end
  end

  defp try_send_from_queue(state) do
    if TransmitBuffer.is_full?(state.tx_buffer) do
      state
    else
      case :queue.out(state.packet_queue) do
        {{:value, {packet, sequence}}, new_queue} ->
          Logger.debug("TCS TX: Actually sending packet with sequence #{sequence} to socket")

          # Apply error injection if configured
          packet_to_send = if state.error_injection && state.error_injection.enabled do
            ErrorInjector.maybe_corrupt(packet, state.error_injection, :send)
          else
            packet
          end

          state.transport.send(state.socket, packet_to_send)

          now = DateTime.utc_now()
          packet_state = %PacketState{
            nakcce_received: false,
            wack_count: 1,
            sent_time: now,
            packet: packet,  # Store original packet for retransmission
            transmitted: true,
            acked: false
          }

          case TransmitBuffer.add(state.tx_buffer, sequence, packet_state) do
            {:ok, new_buffer} ->
              # Log buffer state after adding
              all_seqs = TransmitBuffer.get_all_packets(new_buffer)
                         |> Enum.map(fn {seq, _} -> seq end)
                         |> Enum.sort()
              Logger.debug("TCS TX: Buffer now contains sequences: #{inspect(all_seqs)}")

              %{state | packet_queue: new_queue, tx_buffer: new_buffer}

            {:error, :buffer_full} ->
              Logger.error("TX buffer full, this shouldn't happen")
              state
          end

        {:empty, _} ->
          state
      end
    end
  end
end