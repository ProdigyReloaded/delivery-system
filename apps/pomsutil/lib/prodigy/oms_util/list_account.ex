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

defmodule ListAccount do
  @moduledoc false

  alias Prodigy.Core.Data.{Household, Repo, User}

  import Ecto.Query
  import ExPrintf

  defp pre(:user) do
    IO.puts(
      String.trim("""
      User ID
      -------
      """)
    )
  end

  defp pre(:household) do
    IO.puts(
      String.trim("""
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

  def exec(type, argv, args \\ %{})

  def exec(:user, _argv, args) do
    pre(:user)

    User
    |> where([user], like(user.id, ^Map.get(args, :like, "%")))
    |> Repo.all()
    |> Enum.each(fn user ->
      each(:user, user.id)
    end)
  end

  def exec(:household, _argv, args) do
    pre(:household)

    Household
    |> where([household], like(household.id, ^Map.get(args, :like, "%")))
    |> Repo.all()
    |> Enum.each(fn household ->
      each(:household, household.id)
    end)
  end
end
