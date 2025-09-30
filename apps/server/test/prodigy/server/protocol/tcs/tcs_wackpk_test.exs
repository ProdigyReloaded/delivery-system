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

defmodule Prodigy.Server.Protocol.Tcs.WackpkTest do
  use ExUnit.Case
  require Logger

  alias Prodigy.Server.Protocol.Tcs
  alias Prodigy.Server.Protocol.Tcs.Packet
  alias Prodigy.Server.Protocol.Tcs.Packet.Type
  alias Prodigy.Server.Protocol.Tcs.ReceiveBuffer

  # Mock transport module for testing
  defmodule MockTransport do
    import Kernel, except: [send: 2]

    def send(_socket, data) do
      # Send to test process so we can assert on it
      Kernel.send(self(), {:sent, data})
      :ok
    end
  end

  setup do
    # Create a basic state for testing
    rx_buffer = ReceiveBuffer.new(8, 10)  # Window size 8, starting at seq 10

    state = %{
      socket: :mock_socket,
      transport: MockTransport,
      dia_module: nil,
      dia_pid: nil,
      tx_seq: 0,
      rx_seq: 10,
      rx_buffer: rx_buffer,
      buffer: <<>>
    }

    {:ok, %{state: state}}
  end

  describe "WACKPK handling" do
    test "sends ACKPKT when packet was already received", %{state: state} do
      # First, simulate receiving packet seq 12
      packet_12 = %Packet{seq: 12, type: Type.UD1ACK, payload: <<1, 2, 3>>}
      {:ok, rx_buffer_with_12} = ReceiveBuffer.add_packet(state.rx_buffer, packet_12)
      state = %{state | rx_buffer: rx_buffer_with_12}

      # Now receive WACKPK for seq 12
      wackpk = %Packet{seq: 0, type: Type.WACKPK, payload: <<12>>}

      # Call the handler
      {_excess, _tx_seq, _rx_seq, _rx_buffer} =
        Tcs.handle_packet_in({wackpk, <<>>}, Type.WACKPK, state)

      # Verify ACKPKT was sent
      assert_receive {:sent, data}
      {:ok, response, _} = Packet.decode(data)
      assert response.type == Type.ACKPKT
      assert response.payload == <<12>>
    end

    test "sends NAKNCC when packet is in window but not received", %{state: state} do
      # WACKPK for seq 13 which is in window but not received
      wackpk = %Packet{seq: 0, type: Type.WACKPK, payload: <<13>>}

      # Call the handler
      {_excess, _tx_seq, _rx_seq, _rx_buffer} =
        Tcs.handle_packet_in({wackpk, <<>>}, Type.WACKPK, state)

      # Verify NAKNCC was sent
      assert_receive {:sent, data}
      {:ok, response, _} = Packet.decode(data)
      assert response.type == Type.NAKNCC
      assert response.payload == <<13>>
    end

    test "sends RXMITP for sequence outside window (before)", %{state: state} do
      # WACKPK for seq 5, which is before our window (base_seq = 10)
      wackpk = %Packet{seq: 0, type: Type.WACKPK, payload: <<5>>}

      # Call the handler
      {_excess, _tx_seq, _rx_seq, _rx_buffer} =
        Tcs.handle_packet_in({wackpk, <<>>}, Type.WACKPK, state)

      # Should send RXMITP since it's outside window
      assert_receive {:sent, data}
      {:ok, response, _} = Packet.decode(data)
      assert response.type == Type.RXMITP
      assert response.payload == <<10>>  # Should request from next_expected
    end

    test "sends RXMITP for sequence outside window (beyond)", %{state: state} do
      # WACKPK for seq 50, which is way beyond our window (base = 10, size = 8)
      wackpk = %Packet{seq: 0, type: Type.WACKPK, payload: <<50>>}

      # Call the handler
      {_excess, _tx_seq, _rx_seq, _rx_buffer} =
        Tcs.handle_packet_in({wackpk, <<>>}, Type.WACKPK, state)

      # Should send RXMITP to resync
      assert_receive {:sent, data}
      {:ok, response, _} = Packet.decode(data)
      assert response.type == Type.RXMITP
      assert response.payload == <<10>>  # Should request from next_expected
    end

    test "handles sequence wraparound correctly", %{state: state} do
      # Set up window near the wraparound point
      rx_buffer = ReceiveBuffer.new(8, 252)  # Window at seq 252-3 (wraps around)
      state = %{state | rx_buffer: rx_buffer}

      # WACKPK for seq 250, which is outside window (before)
      wackpk = %Packet{seq: 0, type: Type.WACKPK, payload: <<250>>}

      # Call the handler
      {_excess, _tx_seq, _rx_seq, _rx_buffer} =
        Tcs.handle_packet_in({wackpk, <<>>}, Type.WACKPK, state)

      # Should send RXMITP since it's outside window
      assert_receive {:sent, data}
      {:ok, response, _} = Packet.decode(data)
      assert response.type == Type.RXMITP
      assert response.payload == <<252>>  # next_expected
    end

    test "complex scenario with multiple packets", %{state: state} do
      # Set up: received 10, 11, 13, 15 (missing 12, 14)
      rx_buffer = ReceiveBuffer.new(8, 10)

      packets_to_add = [
        %Packet{seq: 10, type: Type.UD1ACK, payload: <<10>>},
        %Packet{seq: 11, type: Type.UD1ACK, payload: <<11>>},
        %Packet{seq: 13, type: Type.UD1ACK, payload: <<13>>},
        %Packet{seq: 15, type: Type.UD1ACK, payload: <<15>>}
      ]

      rx_buffer = Enum.reduce(packets_to_add, rx_buffer, fn packet, buf ->
        {:ok, new_buf} = ReceiveBuffer.add_packet(buf, packet)
        new_buf
      end)

      state = %{state | rx_buffer: rx_buffer}

      # Test WACKPK for received packet (11)
      wackpk_11 = %Packet{seq: 0, type: Type.WACKPK, payload: <<11>>}
      Tcs.handle_packet_in({wackpk_11, <<>>}, Type.WACKPK, state)
      assert_receive {:sent, data}
      {:ok, resp, _} = Packet.decode(data)
      assert resp.type == Type.ACKPKT
      assert resp.payload == <<11>>

      # Test WACKPK for missing packet (12)
      wackpk_12 = %Packet{seq: 0, type: Type.WACKPK, payload: <<12>>}
      Tcs.handle_packet_in({wackpk_12, <<>>}, Type.WACKPK, state)
      assert_receive {:sent, data}
      {:ok, resp, _} = Packet.decode(data)
      assert resp.type == Type.NAKNCC
      assert resp.payload == <<12>>

      # Test WACKPK for missing packet (14)
      wackpk_14 = %Packet{seq: 0, type: Type.WACKPK, payload: <<14>>}
      Tcs.handle_packet_in({wackpk_14, <<>>}, Type.WACKPK, state)
      assert_receive {:sent, data}
      {:ok, resp, _} = Packet.decode(data)
      assert resp.type == Type.NAKNCC
      assert resp.payload == <<14>>
    end
  end
end