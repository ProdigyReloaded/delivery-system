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

defmodule Import do
  @moduledoc false

  alias Prodigy.Core.Data.{Object, Repo}

  import Ecto.Changeset

  def parse_object(content) do
    <<
      object_id::binary-size(11),
      sequence,
      type,
      _length::16-little,
      candidacy_version_high,
      _set_size,
      candidacy_version_low,
      _rest::binary
    >> = content

    <<_candidacy::3, version::13>> = <<candidacy_version_high, candidacy_version_low>>

    %Object{name: object_id, sequence: sequence, type: type, version: version, contents: content}
  end

  def exec(argv, _args \\ %{}) do
    Repo.transaction(fn ->
      count =
        Enum.flat_map(argv, fn arg -> Path.wildcard(arg) end)
        |> Enum.map(fn f ->
          File.read!(f)
          |> parse_object
          |> change
          |> Repo.insert()
        end)
        |> Enum.count()

      IO.puts("- Imported #{count} objects")
    end)
  end
end
