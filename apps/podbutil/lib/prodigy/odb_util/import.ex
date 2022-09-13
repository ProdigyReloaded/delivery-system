# Copyright 2022, Phillip Heller
#
# This file is part of podbutil.
#
# podbutil is free software: you can redistribute it and/or modify it under the terms of the GNU General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# podbutil is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with podbutil. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Import do
  @moduledoc false

  alias Prodigy.Core.Data.{Repo, Object}

  import Ecto.Changeset
  import Ecto.Query
  import ExPrintf
  import Config
  import Logger

  defp pre(source, _endian, _prologue) do
  end

  defp each(filename, sequence, type, version, comment, data, _args) do
  end

  defp post do
  end

  def parse_object(content) do
    <<
      object_id::binary-size(11),
      sequence,
      type,
      length::16-little,
      candidacy_version_high,
      set_size,
      candidacy_version_low,
      rest::binary
    >> = content

    <<candidacy::3, version::13>> = <<candidacy_version_high, candidacy_version_low>>

    %Object{name: object_id, sequence: sequence, type: type, version: version, contents: content}
  end

  def exec(argv, args \\ %{}) do
    {database, user, hostname, port} = Prodigy.OdbUtil.DbUtil.start(argv)

    Repo.transaction(fn ->
      count =
      Enum.flat_map(argv, fn arg -> Path.wildcard(arg) end)
      |> Enum.map(fn f ->
        File.read!(f)
        |> parse_object
        |> change
        |> Repo.insert
      end)
      |> Enum.count

      IO.puts("- Imported #{count} objects")
    end)
  end
end
