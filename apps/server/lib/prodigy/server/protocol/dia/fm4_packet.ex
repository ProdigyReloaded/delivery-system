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

defmodule Prodigy.Server.Protocol.Dia.Packet.Fm4 do
  @moduledoc """
  The DIA Fm4 Packet (External Gateways)

  The DIA Fm4 Header is used to manage state when communicating with DIA destinations that are external to the Prodigy
  network.
  """
  alias __MODULE__

  use EnumType

  defstruct user_id: nil, correlation_id: nil
  @type t :: %Fm4{user_id: binary, correlation_id: binary}
end
