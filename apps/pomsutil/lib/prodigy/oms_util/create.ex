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

defmodule Create do
  @moduledoc false
  alias Prodigy.Core.Data.{Repo, User, Household}

  import Ecto.Query
  import Ecto.Changeset
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

  def exec(argv, args \\ %{}) do
    # TODO add support for arguments [XXXX[YY]] [password]
    # TODO retry in the case we try to insert an already existing value
    # TODO use a sequence to create in predictable order and avoid retries
    # TODO add mechanism for excluded IDs
    {database, user, hostname, port} = Prodigy.OmsUtil.DbUtil.start(argv)

    new_household = random_id()
    new_password = random_password()

    today = DateTime.to_date(DateTime.utc_now())

    %Household{id: new_household, enabled_date: today}
    |> change
    |> put_assoc(:users, [
      %User{id: new_household <> "A"}
      |> User.changeset(%{password: new_password})
    ])
    |> Repo.insert()

    IO.puts("- Created Household #{new_household}")
    IO.puts("- Created User #{new_household <> "A"} with password #{new_password}")

  end

  defp random(x) do
    Enum.to_list(x)
    |> Enum.chunk_every(1)
    |> Enum.random
  end

  defp random_char() do
    random(?A..?Z)
  end

  defp random_int() do
    random(?0..?9)
  end

  defp random_both() do
    random(Enum.chunk_every(?0..?9, 1) ++ Enum.chunk_every(?A..?Z,1))
  end

  defp random_id() do
    random_4 = Enum.map(0..3, fn _ -> random_char() end) |> Enum.join("")
    random_2 = Enum.map(0..1, fn _ -> random_int() end) |> Enum.join("")
    Enum.join([random_4, random_2], "")
  end

  defp random_password() do
    Enum.map(0..5, fn _ -> random_both() end) |> Enum.join("")
  end
end
