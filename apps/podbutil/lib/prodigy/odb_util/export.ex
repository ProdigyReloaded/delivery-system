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

defmodule Export do
  @moduledoc false

  #  alias Prodigy.OdbUtil.DbUtil
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

  defp each(filename, sequence, type, version, data, args) do
    filename = sprintf("%s_%d_%x_%d", [String.trim(filename), sequence, type, version])
    {:ok, file} = File.open(Path.join(args.target, filename), [:write])
    IO.binwrite(file, data)
    File.close(file)
    IO.puts(sprintf("Wrote %d bytes to %s", [byte_size(data), filename]))
  end

  def exec(_argv, args \\ %{}) do
    #    {_database, _user, _hostname, _port} = DbUtil.start(argv)

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
