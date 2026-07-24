# Copyright 2022-2025, Ralph Richard Cook
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

defmodule Prodigy.Server.Service.Sabre.SabreData do
  @moduledoc """
  Compile-time loaded reference data for airport and airline code lookups.
  """

  @data_into_map fn file ->
    for line <- File.stream!(file, [], :line), into: %{} do
      [faa_code, airport_name] = line |> String.split(";") |> Enum.map(&String.trim(&1))
      {faa_code, airport_name}

    end
  end

  @external_resource airports_file = Path.join([__DIR__, "us_airports.txt"])
  @external_resource airlines_file = Path.join([__DIR__, "airlines.txt"])

  @airports_map @data_into_map.(airports_file)
  @airlines_map @data_into_map.(airlines_file)

  def airports_map do
    @airports_map
  end

  def airlines_map do
    @airlines_map
  end
end
