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

defmodule Prodigy.Server.Context do
  @moduledoc """
  Structure containing context for an individual Prodigy Connection.

  The Context structure is established when the `Prodigy.Server.Router` instance is created upon client connection, and
  persists until the connection is terminated.
  """

  defstruct [:user, :rs_version, :auth_timeout, :messaging]

  def set_auth_timer do
    Process.send_after(self(), :auth_timeout, Application.fetch_env!(:server, :auth_timeout))
  end

  def cancel_auth_timer(ref) do
    Process.cancel_timer(ref)
  end
end
