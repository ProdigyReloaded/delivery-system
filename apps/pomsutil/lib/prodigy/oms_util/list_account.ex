# Copyright 2022, Phillip Heller
#
# This file is part of pomsutil.
#
# pomsutil is free software: you can redistribute it and/or modify it under the terms of the GNU General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# pomsutil is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with pomsutil. If not,
# see <https://www.gnu.org/licenses/>.

defmodule ListAccount do
  @moduledoc false
  alias Prodigy.Core.Data.{Repo, User, Household}

  import Ecto.Query
  import ExPrintf
  import Config

  defp pre(:user, source) do
    IO.puts(
      String.trim("""
      Source: #{source}

      User ID
      -------
      """)
    )
  end

  defp pre(:household, source) do
    IO.puts(
      String.trim("""
      Source: #{source}

      Household ID
      ------------
      """)
    )
  end

  defp each(:user, id) do
    IO.puts(sprintf("%7s", [id]))
  end

  defp each(:household, id) do
    IO.puts(sprintf("%6s", [id]))
  end

  defp post do
  end

  def exec(type, argv, args \\ %{})

  def exec(:user, argv, args) do
    {database, user, hostname, port} = Prodigy.OmsUtil.DbUtil.start(argv)

    pre(:user, sprintf("podb://%s@%s:%d/%s", [user, hostname, port, database]))

    User
    |> where([user], like(user.id, ^Map.get(args, :like, "%")))
    |> Repo.all()
    |> Enum.each(fn user ->
      each(:user, user.id)
    end)
  end

  def exec(:household, argv, args) do
    {database, user, hostname, port} = Prodigy.OmsUtil.DbUtil.start(argv)

    pre(:household, sprintf("podb://%s@%s:%d/%s", [user, hostname, port, database]))

    Household
    |> where([household], like(household.id, ^Map.get(args, :like, "%")))
    |> Repo.all()
    |> Enum.each(fn household ->
      each(:household, household.id)
    end)
  end
end
