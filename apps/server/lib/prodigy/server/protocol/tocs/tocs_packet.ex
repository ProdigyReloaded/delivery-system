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

defmodule Prodigy.Server.Protocol.Tocs.Packet do
  @moduledoc """
  TOCS Packet Structure and encoding function.
  """

  alias __MODULE__
  use EnumType
  require Logger

  @enforce_keys [:seq]
  defstruct [:seq, payload: <<>>, blocknum: 0, blockstot: 0]
  @type t :: %Packet{seq: integer(), payload: binary(), blocknum: integer(), blockstot: integer()}

  @spec encode(Packet.t()) :: <<_::48, _::_*8>>
  def encode(%Packet{} = packet) do
    <<0, packet.seq, packet.blocknum, packet.blockstot, byte_size(packet.payload)::16-big,
      packet.payload::binary>>
  end

  # no decode, because these packets are unidirectional to the reception system
end
