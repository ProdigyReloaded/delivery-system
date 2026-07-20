# Copyright 2026, Phillip Heller
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

defmodule Prodigy.Server.Protocol.Dia.Packet.Fm2 do
  @moduledoc """
  The DIA Fm2 Packet (Transport Level Information)

  The DIA Fm2 Header is used when a logical application message has been subdivided into multiple 1K blocks for
  transmission.  Each block is sent as a separate DIA packet carrying its own Fm0 envelope and an Fm2 header that
  identifies the block sequence and the total number of blocks in the logical message.
  """
  alias __MODULE__

  use EnumType

  defstruct num_blocks: nil, block_num: nil
  @type t :: %Fm2{num_blocks: integer, block_num: integer}
end
