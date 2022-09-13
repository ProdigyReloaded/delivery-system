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

defmodule Prodigy.Server.Protocol.Dia.Packet.Fm0 do
  @moduledoc false
  alias __MODULE__

  use EnumType

  import Prodigy.Server.Util
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm4, Fm9, Fm64}

  defenum Function do
    value(APPL_0, 0x00)
    value(APPL_1, 0x01)
    value(APPL_2, 0x02)
    value(APPL_3, 0x03)
    value(APPL_4, 0x04)
    value(APPL_5, 0x05)
    value(APPL_6, 0x06)
    value(APPL_7, 0x07)
    value(APPL_8, 0x08)
    value(APPL_9, 0x09)
    value(APPL_A, 0x0A)
    value(APPL_B, 0x0B)
    value(APPL_C, 0x0C)
    value(APPL_D, 0x0D)
    value(APPL_E, 0x0E)
    value(APPL_F, 0x0F)
    value(STATUS, 0x20)
    value(BEGIN_SESSION, 0x80)
    value(END_SESSION_NORMAL, 0x81)
    value(END_SESSION_ABNORMAL, 0x82)
    value(REQUEST_TERMINATE, 0x83)
    value(SYSTEM_UP, 0xC0)
    value(SYSTEM_DOWN, 0xC1)
    value(ECHO, 0xC2)
    value(SYSTEM_MESSAGE, 0xC3)
    value(PREPARE_FOR_SYSTEM_DOWN, 0xC4)
  end

  defmodule Mode do
    @moduledoc false
    defstruct reserved: false,
              timeout_message_required: false,
              logging_required: false,
              unsolicited_message: false,
              response: false,
              response_expected: false,
              encryption: false,
              compaction: false

    @type t :: %Mode{
            reserved: boolean,
            timeout_message_required: boolean,
            logging_required: boolean,
            unsolicited_message: boolean,
            response: boolean,
            response_expected: boolean,
            encryption: boolean,
            compaction: boolean
          }

    def decode(<<a::1, b::1, c::1, d::1, e::1, f::1, g::1, h::1>>) do
      %Mode{
        reserved: int2bool(h),
        timeout_message_required: int2bool(g),
        logging_required: int2bool(f),
        unsolicited_message: int2bool(e),
        response: int2bool(d),
        response_expected: int2bool(c),
        encryption: int2bool(b),
        compaction: int2bool(a)
      }
    end

    def encode(%Mode{} = mode) do
      <<bool2int(mode.compaction)::1, bool2int(mode.encryption)::1,
        bool2int(mode.response_expected)::1, bool2int(mode.response)::1,
        bool2int(mode.unsolicited_message)::1, bool2int(mode.logging_required)::1,
        bool2int(mode.timeout_message_required)::1, 0::1>>
    end
  end

  #  @spec make_response(%Fm4{} | %Fm9{} | %Fm64{} | binary(), %Fm0{}) :: %Fm0{}
  def make_response(payload, packet, next_header \\ nil) do
    packet =
      case next_header do
        %Fm4{} -> %{packet | concatenated: true, fm4: next_header}
        %Fm9{} -> %{packet | concatenated: true, fm9: next_header}
        %Fm64{} -> %{packet | concatenated: true, fm64: next_header}
        _ -> %{packet | concatenated: false}
      end

    %{
      packet
      | src: packet.dest,
        dest: packet.src,
        mode: %Fm0.Mode{response: true},
        payload: payload
    }
  end

  # if "concat" is true, then there will be another header following this, in payload.
  # src is always 0x0 when coming from the client
  # server application is responsible for swapping dest and src
  # if client expects a response, the mode bitfield will have the enum RESPONSE_EXPECTED set.
  #   Server application should clear this and set RESPONSE
  # if client doesn't expect a response, the mode bitfield will have enum RESPONSE_EXPECTED clear
  #   Server must not send a response packet in this case, as it will cause client error OMCM 10:
  #     "out of sequence message received"

  defstruct concatenated: false,
            function: nil,
            mode: nil,
            src: nil,
            logon_seq: nil,
            message_id: nil,
            dest: nil,
            fm4: nil,
            fm9: nil,
            fm64: nil,
            payload: nil

  @type t :: %Fm0{
          concatenated: boolean,
          function: Function,
          mode: Mode,
          src: integer,
          logon_seq: integer,
          message_id: integer,
          dest: integer,
          fm4: %Fm4{},
          fm9: %Fm9{},
          fm64: %Fm64{},
          payload: binary
        }
end
