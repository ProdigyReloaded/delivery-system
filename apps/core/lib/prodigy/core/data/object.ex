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

defmodule Prodigy.Core.Data.Object do
  use Ecto.Schema

  @moduledoc """
  Schema specific objects
  """

  @primary_key false
  schema "object" do
    field(:name, :string, primary_key: true)
    field(:sequence, :integer, primary_key: true)
    field(:type, :integer, primary_key: true)
    field(:version, :integer, primary_key: true)
    field(:contents, :binary)
  end
end

# object_id is 13 bytes comprised of concatenation of name (11), sequence, type.
# there should be uniqueness of (name, sequence, type, version)
