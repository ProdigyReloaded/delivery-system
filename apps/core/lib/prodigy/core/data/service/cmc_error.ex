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

defmodule Prodigy.Core.Data.Service.CmcError do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for CMC error reports (dying gasp messages) from client software
  """

  schema "cmc_error" do
    belongs_to(:session, Prodigy.Core.Data.Service.Session)
    field(:user_id, :string)
    field(:system_origin, :string)
    field(:msg_origin, :string)
    field(:unit_id, :string)      # These correspond to RS components
    field(:error_code, :string)   # These are component-specific errors
    field(:severity_level, :string)
    field(:error_threshold, :string)
    field(:error_date, :string)  # Original format from client
    field(:error_time, :string)  # Original format from client
    field(:api_event, :string)
    field(:mem_to_start, :string)
    field(:dos_version, :string)
    field(:rs_version, :string)
    field(:window_id, :string)
    field(:window_last, :string)
    field(:selected_id, :string)
    field(:selected_last, :string)
    field(:base_id, :string)
    field(:base_last, :string)
    field(:keyword, :string)
    field(:raw_payload, :binary)  # Store the original binary for debugging

    timestamps(updated_at: false)
  end

  def changeset(cmc_error, attrs) do
    cmc_error
    |> cast(attrs, [
      :session_id, :user_id, :system_origin, :msg_origin, :unit_id,
      :error_code, :severity_level, :error_threshold, :error_date,
      :error_time, :api_event, :mem_to_start, :dos_version, :rs_version,
      :window_id, :window_last, :selected_id, :selected_last,
      :base_id, :base_last, :keyword, :raw_payload
    ])
    |> validate_required([:session_id, :user_id, :error_code, :severity_level])
  end
end