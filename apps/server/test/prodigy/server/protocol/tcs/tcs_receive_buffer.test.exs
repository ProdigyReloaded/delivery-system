# test/prodigy/server/protocol/tcs/receive_buffer_test.exs
defmodule Prodigy.Server.Protocol.Tcs.ReceiveBuffer.Test do
  use ExUnit.Case, async: true

  alias Prodigy.Server.Protocol.Tcs.ReceiveBuffer
  alias Prodigy.Server.Protocol.Tcs.Packet
  alias Prodigy.Server.Protocol.Tcs.Packet.Type

  describe "new/2" do
    test "creates buffer with default values" do
      buffer = ReceiveBuffer.new()
      assert buffer.size == 2
      assert buffer.base_seq == 0
      assert buffer.next_expected == 0
      assert buffer.wrap_point == 256
    end

    test "creates buffer with custom size and start sequence" do
      buffer = ReceiveBuffer.new(4, 100)
      assert buffer.size == 4
      assert buffer.base_seq == 100
      assert buffer.next_expected == 100
    end
  end

  describe "add_packet/2" do
    test "adds packet within window" do
      buffer = ReceiveBuffer.new(4, 10)
      packet = %Packet{seq: 11, type: Type.UD1ACK, payload: "test"}

      assert {:ok, new_buffer} = ReceiveBuffer.add_packet(buffer, packet)
      assert :array.get(1, new_buffer.buffer) == packet
    end

    test "rejects packet outside window" do
      buffer = ReceiveBuffer.new(4, 10)
      packet = %Packet{seq: 20, type: Type.UD1ACK, payload: "test"}

      assert {:error, :outside_window, 10} = ReceiveBuffer.add_packet(buffer, packet)
    end

    test "handles wrap-around correctly" do
      buffer = ReceiveBuffer.new(4, 254)

      # These should all be in window: 254, 255, 0, 1
      packet254 = %Packet{seq: 254, type: Type.UD1ACK, payload: "254"}
      packet255 = %Packet{seq: 255, type: Type.UD1ACK, payload: "255"}
      packet0 = %Packet{seq: 0, type: Type.UD1ACK, payload: "0"}
      packet1 = %Packet{seq: 1, type: Type.UD1ACK, payload: "1"}

      assert {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet254)
      assert {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet255)
      assert {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet0)
      assert {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)

      # This should be outside window
      packet2 = %Packet{seq: 2, type: Type.UD1ACK, payload: "2"}
      assert {:error, :outside_window, 254} = ReceiveBuffer.add_packet(buffer, packet2)
    end
  end

  describe "in_window?/2" do
    test "correctly identifies sequences in window" do
      buffer = ReceiveBuffer.new(4, 10)

      assert ReceiveBuffer.in_window?(buffer, 10)
      assert ReceiveBuffer.in_window?(buffer, 11)
      assert ReceiveBuffer.in_window?(buffer, 12)
      assert ReceiveBuffer.in_window?(buffer, 13)

      refute ReceiveBuffer.in_window?(buffer, 14)
      refute ReceiveBuffer.in_window?(buffer, 9)
    end

    test "handles wrap-around window correctly" do
      buffer = ReceiveBuffer.new(4, 254)

      assert ReceiveBuffer.in_window?(buffer, 254)
      assert ReceiveBuffer.in_window?(buffer, 255)
      assert ReceiveBuffer.in_window?(buffer, 0)
      assert ReceiveBuffer.in_window?(buffer, 1)

      refute ReceiveBuffer.in_window?(buffer, 2)
      refute ReceiveBuffer.in_window?(buffer, 253)
    end
  end

  describe "get_missing_sequences/1" do
    test "returns empty list when no packets received" do
      buffer = ReceiveBuffer.new(4, 10)
      assert ReceiveBuffer.get_missing_sequences(buffer) == []
    end

    test "returns empty list when all sequential packets received" do
      buffer = ReceiveBuffer.new(4, 10)

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet2 = %Packet{seq: 11, type: Type.UD1ACK, payload: "2"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet2)

      assert ReceiveBuffer.get_missing_sequences(buffer) == []
    end

    test "identifies missing sequences with gaps" do
      buffer = ReceiveBuffer.new(4, 10)

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet3 = %Packet{seq: 12, type: Type.UD1ACK, payload: "3"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet3)

      assert ReceiveBuffer.get_missing_sequences(buffer) == [11]
    end

    test "identifies multiple missing sequences" do
      buffer = ReceiveBuffer.new(6, 10)

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet4 = %Packet{seq: 13, type: Type.UD1ACK, payload: "4"}
      packet6 = %Packet{seq: 15, type: Type.UD1ACK, payload: "6"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet4)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet6)

      assert ReceiveBuffer.get_missing_sequences(buffer) == [11, 12, 14]
    end
  end

  describe "take_sequential_packets/1" do
    test "returns empty list when no packets at head" do
      buffer = ReceiveBuffer.new(4, 10)

      # Add packet not at head
      packet = %Packet{seq: 11, type: Type.UD1ACK, payload: "test"}
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet)

      {packets, _new_buffer} = ReceiveBuffer.take_sequential_packets(buffer)
      assert packets == []
    end

    test "takes sequential packets and advances window" do
      buffer = ReceiveBuffer.new(4, 10)

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet2 = %Packet{seq: 11, type: Type.UD1ACK, payload: "2"}
      packet3 = %Packet{seq: 12, type: Type.UD1ACK, payload: "3"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet2)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet3)

      {packets, new_buffer} = ReceiveBuffer.take_sequential_packets(buffer)

      assert length(packets) == 3
      assert Enum.map(packets, & &1.payload) == ["1", "2", "3"]
      assert new_buffer.base_seq == 13
      assert new_buffer.next_expected == 13
    end

    test "stops at first gap" do
      buffer = ReceiveBuffer.new(4, 10)

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet3 = %Packet{seq: 12, type: Type.UD1ACK, payload: "3"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet3)

      {packets, new_buffer} = ReceiveBuffer.take_sequential_packets(buffer)

      assert length(packets) == 1
      assert hd(packets).payload == "1"
      assert new_buffer.base_seq == 11

      # Packet 3 should still be in buffer at position 1
      assert :array.get(1, new_buffer.buffer) != :pending
    end
  end

  describe "reset/2" do
    test "clears buffer and resets to new base sequence" do
      buffer = ReceiveBuffer.new(4, 10)

      packet = %Packet{seq: 11, type: Type.UD1ACK, payload: "test"}
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet)

      new_buffer = ReceiveBuffer.reset(buffer, 20)

      assert new_buffer.base_seq == 20
      assert new_buffer.next_expected == 20
      assert :array.get(0, new_buffer.buffer) == :pending
      assert :array.get(1, new_buffer.buffer) == :pending
    end
  end

  describe "count_ready_packets/1" do
    test "counts consecutive packets from head" do
      buffer = ReceiveBuffer.new(4, 10)

      assert ReceiveBuffer.count_ready_packets(buffer) == 0

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet2 = %Packet{seq: 11, type: Type.UD1ACK, payload: "2"}
      packet4 = %Packet{seq: 13, type: Type.UD1ACK, payload: "4"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      assert ReceiveBuffer.count_ready_packets(buffer) == 1

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet2)
      assert ReceiveBuffer.count_ready_packets(buffer) == 2

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet4)
      assert ReceiveBuffer.count_ready_packets(buffer) == 2  # Stops at gap
    end
  end

  describe "status/1" do
    test "provides complete buffer status" do
      buffer = ReceiveBuffer.new(4, 10)

      packet1 = %Packet{seq: 10, type: Type.UD1ACK, payload: "1"}
      packet3 = %Packet{seq: 12, type: Type.UD1ACK, payload: "3"}

      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet1)
      {:ok, buffer} = ReceiveBuffer.add_packet(buffer, packet3)

      status = ReceiveBuffer.status(buffer)

      assert status.base_seq == 10
      assert status.next_expected == 10
      assert status.window == [
               {10, :received},
               {11, :pending},
               {12, :received},
               {13, :pending}
             ]
      assert status.missing == [11]
    end
  end
end