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

defmodule Prodigy.Server.Protocol.Dia.Packet.Fm9 do
  @moduledoc false
  alias __MODULE__

  use EnumType

  import Prodigy.Server.Util

  defenum Function do
    value(COMMAND, 0x1)
    value(STATISTICS, 0x2)
    value(ALERT, 0x3)
    value(CONTROL, 0x4)
  end

  defenum Reason do
    value(BACKBONE, 0x1)
    value(RECEPTION_SYSTEM, 0x2)
  end

  defmodule Flags do
    @moduledoc false
    defstruct store_by_key: false,
              retrieve_by_key: false,
              binary_data: false,
              ascii_data: false

    @type t :: %Flags{
            store_by_key: boolean,
            retrieve_by_key: boolean,
            binary_data: boolean,
            ascii_data: boolean
          }

    def decode(<<a::1, b::1, c::1, d::1, _::4>>) do
      %Flags{
        store_by_key: int2bool(a),
        retrieve_by_key: int2bool(b),
        binary_data: int2bool(c),
        ascii_data: int2bool(d)
      }
    end

    def encode(%Flags{} = flags) do
      <<bool2int(flags.store_by_key)::1, bool2int(flags.retrieve_by_key)::1,
        bool2int(flags.binary_data)::1, bool2int(flags.ascii_data)::1, 0::4>>
    end
  end

  defstruct concatenated: false, function: nil, reason: nil, flags: nil, payload: nil

  @type t :: %Fm9{
          concatenated: boolean,
          function: Function,
          reason: Reason,
          flags: Flags,
          payload: binary
        }
end
