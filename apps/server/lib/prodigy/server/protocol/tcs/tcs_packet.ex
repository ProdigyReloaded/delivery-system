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

defmodule Prodigy.Server.Protocol.Tcs.Packet do
  @moduledoc """
  TCS Packet Structure and encoding/decoding functions.

  TCS packet structure is as follows:
  ```
  0      1       2            3          4      5                                  N            N+2
  +------+-------+------------+----------+------+----------------------------------+--------------+
  | STX  | Count | Complement | Sequence | Type |             Payload              |   Checksum   |
  +------+-------+------------+----------+------+----------------------------------+--------------+
  ```

  | Name         |   Size    |   Description                                                                 |
  |--------------|-----------|-------------------------------------------------------------------------------|
  | `STX`        | 1 byte    | A preamble indicating the beginning of a packet; always `ASCII STX (0x02)`    |
  | `Count`      | 1 byte    | The number of bytes in the Payload field less 1                               |
  | `Complement` | 1 byte    | The ones complement of the count                                              |
  | `Sequence`   | 1 byte    | Ordered sequnece of data packets, beginning at `0` and rolling over at `255`  |
  |              |           | Always `0` for protocol packets.                                              |
  | `Type`       | 1 byte    | The type of packet per values in Prodigy.Server.Protocol.Tcs.Packet.Type      |
  | `Payload`    | N bytes   | The payload of the packet:                                                    |
  |              |           |   In the case of Data packet, the content.                                    |
  |              |           |   In the case of a protocol packet, the sequence # of the relevant TCS packet |
  | Checksum     | 2 bytes   | Little endian encoded CRC-16/X.25 checksum of everthing after `STX`           |

  # Theory of Operation

  Upon receiving bytes, Prodigy.Server.Protocol.Tcs will pass the accumulated buffer to one of the `decode()`
  functions within this module.

  The several arities of `decode()` reject invalid packets, recursively attempt to decode a packet, and either return
  a decoded packet to the caller, or an indication that no packet was found and the current buffer.

  This procedure approximates the _hunt header_ state implemented in the original reception system client.
  """
  alias __MODULE__

  require Logger
  use EnumType
  import Bitwise

  defenum Type do
    @moduledoc "An enumeration of the types of TCS protocol packets"
    # Data, User data 1st blk: no ack
    value UD1NAK, 0 do
      @moduledoc false
    end

    #    value(UD1NAK, 0)
    # Data, User data 1st blk: ack
    value UD1ACK, 1 do
      @moduledoc false
    end

    # Protocol, ack packet
    value ACKPKT, 2 do
      @moduledoc false
    end

    # Protocol, Nack CRC error
    value NAKCCE, 3 do
      @moduledoc false
    end

    # Protocol, Nack no CRC error
    value NAKNCC, 4 do
      @moduledoc false
    end

    # Protocol, retransmit starting at packet
    value RXMITP, 5 do
      @moduledoc false
    end

    # Protocol, waiting acknowledgement
    value WACKPK, 6 do
      @moduledoc false
    end

    # Protocol, Transmission aborted
    value TXABOD, 7 do
      @moduledoc false
    end

    # Data, User data not 1st blk: no ack
    value UD2NAK, 8 do
      @moduledoc false
    end

    # Data, User data not 1st blk: ack
    value UD2ACK, 9 do
      @moduledoc false
    end
  end

  @enforce_keys [:seq, :type, :payload]
  defstruct [:seq, :type, :payload]
  @type t :: %Packet{seq: integer(), type: Type.t(), payload: binary()}

  @doc "Encode a given TCS packet structure into a binary representation."
  @spec encode(Packet.t()) :: <<_::16, _::_*8>>
  def encode(%Packet{} = packet) do
    count = byte_size(packet.payload) - 1
    data = <<count, ~~~count &&& 255, packet.seq, packet.type.value(), packet.payload::binary>>
    crc = CRC.calculate(:binary.bin_to_list(data), :x_25)
    <<0x02>> <> data <> <<crc::16-little>>
  end

  @doc "Construct a TCS Acknowledgement Packet"
  @spec ackpkt(integer) :: <<_::16, _::_*8>>
  def ackpkt(seq) do
    Logger.debug("In ackpkt function, seq is #{seq}.")
    encode(%Packet{seq: 0, type: Type.ACKPKT, payload: <<seq>>})
  end

  @doc "Construct a TCS Negative Acknowledgement (CRC Error) Packet"
  @spec nakcce(integer) :: <<_::16, _::_*8>>
  def nakcce(seq) do
    Logger.debug("In nakcce function, seq is #{seq}.")
    encode(%Packet{seq: 0, type: Type.NAKCCE, payload: <<seq>>})
  end

  @doc "Construct a TCS Negative Acknowledgement (Not CRC Error) Packet"
  @spec nakncc(integer) :: <<_::16, _::_*8>>
  def nakncc(seq) do
    Logger.debug("In nakncc function, seq is #{seq}.")
    encode(%Packet{seq: 0, type: Type.NAKNCC, payload: <<seq>>})
  end

  @doc "Construct a TCS Retransmit Packet"
  @spec rxmitp(integer) :: <<_::16, _::_*8>>
  def rxmitp(seq) do
    Logger.debug("In rxmitp function, seq is #{seq}.")
    encode(%Packet{seq: 0, type: Type.RXMITP, payload: <<seq>>})
  end

  @doc "Construct a TCS Waiting for Acknowledgement Packet"
  @spec wackpk(integer) :: <<_::16, _::_*8>>
  def wackpk(seq) do
    Logger.debug("In wackpk function, seq is #{seq}.")
    encode(%Packet{seq: 0, type: Type.WACKPK, payload: <<seq>>})
  end

  @doc "Construct a TCS Transmission Aborted Packet"
  @spec txabod(integer) :: <<_::16, _::_*8>>
  def txabod(seq) do
    Logger.debug("In txabod function, seq is #{seq}.")
    encode(%Packet{seq: 0, type: Type.TXABOD, payload: <<seq>>})
  end

  @doc """
  Attempt to find a valid TCS packet in a given buffer.

  The several arities of the decode() function progressively match and/or validate fields within the TCS
  header, discarding and recursing where possible.

  When more bytes are needed, `{:fragment, buffer}` is returned, where `buffer` is the accumulated bytes not yet
  discarded.

  The last step in determining validity is performing a CRC check.

  On success, `{:ok, %Packet{}, excess}` is returned to the caller, `Packet` is the decoded TCS packet structure and
  `excess` is the remaining bytes after decoding.

  In the case of an invalid CRC, `{:error, :crc, seq, excess}` is returned to the caller, where `seq` is the sequence
  number in the invalid TCS packet and `excess` is the remaining bytes after decoding.  It is up to the caller to
  handle any supervisory tasks, such as sending a `NAKCRC` packet.
  """
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
