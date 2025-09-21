defmodule Prodigy.Server.Protocol.Tcs.TransmitBuffer do
  @moduledoc """
  Fixed-size circular buffer for managing transmitted packets awaiting acknowledgment
  """

  defstruct [
    :size,
    :buffer,  # Array of {sequence, packet_state} or nil
    :head,    # Next write position
    :tail,    # Oldest unacked position
    :count    # Number of items in buffer
  ]

  defmodule PacketState do
    @moduledoc "State for a transmitted packet awaiting acknowledgment"
    defstruct [
      nakcce_received: false,
      wack_count: 1,
      sent_time: nil,
      packet: nil,
      transmitted: false,
      acked: false
    ]
  end

  def new(size \\ 8) do
    %__MODULE__{
      size: size,
      buffer: :array.new(size, default: nil),
      head: 0,
      tail: 0,
      count: 0
    }
  end

  def add(buffer, sequence, packet_state) do
    if buffer.count >= buffer.size do
      {:error, :buffer_full}
    else
      new_buffer = :array.set(buffer.head, {sequence, packet_state}, buffer.buffer)
      {:ok, %{buffer |
        buffer: new_buffer,
        head: rem(buffer.head + 1, buffer.size),
        count: buffer.count + 1
      }}
    end
  end

  def get_by_sequence(buffer, sequence) do
    Enum.find_value(0..(buffer.size - 1), fn i ->
      case :array.get(i, buffer.buffer) do
        {^sequence, packet_state} -> packet_state
        _ -> nil
      end
    end)
  end

  def update_by_sequence(buffer, sequence, update_fn) do
    new_array = Enum.reduce(0..(buffer.size - 1), buffer.buffer, fn i, acc ->
      case :array.get(i, acc) do
        {^sequence, packet_state} ->
          :array.set(i, {sequence, update_fn.(packet_state)}, acc)
        _ ->
          acc
      end
    end)
    %{buffer | buffer: new_array}
  end

  def mark_acked(buffer, sequence) do
    # First mark the packet as acked
    new_buffer_array = Enum.reduce(0..(buffer.size - 1), buffer.buffer, fn i, acc ->
      case :array.get(i, acc) do
        {^sequence, packet_state} ->
          :array.set(i, {sequence, %{packet_state | acked: true}}, acc)
        _ ->
          acc
      end
    end)

    # Now advance tail past any consecutive acked packets from the tail position
    {final_buffer, new_tail, new_count} = advance_tail(new_buffer_array, buffer.tail, buffer.count, buffer.size)

    %{buffer | buffer: final_buffer, tail: new_tail, count: new_count}
  end

  defp advance_tail(buffer, tail, count, size) when count > 0 do
    case :array.get(tail, buffer) do
      {_seq, %{acked: true}} ->
        # Clear this slot and advance
        new_buffer = :array.set(tail, nil, buffer)
        new_tail = rem(tail + 1, size)
        advance_tail(new_buffer, new_tail, count - 1, size)
      _ ->
        # Either nil or unacked packet, stop here
        {buffer, tail, count}
    end
  end

  defp advance_tail(buffer, tail, count, _size), do: {buffer, tail, count}

  def get_unacked_sequences(buffer) do
    Enum.reduce(0..(buffer.size - 1), [], fn i, acc ->
      case :array.get(i, buffer.buffer) do
        {seq, %{acked: false}} -> [seq | acc]
        _ -> acc
      end
    end) |> Enum.reverse()
  end

  def get_all_packets(buffer) do
    Enum.reduce(0..(buffer.size - 1), [], fn i, acc ->
      case :array.get(i, buffer.buffer) do
        {seq, packet_state} -> [{seq, packet_state} | acc]
        nil -> acc
        _ -> acc
      end
    end) |> Enum.reverse()
  end

  def is_full?(buffer), do: buffer.count >= buffer.size

  def count(buffer), do: buffer.count
end