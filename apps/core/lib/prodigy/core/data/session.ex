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

defmodule Prodigy.Core.Data.Session do
  use Ecto.Schema

  @moduledoc """
  Schema specific to individual user sessions and related change functions
  """

  schema "session" do
    belongs_to(:user, Prodigy.Core.Data.User)
    field(:logon_timestamp, :utc_datetime)
    # enroll, success, etc; this can be a small integer or enum
    field(:logon_status, :integer)
    field(:logoff_timestamp, :utc_datetime)
    # normal, abnormal, bounced, etc; this can be a small integer or enum
    field(:logoff_status, :integer)
    field(:rs_version, :string)
    # for bouncing
    field(:node, :string)
    field(:pid, :string)

    # TODO need a special mechanism to get origin IP if session originates from a softmodem that answers a SIP call
    # use the native inet field if possible
    field(:source_address, :string)
    field(:source_port, :integer)
  end
end
