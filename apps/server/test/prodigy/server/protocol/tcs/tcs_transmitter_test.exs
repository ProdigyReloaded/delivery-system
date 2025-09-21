# test/prodigy/server/protocol/tcs/transmitter_test.exs
defmodule Prodigy.Server.Protocol.Tcs.Transmitter.Test do
  use ExUnit.Case, async: true
  require Logger
  import WaitFor

  alias Prodigy.Server.Protocol.Tcs.Transmitter
  alias Prodigy.Server.Protocol.Tcs.Packet

  setup do
    {:ok, socket} = TestTransport.start_link({})

    {:ok, pid} = Transmitter.start_link(%{
      transport: TestTransport,
      socket: socket,
      from: self()
    })

    {:ok, transmitter: pid, socket: socket}
  end

  test "queues and sends packets", %{transmitter: pid, socket: socket} do
    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Wait for packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)

    sent_data = TestTransport.take(socket)
    assert sent_data == packet
  end

  test "handles ackpkt", %{transmitter: pid, socket: socket} do
    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Wait for packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    TestTransport.take(socket) # Clear the sent packet

    # Send ACK
    Transmitter.send_code(pid, :ackpkt, 1)

    # Give it time to process
    :timer.sleep(100)

    # Try to trigger sending more packets - acked packet should be removed
    packet2 = Packet.encode(%Packet{seq: 2, type: Packet.Type.UD1ACK, payload: "test2"})
    Transmitter.transmit_packet(pid, packet2, 2)

    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    assert TestTransport.count(socket) == 1 # Only the new packet
  end

  test "handles nakcce and resends packet", %{transmitter: pid, socket: socket} do
    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Wait for packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    sent1 = TestTransport.take(socket)
    assert sent1 == packet

    # Send NAKCCE
    Transmitter.send_code(pid, :nakcce, 1)

    # Wait for retransmission
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    sent2 = TestTransport.take(socket)
    assert sent2 == packet # Same packet retransmitted
  end

  test "handles nakncc and resends packet", %{transmitter: pid, socket: socket} do
    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Wait for packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    sent1 = TestTransport.take(socket)
    assert sent1 == packet

    # Send NAKNCC
    Transmitter.send_code(pid, :nakncc, 1)

    # Wait for retransmission
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    sent2 = TestTransport.take(socket)
    assert sent2 == packet
  end

  test "doesn't resend on nakncc if nakcce already received", %{transmitter: pid, socket: socket} do
    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Wait for packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    TestTransport.take(socket) # Original send

    # Send NAKCCE first
    Transmitter.send_code(pid, :nakcce, 1)
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    TestTransport.take(socket) # Retransmission from NAKCCE

    # Now send NAKNCC - should not retransmit
    Transmitter.send_code(pid, :nakncc, 1)
    :timer.sleep(200)
    assert TestTransport.count(socket) == 0
  end

  test "handles rxmitp and resends all unacked packets", %{transmitter: pid, socket: socket} do
    packet1 = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test1"})
    packet2 = Packet.encode(%Packet{seq: 2, type: Packet.Type.UD1ACK, payload: "test2"})
    packet3 = Packet.encode(%Packet{seq: 3, type: Packet.Type.UD1ACK, payload: "test3"})

    Transmitter.transmit_packet(pid, packet1, 1)
    Transmitter.transmit_packet(pid, packet2, 2)
    Transmitter.transmit_packet(pid, packet3, 3)

    # Wait for all packets to be sent initially
    :ok = wait_for(fn -> TestTransport.count(socket) >= 3 end, 1000)

    # Clear the initial sends
    TestTransport.take(socket)
    TestTransport.take(socket)
    TestTransport.take(socket)

    # ACK the middle packet
    Transmitter.send_code(pid, :ackpkt, 2)
    :timer.sleep(100)

    # Send RXMITP
    Transmitter.send_code(pid, :rxmitp, 1)

    # Should resend packets 1 and 3 (unacked ones)
    :ok = wait_for(fn -> TestTransport.count(socket) >= 2 end, 500)

    resent1 = TestTransport.take(socket)
    resent2 = TestTransport.take(socket)

    # Packets 1 and 3 should be resent
    assert resent1 == packet1 || resent1 == packet3
    assert resent2 == packet1 || resent2 == packet3
    assert resent1 != resent2
  end

  test "respects buffer size limit", %{transmitter: pid, socket: socket} do
    # Send 8 packets (buffer size)
    for i <- 1..8 do
      packet = Packet.encode(%Packet{seq: i, type: Packet.Type.UD1ACK, payload: "test#{i}"})
      Transmitter.transmit_packet(pid, packet, i)
    end

    # Wait for them to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) == 8 end, 2000)

    # Clear sent packets
    for _ <- 1..8, do: TestTransport.take(socket)

    # Try to send a 9th packet
    packet9 = Packet.encode(%Packet{seq: 9, type: Packet.Type.UD1ACK, payload: "test9"})
    Transmitter.transmit_packet(pid, packet9, 9)

    # It should be queued but not sent
    :timer.sleep(500)
    assert TestTransport.count(socket) == 0

    # ACK the first packet
    Transmitter.send_code(pid, :ackpkt, 1)

    # Now packet 9 should be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)

    sent = TestTransport.take(socket)
    assert sent == packet9
  end

  test "sends wackpk after timeout", %{socket: socket} do
    {:ok, pid} = Transmitter.start_link(%{
      transport: TestTransport,
      socket: socket,
      from: self(),
      wack_interval: 0,  # Always expired
      run_interval: 60_000  # Won't fire
    })

    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Give the GenServer time to process the cast message
    :timer.sleep(10)

    # Manually trigger first run_checks to send the packet
    send(pid, :run_checks)

    # Wait for initial packet send
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    sent_packet = TestTransport.take(socket)
    assert sent_packet == packet

    # Now trigger again to check for WACK
    send(pid, :run_checks)

    # WACK should be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)

    wack_data = TestTransport.take(socket)
    {:ok, wack_packet, _} = Packet.decode(wack_data)
    assert wack_packet.type == Packet.Type.WACKPK
    assert wack_packet.payload == <<1>>
  end

  @tag :focus
  test "sends wp_limit_exceeded after too many wacks", %{socket: socket} do
    {:ok, pid} = Transmitter.start_link(%{
      transport: TestTransport,
      socket: socket,
      from: self(),
      wack_interval: 0,     # Always expired
      run_interval: 60_000  # Won't auto-fire during test
    })

    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Give the GenServer time to process the cast message
    :timer.sleep(10)

    # First run_checks to actually send the packet from queue to socket
    send(pid, :run_checks)

    # Wait for initial packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)
    TestTransport.take(socket) # Clear the initial packet

    # Trigger 3 WACKs (wack_count goes from 1 to 2, 2 to 3, 3 to 4)
    for i <- 1..3 do
      send(pid, :run_checks)

      # Wait for WACK to be sent
      :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)

      wack_data = TestTransport.take(socket)
      {:ok, wack_packet, _} = Packet.decode(wack_data)
      assert wack_packet.type == Packet.Type.WACKPK, "Expected WACK ##{i}"
      assert wack_packet.payload == <<1>>
    end

    # Now trigger one more check - this should hit the threshold
    send(pid, :run_checks)

    # Should receive the limit exceeded message (no 4th WACK is sent)
    assert_receive {:wp_limit_exceeded, ^socket}, 500

    # Verify no WACK was sent this time
    assert TestTransport.count(socket) == 0
  end
end