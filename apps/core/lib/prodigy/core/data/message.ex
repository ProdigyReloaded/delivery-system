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

defmodule Prodigy.Core.Data.Message do
  use Ecto.Schema

  @moduledoc """
  Schema specific to messaging and related change functions
  """

  # set this by select count(*) from messages where to = 'AAAA12A'
  # next message slot will be count + 1 % 2^16

  # TODO denormalize this

  @primary_key false
  schema "message" do
    field(:from_id, :string)
    field(:from_name, :string)
    field(:to_id, :string, primary_key: true)
    field(:index, :integer, primary_key: true)
    field(:subject, :string)
    field(:sent_date, :utc_datetime)
    field(:retain_date, :utc_datetime)
    field(:contents, :binary)
    field(:retain, :boolean)
    field(:read, :boolean)
  end

  def changeset(message, params \\ %{}) do
    message
    |> Ecto.Changeset.change(params)

    #    |> Ecto.Changeset.cast(params, [:logged_on])
    #    |> Ecto.Changeset.validate_required([:logged_on])
  end
end
