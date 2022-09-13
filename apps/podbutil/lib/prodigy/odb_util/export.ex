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

defmodule Export do
  @moduledoc false

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Object

  import Ecto.Query
  import ExPrintf
  import Config

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
  defp pre(source, _endian, _prologue) do
  end

  defp each(filename, sequence, type, version, data, args) do
    filename = sprintf("%s_%d_%x_%d", [String.trim(filename), sequence, type, version])
    {:ok, file} = File.open(Path.join(args.target, filename), [:write])
    IO.binwrite(file, data)
    File.close(file)
    IO.puts(sprintf("Wrote %d bytes to %s", [byte_size(data), filename]))
  end

  defp post do
  end

  def exec(argv, args \\ %{}) do
    {database, user, hostname, port} = Prodigy.OdbUtil.DbUtil.start(argv)

    Object
    |> where([o], like(o.name, ^args.like))
    |> Repo.all()
    |> Enum.each(fn obj ->
      <<name::binary-size(8), ext::binary>> = obj.name

      each(
        sprintf("%8s.%3s", [name, ext]),
        obj.sequence,
        obj.type,
        obj.version,
        obj.contents,
        args
      )
    end)
  end
end
