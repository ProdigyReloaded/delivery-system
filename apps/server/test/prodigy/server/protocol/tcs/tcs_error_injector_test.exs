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

defmodule Prodigy.Server.Protocol.Tcs.ErrorInjectionTest do
  use ExUnit.Case
  import WaitFor

  alias Prodigy.Server.Protocol.Tcs.Transmitter
  alias Prodigy.Server.Protocol.Tcs.ErrorInjector
  alias Prodigy.Server.Protocol.Tcs.Packet

  test "bit errors cause CRC failures and retransmission" do
    {:ok, socket} = TestTransport.start_link({})

    # Start transmitter with error injection
    {:ok, pid} = Transmitter.start_link(%{
      transport: TestTransport,
      socket: socket,
      from: self(),
      error_injection: ErrorInjector.init(
        enabled: true,
        error_rate: 1.0,  # Always inject errors
        error_types: [:bit_flip],
        target: :send
      )
    })

    packet = Packet.encode(%Packet{seq: 1, type: Packet.Type.UD1ACK, payload: "test"})
    Transmitter.transmit_packet(pid, packet, 1)

    # Wait for corrupted packet to be sent
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)

    corrupted = TestTransport.take(socket)

    # Verify the packet was corrupted
    refute corrupted == packet

    # Simulate receiving NAKCCE
    Transmitter.send_code(pid, :nakcce, 1)

    # Should resend the original (uncorrupted) packet
    :ok = wait_for(fn -> TestTransport.count(socket) > 0 end, 500)

    resent = TestTransport.take(socket)
    assert resent == packet  # Should be the original, not corrupted
  end
end