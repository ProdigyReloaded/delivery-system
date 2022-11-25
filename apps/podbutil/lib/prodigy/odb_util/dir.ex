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

defmodule Dir do
  @moduledoc false

  alias Prodigy.Core.Data.{Object, Repo}

  import Ecto.Query
  import ExPrintf

  # TODO expand the object schema in the database; currently only holds:
  #    field :name, :string, primary_key: true
  #    field :sequence, :integer, primary_key: true
  #    field :type, :integer, primary_key: true
  #    field :version, :integer, primary_key: true
  #    field :contents, :binary
  # should also hold
  #    # in set
  #    length in bytes
  #    storage field
  #    keyword (?)
  defp pre do
    IO.puts(
      String.trim("""
      Name          Seq Type Version
      ------------  --- ---- -------
      """)
    )
  end

  defp each(filename, sequence, type, version, _data, _args) do
    IO.puts(sprintf("%-12s  %3d %4x %7d", [filename, sequence, type, version]))
  end

  def exec(_argv, args \\ %{}) do
    pre()

    try do
      Object
      |> where([o], like(o.name, ^args.like))
      |> Repo.all()
      |> Enum.each(fn obj ->
        <<name::binary-size(8), ext::binary>> = obj.name
        each(sprintf("%8s.%3s", [name, ext]), obj.sequence, obj.type, obj.version, nil, nil)
      end)
    rescue
      _e ->
        # Logger.error(Exception.format(:error, e, __STACKTRACE__))
        # reraise e, __STACKTRACE__
        exit(:shutdown)
    end
  end
end
