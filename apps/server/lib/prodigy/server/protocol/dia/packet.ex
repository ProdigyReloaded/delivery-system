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

defmodule Prodigy.Server.Protocol.Dia.Packet do
  @moduledoc """
  DIA Protocol packet decoding functions
  """
  require Logger
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm4, Fm64, Fm9}

  import Prodigy.Server.Util

  # concatenated FM0
  # TODO constrain this dialyzer warning to "overlapping_contract"
  @dialyzer {:nowarn_function, {:decode, 1}}
  @spec decode(binary()) :: {:ok, Fm0.t()} | {:error, atom()}
  def decode(
        <<16, 1::1, 0::7, function, mode::binary-size(1), src::32, logon_seq, message_id,
          dest::32, length::16, payload::binary-size(length)>>
      ) do
    decode(payload, %Fm0{
      concatenated: true,
      function: Fm0.Function.from(function),
      mode: Fm0.Mode.decode(mode),
      src: src,
      logon_seq: logon_seq,
      message_id: message_id,
      dest: dest
    })
  end

  # not concatenated FM0
  @spec decode(binary()) :: {:ok, Fm0.t()}
  def decode(
        <<16, 0::1, 0::7, function, mode::binary-size(1), src::32, logon_seq, message_id,
          dest::32, length::16, payload::binary-size(length)>>
      ) do
    {:ok,
     %Fm0{
       concatenated: false,
       function: Fm0.Function.from(function),
       mode: Fm0.Mode.decode(mode),
       src: src,
       logon_seq: logon_seq,
       message_id: message_id,
       dest: dest,
       payload: payload
     }}
  end

  # fragment
  @spec decode(binary()) :: {:error, atom()}
  def decode(
        <<16, _::1, 0::7, _function, _mode::binary-size(1), _src::32, _logon_seq, _message_id,
          _dest::32, length::16, payload::binary>>
      )
      when byte_size(payload) < length do
    {:fragment, need: length, have: byte_size(payload)}
  end

  @spec decode(binary()) :: {:error, atom()}
  def decode(_) do
    {:error, :no_match}
  end

  # TODO constrain this dialyzer warning to "overlapping_contract"
  @dialyzer {:nowarn_function, {:decode, 2}}
  @spec decode(binary(), Fm0.t()) :: {:ok, Fm0.t()}
  def decode(<<length, 4, user_id::binary-size(7), "0", rest::binary>> = _data, fm0) do
    correlation_id_length = length - 10
    <<correlation_id::binary-size(correlation_id_length), payload::binary>> = rest

    {:ok,
     %Fm0{fm0 | fm4: %Fm4{user_id: user_id, correlation_id: correlation_id}, payload: payload}}
  end

  @spec decode(binary(), Fm0.t()) :: {:ok, Fm0.t()}
  def decode(
        <<6, 0::1, 9::7, function, reason, flags::binary-size(1), length,
          payload::binary-size(length), rest::binary>>,
        fm0
      ) do
    {:ok,
     %Fm0{
       fm0
       | fm9: %Fm9{
           function: Fm9.Function.from(function),
           reason: Fm9.Reason.from(reason),
           flags: Fm9.Flags.decode(flags),
           payload: payload
         },
         payload: rest
     }}
  end

  @spec decode(binary(), Fm0.t()) :: {:ok, Fm0.t()}
  def decode(
        <<6, 0::1, 64::7, status_type, data_mode, length::16, payload::binary-size(length),
          rest::binary>>,
        fm0
      ) do
    {:ok,
     %Fm0{
       fm0
       | fm64: %Fm64{
           status_type: Fm64.StatusType.from(status_type),
           data_mode: Fm64.DataMode.from(data_mode),
           payload: payload
         },
         payload: rest
     }}
  end

  @spec encode(Fm0.t()) :: binary()
  def encode(%Fm0{} = packet) do
    fm4 = encode(packet.fm4)
    fm9 = encode(packet.fm9)
    fm64 = encode(packet.fm64)

    payload = fm4 <> fm9 <> fm64 <> packet.payload

    <<16, bool2int(packet.concatenated)::1, 0::7, packet.function.value,
      Fm0.Mode.encode(packet.mode)::binary, packet.src::32, packet.logon_seq, packet.message_id,
      packet.dest::32, byte_size(payload)::16, payload::binary>>
  end

  @spec encode(Fm4.t()) :: binary()
  def encode(%Fm4{} = packet) do
    length = byte_size(packet.correlation_id) + 10
    <<length, 4, packet.user_id::binary-size(7), 0, packet.correlation_id::binary>>
  end

  @spec encode(Fm9.t()) :: binary()
  def encode(%Fm9{} = packet) do
    <<6, 0::1, 9::7, packet.function.value, packet.reason.value, packet.flags.store_by_key::1,
      packet.flags.retrieve_by_key::1, packet.flags.binary_data::1, packet.flags.ascii_data::1,
      0::4, byte_size(packet.payload), packet.payload::binary>>
  end

  @spec encode(Fm64.t()) :: binary()
  def encode(%Fm64{} = packet) do
    <<6, 0::1, 64::7, packet.status_type.value, packet.data_mode.value,
      byte_size(packet.payload)::16, packet.payload::binary>>
  end

  @spec encode(nil) :: binary()
  def encode(nil) do
    <<>>
  end
end
