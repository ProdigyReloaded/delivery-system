defmodule Prodigy.Server.Protocol.Tcs.Transmitter.Test do
  use ExUnit.Case, async: true
  require Logger
  import Cachex.Spec

  alias Prodigy.Server.Protocol.Tcs.Transmitter
  alias Prodigy.Server.Protocol.Tcs.Packet

  setup do
    Cachex.start_link(:transmit, [
      expiration: expiration(
        # how often cleanup should occur
        interval: :timer.seconds(15),

        # default record expiration
        default: :timer.seconds(60)
      )
    ])

    Logger.debug("Setting up cache for tracking acks")
    Cachex.start_link(:ack_tracker, [
      expiration: expiration(
        # how often cleanup should occur
        interval: :timer.seconds(15),

        # default record expiration
        default: :timer.minutes(2)
      )
    ])

    {:ok, socket} = TestTransport.start_link({})

    {:ok, pid} = Transmitter.start_link(%{
      transport: TestTransport,
      socket: socket,
      from: self()
    })
    {:ok, transmitter: pid}
  end

  test "queues and sends packets", %{transmitter: pid} do
    Transmitter.transmit_packet(pid, "test_packet", 1)
    # assert_receive {:send, "test_packet"}
  end

  test "handles ackpkt", %{transmitter: pid} do
    Transmitter.transmit_packet(pid, "test_packet", 1)
    GenServer.cast(pid, {:ackpkt, 1})
    {:ok, value} = Cachex.get(:transmit, {pid, 1})
    assert value == nil
  end

  test "handles nakcce", %{transmitter: pid} do
    Transmitter.transmit_packet(pid, "test_packet", 1)
    GenServer.cast(pid, {:nakcce, 1})
    # assert_receive {:send, "test_packet"}
  end

  test "handles nakncc", %{transmitter: pid} do
    Transmitter.transmit_packet(pid, "test_packet", 1)
    GenServer.cast(pid, {:nakncc, 1})
    # assert_receive {:send, "test_packet"}
  end

  test "sends wackpk after interval", %{transmitter: pid} do
    Transmitter.transmit_packet(pid, "test_packet", 1)
    :timer.sleep(11_000) # Wait longer than @wack_interval
    # assert_receive {:send, _wackpk}
  end
end
