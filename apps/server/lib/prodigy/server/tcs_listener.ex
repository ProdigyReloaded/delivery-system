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

defmodule Prodigy.Server.TcsListener do
  @moduledoc """
  For each connection, an instance of Prodigy.Server.Protocol.Tcs is executed.  This module implements the Ranch
  specified behaviors.
  """

  def child_spec([ranch_opts, tcs_opts]) do
    :ranch.child_spec(__MODULE__, :ranch_tcp, ranch_opts, Prodigy.Server.Protocol.Tcs, tcs_opts)
  end
end
