# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Server.Protocol.Dia.Packet.Fm64 do
  @moduledoc """
  The DIA Fm64 Packet
  """
  alias __MODULE__

  use EnumType

  defenum StatusType do
    @moduledoc "An enumeration of Fm64 Status Types"

    value INFORMATION, 0x0 do
      @moduledoc false
    end

    value STATUS_REQUEST, 0x4 do
      @moduledoc false
    end

    value ERROR, 0x8 do
      @moduledoc false
    end

    value TERMINATE, 0xC do
      @moduledoc false
    end
  end

  defenum DataMode do
    @moduledoc "An enumeration of Fm64 Data Modes"

    value EBCDIC, 0x0 do
      @moduledoc false
    end

    value ASCII, 0x10 do
      @moduledoc false
    end

    value BINARY, 0x20 do
      @moduledoc false
    end
  end

  defstruct concatenated: false, status_type: nil, data_mode: nil, payload: nil

  @type t :: %Fm64{
          concatenated: boolean,
          status_type: StatusType.t(),
          data_mode: DataMode.t(),
          payload: binary
        }
end
