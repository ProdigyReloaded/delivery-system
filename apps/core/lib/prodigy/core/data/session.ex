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

defmodule Prodigy.Core.Data.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema specific to individual user sessions and related change functions
  """

  schema "session" do
    belongs_to(:user, Prodigy.Core.Data.User, type: :string)
    field(:logon_timestamp, :utc_datetime)
    field(:logon_status, :integer)  # 0=success, 1=enroll_other, 2=enroll_subscriber
    field(:logoff_timestamp, :utc_datetime)
    field(:logoff_status, :integer)  # 0=normal, 1=abnormal, 2=timeout, 3=forced
    field(:rs_version, :string)
    field(:node, :string)
    field(:pid, :string)
    field(:source_address, :string)
    field(:source_port, :integer)
    field(:last_activity_at, :utc_datetime)

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :logon_timestamp, :logon_status, :logoff_timestamp,
      :logoff_status, :rs_version, :node, :pid, :source_address,
      :source_port, :last_activity_at])
    |> validate_required([:user_id, :logon_timestamp, :logon_status, :node, :pid])
  end
end
