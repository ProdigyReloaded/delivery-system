defmodule Prodigy.Server.Protocol.Tcs.ReceiveBuffer do
  @moduledoc """
  Circular buffer for managing the receive window with proper sequence number handling
  """

  defstruct [
    :size,
    :buffer,        # Array of packets or :pending
    :base_seq,      # Sequence number at position 0
    :next_expected, # Next sequence we expect to receive
    :wrap_point     # 256 for this protocol
  ]

  def new(size \\ 2, start_seq \\ 0) do
    %__MODULE__{
      size: size,
      buffer: :array.new(size, default: :pending),
      base_seq: start_seq,
      next_expected: start_seq,
      wrap_point: 256
    }
  end

  @doc """
  Add a packet to the buffer if it's within the window
  """
  def add_packet(rb, packet) do
    case get_buffer_position(rb, packet.seq) do
      {:ok, position} ->
        new_buffer = :array.set(position, packet, rb.buffer)
        {:ok, %{rb | buffer: new_buffer}}

      {:error, :outside_window} ->
        {:error, :outside_window, rb.base_seq}
    end
  end

  @doc """
  Check if a sequence number is within our receive window
  """
  def in_window?(rb, seq) do
    # Calculate forward distance accounting for wrap
    distance = calculate_forward_distance(seq, rb.base_seq, rb.wrap_point)
    distance < rb.size
  end

  #
  # Calculate forward distance between sequences with wrap-around
  #
  defp calculate_forward_distance(seq, base, wrap_point) do
    if seq >= base do
      seq - base
    else
      # seq has wrapped around
      (wrap_point - base) + seq
    end
  end

  #
  # Get the position in the buffer for a given sequence number
  #
  defp get_buffer_position(rb, seq) do
    distance = calculate_forward_distance(seq, rb.base_seq, rb.wrap_point)
    if distance < rb.size do
      {:ok, distance}
    else
      {:error, :outside_window}
    end
  end

  @doc """
  Check for missing packets and return list of sequences that need NAK
  """
  def get_missing_sequences(rb) do
    # Find the highest sequence we've received
    highest_received_distance = find_highest_received_distance(rb)

    case highest_received_distance do
      nil ->
        [] # No packets received yet, nothing missing

      max_distance ->
        # Check all positions up to and including the highest received
        # Array indices are 0-based, distances are 0-based
        Enum.reduce(0..max_distance, [], fn distance, acc ->
          # Only check if we need a NAK if there's a packet after this position
          has_later_packet = distance < max_distance

          case {:array.get(distance, rb.buffer), has_later_packet} do
            {:pending, true} ->
              # Missing packet with later packets received
              seq = rem(rb.base_seq + distance, rb.wrap_point)
              [seq | acc]
            _ ->
              acc
          end
        end) |> Enum.reverse()
    end
  end

  defp find_highest_received_distance(rb) do
    # Check from highest possible position down to 0
    # We need to check within the actual buffer size
    max_check = rb.size - 1

    Enum.reduce_while(max_check..0, nil, fn distance, _acc ->
      case :array.get(distance, rb.buffer) do
        :pending -> {:cont, nil}
        _packet -> {:halt, distance}
      end
    end)
  end

  @doc """
  Process packets in sequence order, returning completed packets and advancing window
  """
  def take_sequential_packets(rb) do
    {packets, new_rb} = take_sequential_packets_impl(rb, [])
    {Enum.reverse(packets), new_rb}
  end

  defp take_sequential_packets_impl(rb, acc) do
    case :array.get(0, rb.buffer) do
      :pending ->
        {acc, rb}

      packet ->
        # We have a packet at the head, advance the window
        new_buffer = slide_buffer(rb.buffer)
        new_base = rem(rb.base_seq + 1, rb.wrap_point)
        new_next = rem(rb.next_expected + 1, rb.wrap_point)

        new_rb = %{rb |
          buffer: new_buffer,
          base_seq: new_base,
          next_expected: new_next
        }

        take_sequential_packets_impl(new_rb, [packet | acc])
    end
  end

  #
  # Slide the buffer left by one position
  #
  defp slide_buffer(buffer) do
    size = :array.size(buffer)
    new_buffer = :array.new(size, default: :pending)

    Enum.reduce(1..(size - 1), new_buffer, fn i, acc ->
      :array.set(i - 1, :array.get(i, buffer), acc)
    end)
  end

  @doc """
  Reset the buffer when we get an RXMITP (retransmit) request
  """
  def reset(rb, new_base_seq) do
    %{rb |
      buffer: :array.new(rb.size, default: :pending),
      base_seq: new_base_seq,
      next_expected: new_base_seq
    }
  end

  @doc """
  Get the number of sequential packets ready for processing
  """
  def count_ready_packets(rb) do
    Enum.reduce_while(0..(rb.size - 1), 0, fn i, acc ->
      case :array.get(i, rb.buffer) do
        :pending -> {:halt, acc}
        _packet -> {:cont, acc + 1}
      end
    end)
  end

  @doc """
  Get status summary for debugging
  """
  def status(rb) do
    buffer_status = Enum.map(0..(rb.size - 1), fn i ->
      seq = rem(rb.base_seq + i, rb.wrap_point)
      case :array.get(i, rb.buffer) do
        :pending -> {seq, :pending}
        _packet -> {seq, :received}
      end
    end)

    %{
      base_seq: rb.base_seq,
      next_expected: rb.next_expected,
      window: buffer_status,
      missing: get_missing_sequences(rb)
    }
  end

  @doc """
  Get the status of a specific sequence number in the buffer.
  Returns :received if packet is in buffer, :pending if slot is empty, or :outside_window
  """
  def get_packet_status(rb, seq) do
    case get_buffer_position(rb, seq) do
      {:ok, position} ->
        case :array.get(position, rb.buffer) do
          :pending -> :pending
          _packet -> :received
        end
      {:error, :outside_window} ->
        :outside_window
    end
  end
end