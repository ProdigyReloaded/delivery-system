# test/prodigy/server/protocol/tcs/transmit_buffer_test.exs
defmodule Prodigy.Server.Protocol.Tcs.TransmitBuffer.Test do
  use ExUnit.Case, async: true

  alias Prodigy.Server.Protocol.Tcs.TransmitBuffer
  alias Prodigy.Server.Protocol.Tcs.TransmitBuffer.PacketState

  describe "new/1" do
    test "creates buffer with default size" do
      buffer = TransmitBuffer.new()
      assert buffer.size == 8
      assert buffer.head == 0
      assert buffer.tail == 0
      assert buffer.count == 0
    end

    test "creates buffer with custom size" do
      buffer = TransmitBuffer.new(16)
      assert buffer.size == 16
    end
  end

  describe "add/3" do
    test "adds packet to empty buffer" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{
        acked: false,
        packet: "test_packet",
        sent_time: DateTime.utc_now()
      }

      assert {:ok, new_buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      assert new_buffer.count == 1
      assert new_buffer.head == 1
    end

    test "adds multiple packets" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{acked: false}

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 2, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 3, packet_state)

      assert buffer.count == 3
      assert buffer.head == 3
    end

    test "returns error when buffer is full" do
      buffer = TransmitBuffer.new(2)
      packet_state = %PacketState{acked: false}

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 2, packet_state)

      assert {:error, :buffer_full} = TransmitBuffer.add(buffer, 3, packet_state)
    end

    test "handles wrap-around correctly" do
      buffer = TransmitBuffer.new(3)
      packet_state = %PacketState{acked: false}

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 2, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 3, packet_state)

      # Mark first packet as acked and remove it
      buffer = TransmitBuffer.mark_acked(buffer, 1)
      assert buffer.count == 2

      # Now we should be able to add another
      {:ok, buffer} = TransmitBuffer.add(buffer, 4, packet_state)
      assert buffer.count == 3
      assert buffer.head == 1  # Wrapped around
    end
  end

  describe "get_by_sequence/2" do
    test "finds packet by sequence number" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{
        acked: false,
        packet: "test_packet_42"
      }

      {:ok, buffer} = TransmitBuffer.add(buffer, 42, packet_state)

      found = TransmitBuffer.get_by_sequence(buffer, 42)
      assert found.packet == "test_packet_42"
    end

    test "returns nil for non-existent sequence" do
      buffer = TransmitBuffer.new(4)
      assert TransmitBuffer.get_by_sequence(buffer, 99) == nil
    end
  end

  describe "mark_acked/2" do
    test "marks packet as acked" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{acked: false}

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      buffer = TransmitBuffer.mark_acked(buffer, 1)

      found = TransmitBuffer.get_by_sequence(buffer, 1)
      assert found == nil  # Should be removed after acking
      assert buffer.count == 0
    end

    test "advances tail past consecutive acked packets" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{acked: false}

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 2, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 3, packet_state)

      # Mark first two as acked
      buffer = TransmitBuffer.mark_acked(buffer, 1)
      buffer = TransmitBuffer.mark_acked(buffer, 2)

      assert buffer.count == 1
      assert buffer.tail == 2
    end

    test "doesn't advance tail past unacked packet" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{acked: false}

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 2, packet_state)
      {:ok, buffer} = TransmitBuffer.add(buffer, 3, packet_state)

      # Mark middle packet as acked (out of order)
      buffer = TransmitBuffer.mark_acked(buffer, 2)

      # Tail shouldn't advance because packet 1 is still unacked
      assert buffer.count == 3
      assert buffer.tail == 0

      # Now ack the first packet
      buffer = TransmitBuffer.mark_acked(buffer, 1)

      # Now tail should advance past both 1 and 2
      assert buffer.count == 1
      assert buffer.tail == 2
    end
  end

  describe "update_by_sequence/3" do
    test "updates packet state" do
      buffer = TransmitBuffer.new(4)
      packet_state = %PacketState{
        acked: false,
        wack_count: 1
      }

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, packet_state)

      buffer = TransmitBuffer.update_by_sequence(buffer, 1, fn ps ->
        %{ps | wack_count: ps.wack_count + 1}
      end)

      found = TransmitBuffer.get_by_sequence(buffer, 1)
      assert found.wack_count == 2
    end
  end

  describe "get_unacked_sequences/1" do
    test "returns list of unacked sequences" do
      buffer = TransmitBuffer.new(4)

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, %PacketState{acked: false})
      {:ok, buffer} = TransmitBuffer.add(buffer, 2, %PacketState{acked: false})
      {:ok, buffer} = TransmitBuffer.add(buffer, 3, %PacketState{acked: true})

      unacked = TransmitBuffer.get_unacked_sequences(buffer)
      assert unacked == [1, 2]
    end
  end

  describe "is_full?/1" do
    test "returns true when buffer is full" do
      buffer = TransmitBuffer.new(2)

      refute TransmitBuffer.is_full?(buffer)

      {:ok, buffer} = TransmitBuffer.add(buffer, 1, %PacketState{})
      refute TransmitBuffer.is_full?(buffer)

      {:ok, buffer} = TransmitBuffer.add(buffer, 2, %PacketState{})
      assert TransmitBuffer.is_full?(buffer)
    end
  end
end