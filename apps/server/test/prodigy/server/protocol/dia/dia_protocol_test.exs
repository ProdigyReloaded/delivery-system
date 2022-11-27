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

defmodule Prodigy.Server.Protocol.Dia.Test do
  @moduledoc false
  use ExUnit.Case, async: true
  import WaitFor

  alias Prodigy.Server.Protocol.Dia, as: DiaProtocol
  alias Prodigy.Server.Protocol.Dia.Options
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Protocol.Tcs.Packet, as: TcsPacket

  defmodule TestRouter do
    use GenServer

    def handle_packet(pid, %Fm0{} = packet), do: GenServer.call(pid, {:packet, packet})
    def take(pid), do: GenServer.call(pid, :take)
    def count(pid), do: GenServer.call(pid, :count)

    def init(_), do: {:ok, []}

    def handle_call({:packet, packet}, _from, queue), do: {:reply, :ok, queue ++ [packet]}
    def handle_call(:take, _from, [head | tail]), do: {:reply, head, tail}
    def handle_call(:count, _from, queue), do: {:reply, length(queue), queue}
  end

  @timeout 1000
  @options %Options{router_module: TestRouter}

  @ud1ack %TcsPacket{
    payload:
      <<16, 0, 0, 0, 0, 0, 0, 0, 0, 11, 0, 0, 210, 0, 1, 247, 1, 1, 2, 0, 1, 80, 72, 73, 76, 57,
        57, 65, 0, 0, 6, 70, 79, 79, 66, 65, 82, 1, 224, 84, 104, 101, 32, 113, 117, 105, 99, 107,
        32, 98, 114, 111, 119, 110, 32, 102, 111, 120, 32, 106, 117, 109, 112, 101, 100, 32, 111,
        118, 101, 114, 32, 116, 104, 101, 32, 108, 97, 122, 121, 100, 111, 103, 39, 115, 32, 98,
        97, 99, 107, 46, 32, 84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114, 111, 119, 110,
        32, 102, 111, 120, 32, 106, 117, 109, 112, 101, 100, 32, 32, 111, 118, 101, 114, 32, 116,
        104, 101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 39, 115, 32, 98, 97, 99, 107, 46, 32,
        84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 32, 32, 32, 32, 98, 114, 111, 119, 110, 32,
        102, 111, 120, 32, 106, 117, 109, 112, 101, 100, 32, 111, 118, 101, 114, 32, 116, 104,
        101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 39, 115, 32, 32, 32, 32, 98, 97, 99, 107,
        46, 32, 84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114, 111, 119, 110, 32, 102,
        111, 120, 32, 106, 117, 109, 112, 101, 100, 32, 111, 118, 101, 114, 32, 32, 32, 116, 104,
        101, 32, 108, 97, 122, 121, 32, 100, 111, 103, 39, 115, 32, 98, 97>>,
    seq: 10,
    type: 1
  }

  @ud2ack1 %TcsPacket{
    payload:
      "ck. The quick brown foxjumped over the lazy dog's back. The    quick brown fox jumped over the lazy    dog's back. The quick brown fox jumped  over the lazy dog's back. The quick     brown fox jumped over the lazy dog's    back. The quick brown fox jumped ",
    seq: 11,
    type: 9
  }

  @ud2ack2 %TcsPacket{
    payload: "over...",
    seq: 12,
    type: 9
  }

  test "DiaProtocol handles packets" do
    {:ok, dia_pid} = GenServer.start_link(DiaProtocol, @options)
    {:ok, router_pid} = DiaProtocol.get_router_pid(dia_pid)

    :ok = DiaProtocol.handle_packet(dia_pid, @ud1ack)
    :ok = DiaProtocol.handle_packet(dia_pid, @ud2ack1)
    :ok = DiaProtocol.handle_packet(dia_pid, @ud2ack2)

    :ok = wait_for(fn -> TestRouter.count(router_pid) >= 1 end, @timeout)
    assert %Fm0{} = TestRouter.take(router_pid)
  end
end
