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

defmodule Prodigy.Server.Protocol.Tcs.Packet do
  @moduledoc false
  alias __MODULE__
  use EnumType
  import Bitwise

  @enforce_keys [:seq, :type, :payload]
  defstruct [:seq, :type, :payload]
  @type t :: %Packet{seq: integer(), type: Type, payload: binary()}

  defenum Type do
    # Data, User data 1st blk: no ack
    value(UD1NAK, 0)
    # Data, User data 1st blk: ack
    value(UD1ACK, 1)
    # Protocol, ack packet
    value(ACKPKT, 2)
    # Protocol, Nack CRC error
    value(NAKCCE, 3)
    # Protocol, Nack no CRC error
    value(NAKNCC, 4)
    # Protocol, retransmit starting at packet
    value(RXMITP, 5)
    # Protocol, waiting acknowledgement
    value(WACKPK, 6)
    # Protocol, Transmission aborted
    value(TXABOD, 7)
    # Data, User data not 1st blk: no ack
    value(UD2NAK, 8)
    # Data, User data not 1st blk: ack
    value(UD2ACK, 9)
  end

  @spec encode(Packet.t()) :: <<_::16, _::_*8>>
  def encode(%Packet{} = packet) do
    count = byte_size(packet.payload) - 1
    data = <<count, ~~~count &&& 255, packet.seq, packet.type.value, packet.payload::binary>>
    crc = CRC.calculate(:binary.bin_to_list(data), :x_25)
    <<0x02>> <> data <> <<crc::16-little>>
  end

  @spec ackpkt(integer) :: <<_::16, _::_*8>>
  def ackpkt(seq) do
    encode(%Packet{seq: 0, type: Type.ACKPKT, payload: <<seq>>})
  end

  @spec nakcce(integer) :: <<_::16, _::_*8>>
  def nakcce(seq) do
    encode(%Packet{seq: 0, type: Type.NAKCCE, payload: <<seq>>})
  end

  @spec nakncc(integer) :: <<_::16, _::_*8>>
  def nakncc(seq) do
    encode(%Packet{seq: 0, type: Type.NAKNCC, payload: <<seq>>})
  end

  @spec rxmitp(integer) :: <<_::16, _::_*8>>
  def rxmitp(seq) do
    encode(%Packet{seq: 0, type: Type.RXMITP, payload: <<seq>>})
  end

  @spec wackpk(integer) :: <<_::16, _::_*8>>
  def wackpk(seq) do
    encode(%Packet{seq: 0, type: Type.WACKPK, payload: <<seq>>})
  end

  @spec txabod(integer) :: <<_::16, _::_*8>>
  def txabod(seq) do
    encode(%Packet{seq: 0, type: Type.TXABOD, payload: <<seq>>})
  end

  @spec decode(nonempty_binary) ::
          {:ok, Packet.t(), binary} | {:error, :crc, integer, binary} | {:fragment, binary}
  def decode(<<0x02, count, complement, rest::binary>>)
      when (~~~count &&& 255) != complement do
    decode(<<count, complement, rest::binary>>)
  end

  def decode(<<0x02, count, complement, seq, type, rest::binary>>)
      when type > 9 do
    decode(<<count, complement, seq, type, rest::binary>>)
  end

  def decode(
        <<0x02, count, complement, seq, type, first, rest::binary-size(count),
          expected_crc::16-little, excess::binary>>
      ) do
    case [count, complement, seq, type, first, rest] |> CRC.calculate(:x_25) do
      ^expected_crc ->
        {:ok, %Packet{seq: seq, type: Type.from(type), payload: <<first, rest::binary>>}, excess}

      _ ->
        {:error, :crc, seq, excess}
    end
  end

  def decode(<<0x02, rest::binary>>) do
    {:fragment, <<0x02>> <> rest}
  end

  def decode(<<_first, rest::binary>>) do
    decode(<<rest::binary>>)
  end

  def decode(<<>>) do
    {:fragment, <<>>}
  end
end
