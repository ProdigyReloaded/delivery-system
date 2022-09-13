# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Server.Protocol.Tcs.Packet.Test do
  @moduledoc false
  use ExUnit.Case, async: true
  import Bitwise

  require Logger

  alias Prodigy.Server.Protocol.Tcs.Packet
  alias Prodigy.Server.Protocol.Tcs.Packet.Type

  defp random_payload(max_length) do
    length = Enum.random(1..max_length)
    payload = for _ <- 1..length, into: "", do: <<Enum.random(0..255)>>
    {length, payload}
  end

  test "Data Packet encode/decode" do
    for _i <- 0..99 do
      # create a random payload, data packet type, and sequence number
      {length, payload} = random_payload(500)
      intype = Type.from(Enum.random([0, 1, 8, 9]))
      inseq = Enum.random(0..255)

      # The length may exceed what one packet can bear; determine what this packet will bear and what is excess
      thislen = min(256, length)
      _excesslen = length - thislen
      <<thispayload::binary-size(thislen), thisexcess::binary>> = payload

      # prepare the first and remaining payload bytes (first is not included in "count"; hence the reason the packet
      # may bear 256 total bytes
      <<first, rest::binary>> = thispayload

      # manually calculate the CRC, encode the packet, and ensure the unit under test calculated the same CRC
      crc =
        [thislen - 1, ~~~(thislen - 1) &&& 255, inseq, intype.value, first, rest]
        |> CRC.calculate(:x_25)

      data = Packet.encode(%Packet{seq: inseq, type: intype, payload: thispayload})

      <<0x02, count, complement, outseq, outtype, first, rest::binary-size(count),
        expected_crc::16-little>> = data

      assert crc == expected_crc

      # decode the encoded binary after appending the excess data generated above; ensure the excess is returned as
      # such for subsequent decoding
      assert {:ok, %Packet{} = packet, <<^thisexcess::binary>>} =
               Packet.decode(data <> thisexcess)

      # ensure the type and sequenec did not change
      assert packet.seq == inseq
      assert packet.type == intype

      # change one byte and ensure the CRC is now wrong and the proper atom returned
      new_first = Integer.mod(first + 1, 255)

      baddata =
        <<0x02, count, complement, outseq, outtype, new_first, rest::binary-size(count),
          expected_crc::16-little>>

      assert {:error, :crc, ^inseq, _excess} = Packet.decode(baddata)
    end
  end

  test "ACKPKT encode/decode" do
    {:ok, %Packet{} = packet, <<>>} = Packet.decode(Packet.ackpkt(4))

    assert packet.seq == 0
    assert packet.type == Type.ACKPKT
    assert packet.payload == <<0x4>>
  end

  test "NAKCCE encode/decode" do
    {:ok, %Packet{} = packet, <<>>} = Packet.decode(Packet.nakcce(5))

    assert packet.seq == 0
    assert packet.type == Type.NAKCCE
    assert packet.payload == <<0x5>>
  end

  test "NAKNCC encode/decode" do
    {:ok, %Packet{} = packet, <<>>} = Packet.decode(Packet.nakncc(6))

    assert packet.seq == 0
    assert packet.type == Type.NAKNCC
    assert packet.payload == <<0x6>>
  end

  test "RXMITP encode/decode" do
    {:ok, %Packet{} = packet, <<>>} = Packet.decode(Packet.rxmitp(7))

    assert packet.seq == 0
    assert packet.type == Type.RXMITP
    assert packet.payload == <<0x7>>
  end

  test "WACKPK encode/decode" do
    {:ok, %Packet{} = packet, <<>>} = Packet.decode(Packet.wackpk(8))

    assert packet.seq == 0
    assert packet.type == Type.WACKPK
    assert packet.payload == <<0x8>>
  end

  test "TXABOD encode/decode" do
    {:ok, %Packet{} = packet, <<>>} = Packet.decode(Packet.txabod(9))

    assert packet.seq == 0
    assert packet.type == Type.TXABOD
    assert packet.payload == <<0x9>>
  end

  test "empty buffer" do
    assert {:fragment, <<>>} = Packet.decode(<<>>)
  end

  test "leading noise stripped" do
    assert {:fragment, <<>>} = Packet.decode(<<0x03, 0x04>>)
    assert {:fragment, <<0x2>>} = Packet.decode(<<0x05, 0x06, 0x2>>)
  end

  test "not a packet (wrong complement)" do
    assert {:fragment, <<>>} = Packet.decode(<<0x02, 0x12, 0x34>>)
    assert {:fragment, <<>>} = Packet.decode(<<0x03, 0x04, 0x02, 0x12, 0x34>>)
    assert {:fragment, <<0x2>>} = Packet.decode(<<0x02, 0x12, 0x34, 0x2>>)
    assert {:fragment, <<0x2>>} = Packet.decode(<<0x03, 0x04, 0x02, 0x12, 0x34, 0x2>>)
  end

  test "not a packet (bad type)" do
    assert {:fragment, <<>>} = Packet.decode(<<0x02, 0x00, 0xFF, 0x1, 0xA>>)
    assert {:fragment, <<>>} = Packet.decode(<<0x03, 0x04, 0x02, 0x00, 0xFF, 0x1, 0xA>>)
    assert {:fragment, <<0x2>>} = Packet.decode(<<0x02, 0x00, 0xFF, 0x1, 0xA, 0x2>>)
    assert {:fragment, <<0x2>>} = Packet.decode(<<0x3, 0x4, 0x02, 0x00, 0xFF, 0x1, 0xA, 0x2>>)
  end
end
