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

  def parse_object(content, _filename) do
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

  def parse_object_raw(content, filename) do
    [filename_prefix, filename_suffix] = String.split(Path.basename(filename), ".")
    [ext, sequence, type, version] = String.split(filename_suffix, "_")

    object_id = String.pad_trailing(filename_prefix <> ext, 11)

    %Object{name: object_id,
            sequence: String.to_integer(sequence),
            type: String.to_integer(type),
            version: String.to_integer(version),
            contents: content}
  end

  def exec(argv, args \\ %{}) do

    parse_fn = case Map.get(args, :raw) do
      true -> &Import.parse_object_raw/2
      _ -> &Import.parse_object/2
    end

    Repo.transaction(fn ->
      count =
        Enum.flat_map(argv, fn arg -> Path.wildcard(arg) end)
        |> Enum.map(fn f ->
          File.read!(f)
          |> parse_fn.(f)
          |> change
          |> Repo.insert()
        end)
        |> Enum.count()

      IO.puts("- Imported #{count} objects")
    end)
  end
end
