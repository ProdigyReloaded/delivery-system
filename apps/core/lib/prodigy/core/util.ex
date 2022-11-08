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

defmodule Prodigy.Core.Util do
  @moduledoc """
  General helper functions
  """

  # TODO it may not be a good idea to translate nil, but I'm doing it since the data collection fields in the database
  # come back as "nil" when they are unset
  def int2bool(1), do: true
  def int2bool(0), do: false
  def int2bool(nil), do: false

  def bool2int(true), do: 1
  def bool2int(false), do: 0
  def bool2int(nil), do: 0

  def fixed_chunk(size, payload) do
    for <<value::binary-size(size) <- payload>>, do: value
  end

  def length_value_chunk(payload, values \\ [])

  def length_value_chunk(<<>>, values) do
    values
  end

  def length_value_chunk(payload, values) do
    <<length, value::binary-size(length), rest::binary>> = payload
    length_value_chunk(rest, values ++ [value])
  end

  def val_or_else(val, other) do
    if is_nil(val), do: other, else: val
  end
end
