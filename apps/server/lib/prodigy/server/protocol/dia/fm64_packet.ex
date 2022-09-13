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

defmodule Prodigy.Server.Protocol.Dia.Packet.Fm64 do
  @moduledoc false
  alias __MODULE__

  use EnumType

  defenum StatusType do
    value(INFORMATION, 0x0)
    value(STATUS_REQUEST, 0x4)
    value(ERROR, 0x8)
    value(TERMINATE, 0xC)
  end

  defenum DataMode do
    value(EBCDIC, 0x0)
    value(ASCII, 0x10)
    value(BINARY, 0x20)
  end

  defstruct concatenated: false, status_type: nil, data_mode: nil, payload: nil

  @type t :: %Fm64{
          concatenated: boolean,
          status_type: StatusType,
          data_mode: DataMode,
          payload: binary
        }
end
