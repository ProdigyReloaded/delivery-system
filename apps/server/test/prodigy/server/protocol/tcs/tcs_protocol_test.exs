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

defmodule Prodigy.Server.Protocol.Tcs.Test do
  @moduledoc false
  use ExUnit.Case, async: true
  import WaitFor
  require Logger

  alias Prodigy.Server.Protocol.Tcs, as: TcsProtocol
  alias Prodigy.Server.Protocol.Tcs.Options, as: Options
  alias Prodigy.Server.Protocol.Tcs.Packet, as: Packet
  alias Prodigy.Server.Protocol.Tcs.Packet.Type, as: Type

  defmodule TestRanch do
    def handshake(ref), do: {:ok, ref}
  end

  defmodule TestTransport do
    use Agent

    # socket, for our testing, is the pid of the TestTransport process
    def setopts(_, _), do: :ok
    def start_link(_opts), do: Agent.start_link(fn -> [] end)

    def send(socket, data),
      do: Agent.get_and_update(socket, fn queue -> {queue, queue ++ [data]} end)

    def take(socket), do: Agent.get_and_update(socket, fn [head | tail] -> {head, tail} end)
    def count(socket), do: Agent.get(socket, fn queue -> length(queue) end)
  end

  defmodule TestDiaProtocol do
    require Logger
    use GenServer

    @doc """
    TcsProtocol uses this function to pass a received packet to be processed.
    """
    def handle_packet(pid, %Packet{} = packet), do: GenServer.call(pid, {:packet, packet})

    @doc """
    Get the next packet that was sent by TcsProtocol.
    """
    def take(pid), do: GenServer.call(pid, :take)

    @doc """
    Get the number of packets in the receive queue currently.
    """
    def count(pid), do: GenServer.call(pid, :count)

    @doc """
    Returns whether or not the TestDiaProtocol process is alive.
    """
    def is_alive?(pid), do: Process.alive?(pid) != nil

    ##

    def init(_) do
      {:ok, []}
    end

    def handle_call({:packet, packet}, _from, queue), do: {:reply, :ok, queue ++ [packet]}
    def handle_call(:take, _from, [head | tail]), do: {:reply, head, tail}
    def handle_call(:count, _from, queue), do: {:reply, length(queue), queue}

    def terminate(_reason, _queue) do
      :normal
    end
  end

  @timeout 1000
  @options %Options{dia_module: TestDiaProtocol, ranch_module: TestRanch}

  setup do
    {:ok, socket} = TestTransport.start_link({})
    {:ok, tcsp} = TcsProtocol.start_link(socket, TestTransport, @options)
    :ok = wait_for(fn -> GenServer.call(tcsp, :get_dia_pid) != nil end, @timeout)
    dia_pid = GenServer.call(tcsp, :get_dia_pid)

    on_exit(fn -> Process.exit(tcsp, :shutdown) end)

    [tcsp: tcsp, socket: socket, dia_pid: dia_pid]
  end

  @tcs1 Packet.encode(%Packet{
          seq: 0,
          type: Type.UD1ACK,
          payload: <<
            0x10,
            0x00,
            0x00,
            0x20,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            0x00,
            0x00,
            0x22,
            0x00,
            0x00,
            0x17,
            0x01,
            0x50,
            0x48,
            0x49,
            0x4C,
            0x39,
            0x39,
            0x41,
            0x06,
            0x46,
            0x4F,
            0x4F,
            0x42,
            0x41,
            0x52,
            0x30,
            0x36,
            0x2E,
            0x30,
            0x33,
            0x2E,
            0x31,
            0x30
          >>
        })

  test "TcsProtocol parses a valid TCS type 1 packet with sequence 0", context do
    send(context.tcsp, {:tcp, nil, @tcs1})

    # wait for TcsProtocol to parse the packet and send it to the TestDiaProtocol process
    :ok =
      wait_for(
        fn ->
          TestDiaProtocol.is_alive?(context.dia_pid) and
            TestDiaProtocol.count(context.dia_pid) == 1
        end,
        @timeout
      )

    # check the results
    assert TestDiaProtocol.count(context.dia_pid) == 1
    packet = TestDiaProtocol.take(context.dia_pid)
    assert packet.type == Type.UD1ACK
    assert packet.seq == 0

    :ok = wait_for(fn -> TestTransport.count(context.socket) > 0 end, @timeout)

    assert TestTransport.count(context.socket) == 1
    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.ACKPKT
    assert packet.seq == 0
    assert packet.payload == <<0>>
  end

  test "out of sequence packet causes NAKNCC", context do
    send(
      context.tcsp,
      {:tcp, nil, Packet.encode(%Packet{type: Type.UD1ACK, seq: 9, payload: <<"foo">>})}
    )

    :ok = wait_for(fn -> TestTransport.count(context.socket) > 0 end, @timeout)

    assert TestTransport.count(context.socket) == 1
    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.NAKNCC
    assert packet.seq == 0
    assert packet.payload == <<9>>
  end

  test "two good packets, then one out of sequence", context do
    send(
      context.tcsp,
      {:tcp, nil, Packet.encode(%Packet{type: Type.UD1ACK, seq: 0, payload: <<"foo">>})}
    )

    send(
      context.tcsp,
      {:tcp, nil, Packet.encode(%Packet{type: Type.UD1NAK, seq: 1, payload: <<"bar">>})}
    )

    send(
      context.tcsp,
      {:tcp, nil, Packet.encode(%Packet{type: Type.UD1ACK, seq: 9, payload: <<"baz">>})}
    )

    :ok =
      wait_for(
        fn ->
          TestDiaProtocol.is_alive?(context.dia_pid) and
            TestDiaProtocol.count(context.dia_pid) > 1
        end,
        @timeout
      )

    # check the results
    assert TestDiaProtocol.count(context.dia_pid) == 2
    packet = TestDiaProtocol.take(context.dia_pid)
    assert packet.type == Type.UD1ACK
    assert packet.seq == 0
    assert packet.payload == <<"foo">>

    packet = TestDiaProtocol.take(context.dia_pid)
    assert packet.type == Type.UD1NAK
    assert packet.seq == 1
    assert packet.payload == <<"bar">>

    :ok = wait_for(fn -> TestTransport.count(context.socket) == 2 end, @timeout)

    assert TestTransport.count(context.socket) == 2
    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.ACKPKT
    assert packet.seq == 0
    assert packet.payload == <<0>>

    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.NAKNCC
    assert packet.seq == 0
    assert packet.payload == <<9>>
  end

  test "TCS receive sequence rolls over from 255 to 0", context do
    for i <- 0..514 do
      send(
        context.tcsp,
        {:tcp, nil,
         Packet.encode(%Packet{type: Type.UD1NAK, seq: Integer.mod(i, 256), payload: <<"foo">>})}
      )
    end

    send(
      context.tcsp,
      {:tcp, nil, Packet.encode(%Packet{type: Type.UD1ACK, seq: 515, payload: <<"foo">>})}
    )

    #    :ok = wait_for(fn () -> TestDiaProtocol.is_alive?(context.dia_pid) and TestDiaProtocol.count(context.dia_pid) == 516 end, @timeout)
    case wait_for(
           fn ->
             TestDiaProtocol.is_alive?(context.dia_pid) and
               TestDiaProtocol.count(context.dia_pid) == 516
           end,
           @timeout
         ) do
      :timeout ->
        Logger.debug(
          "alive? #{TestDiaProtocol.is_alive?(context.dia_pid)} count: #{TestDiaProtocol.count(context.dia_pid)}"
        )

      :ok ->
        :ok
    end

    assert TestDiaProtocol.count(context.dia_pid) == 516
    :ok = wait_for(fn -> TestTransport.count(context.socket) == 1 end, @timeout)

    assert TestTransport.count(context.socket) == 1
    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.ACKPKT
    assert packet.seq == 0
    assert packet.payload == <<3>>
  end

  @tcs5 Packet.encode(%Packet{
          seq: 0,
          type: Type.UD1ACK,
          payload: <<
            0x10,
            0x00,
            0x00,
            0x20,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x04,
            0x00,
            0x00,
            0xD2,
            0x00,
            0x00,
            0x01,
            0x02,
            0x7F
          >>
        })

  test "TcsProtocol parses a valid TCS packet sent in chunks", context do
    <<head::binary-size(8), tail::binary>> = @tcs5

    send(context.tcsp, {:tcp, nil, head})
    send(context.tcsp, {:tcp, nil, tail})

    # wait for TcsProtocol to parse the packet and send it to the TestDiaProtocol process
    :ok =
      wait_for(
        fn ->
          TestDiaProtocol.is_alive?(context.dia_pid) and
            TestDiaProtocol.count(context.dia_pid) > 0
        end,
        @timeout
      )

    # check the results
    assert TestDiaProtocol.count(context.dia_pid) == 1
    packet = TestDiaProtocol.take(context.dia_pid)
    assert packet.type == Type.UD1ACK
    assert packet.seq == 0
    assert TestTransport.count(context.socket) == 1

    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.ACKPKT
    assert packet.seq == 0
    assert packet.payload == <<0>>
  end

  @tcs2_with_bad_type <<0x02, 0x00, 0xFF, 0x00, 0x0F, 0x00, 0x15, 0x39>>

  test "TcsProtocol parses a valid TCS packet that follows junk", context do
    <<head::binary-size(8), tail::binary>> = @tcs5

    # chunked with a false header start.
    send(context.tcsp, {:tcp, nil, <<0x03, 0xFF, 0x02>>})
    send(context.tcsp, {:tcp, nil, <<0x42>>})
    send(context.tcsp, {:tcp, nil, @tcs2_with_bad_type <> head})
    send(context.tcsp, {:tcp, nil, tail})

    # wait for TcsProtocol to parse the packet and send it to the TestDiaProtocol process
    :ok =
      wait_for(
        fn ->
          TestDiaProtocol.is_alive?(context.dia_pid) and
            TestDiaProtocol.count(context.dia_pid) > 0
        end,
        @timeout
      )

    # check the results
    assert TestDiaProtocol.count(context.dia_pid) == 1
    packet = TestDiaProtocol.take(context.dia_pid)
    assert packet.type == Type.UD1ACK
    assert packet.seq == 0

    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.ACKPKT
    assert packet.seq == 0
    assert packet.payload == <<0>>
  end

  test "TcsProtocol parses a valid TCS packet that follows junk (junk starts with 0x2)",
       context do
    send(context.tcsp, {:tcp, nil, <<0x02, 0xFF, 0x42>> <> @tcs5})

    # wait for TcsProtocol to parse the packet and send it to the TestDiaProtocol process
    :ok =
      wait_for(
        fn ->
          TestDiaProtocol.is_alive?(context.dia_pid) and
            TestDiaProtocol.count(context.dia_pid) > 0
        end,
        @timeout
      )

    # check the results
    assert TestDiaProtocol.count(context.dia_pid) == 1
    packet = TestDiaProtocol.take(context.dia_pid)
    assert packet.type == Type.UD1ACK
    assert packet.seq == 0

    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.ACKPKT
    assert packet.seq == 0
    assert packet.payload == <<0>>
  end

  @crce <<0x02, 0x26, 0xD9, 0x42, 0x01, 0x10, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x01, 0x00, 0x00, 0x22, 0x00, 0x00, 0x17, 0x01, 0x50, 0x48, 0x49, 0x4C, 0x39, 0x39,
          0x41, 0x06, 0x46, 0x4F, 0x4F, 0x42, 0x41, 0x52, 0x30, 0x36, 0x2E, 0x30, 0x33, 0x2E,
          0x31, 0x30, 0x18, 0xEF>>

  @tag badcrc: true
  test "TcsProtocol sends back a NACKCCE on bad CRC", context do
    send(context.tcsp, {:tcp, nil, @crce})
    :ok = wait_for(fn -> TestTransport.count(context.socket) == 1 end, @timeout)

    {:ok, %Packet{} = packet, _excess} = Packet.decode(TestTransport.take(context.socket))
    assert packet.type == Type.NAKCCE
    assert packet.payload == <<0x42>>
  end
end
