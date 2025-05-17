# Copyright 2025, Ralph Richard Cook
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

defmodule Prodigy.Server.Protocol.Tcs.Window.Test do
  use ExUnit.Case
  alias Prodigy.Server.Protocol.Tcs.Window
  alias Prodigy.Server.Protocol.Tcs.Packet

  describe "window tests" do
    test "init creates window with correct sequence numbers" do
      window = Window.init(254, 4)
      assert window.sequences == [254, 255, 0, 1]
      assert map_size(window.packet_map) == 4
      assert window.window_start == 254
      assert window.window_size == 4
    end

    test "first_sequence and last_sequence work correctly" do
      window = Window.init(254, 4)
      assert Window.first_sequence(window) == 254
      assert Window.last_sequence(window) == 1
    end

    test "add_packet handles sequence within window" do
      window = Window.init(1, 4)
      packet = %Packet{seq: 2, type: Type.UD1ACK, payload: <<"baz">>}
      {:ok, updated_window} = Window.add_packet(window, 2, packet)
      assert updated_window.packet_map[2] == packet
    end

    test "add_packet rejects sequence outside window" do
      window = Window.init(1, 4)
      packet = %Packet{seq: 8, type: Type.UD1ACK, payload: <<"baz">>}
      assert {:error, :outside_window, 1} = Window.add_packet(window, 8, packet)
    end

    test "check_packets detects out of sequence packets" do
      window = Window.init(1, 4)
      packet = %Packet{seq: 3, type: Type.UD1ACK, payload: <<"baz">>}
      {:ok, window} = Window.add_packet(window, 3, packet)
      missing = Window.check_packets(window)
      assert length(missing) == 2
      assert Enum.map(missing, fn {seq, _} -> seq end) == [1, 2]
    end

    test "tcs_packets_used counts received packets" do
      window = Window.init(1, 4)
      assert Window.tcs_packets_used(window) == 0

      {:ok, window} =
        Window.add_packet(window, 1, %Packet{seq: 1, type: Type.UD1ACK, payload: <<"baz">>})

      {:ok, window} =
        Window.add_packet(window, 2, %Packet{seq: 2, type: Type.UD1ACK, payload: <<"baz">>})

      assert Window.tcs_packets_used(window) == 2
    end
  end
end
