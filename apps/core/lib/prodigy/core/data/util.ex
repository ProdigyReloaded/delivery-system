# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Core.Data.Util do
  @moduledoc """
  Helper utilities to start the Database Repository supervisor outside of the Prodigy Server
  """

  alias Prodigy.Core.Data.Repo

  defp get_password do
    password = System.get_env("DB_PASS", nil)

    if password == nil do
      IO.puts("TODO - prompt for password")
      #        Mix.Tasks.Hex.password_get("Password: ")
      #        |> String.replace_trailing("\n","")
    else
      password
    end
  end

  defp validate_arguments(user, password, hostname, port, database) do
    if user == nil or user == "" or
         password == nil or password == "" or
         hostname == nil or hostname == "" or
         port == nil or port == "" or
         database == nil or database == "" do
      IO.puts("A username, password, hostname, port number, and database name must be specified.")
      exit(:shutdown)
    end
  end

  def start_repo do
    database = System.get_env("DB_NAME", "")
    user = System.get_env("DB_USER", "")
    password = get_password()
    hostname = System.get_env("DB_HOST", "localhost")
    port = String.to_integer(System.get_env("DB_PORT", "5432"))

    validate_arguments(user, password, hostname, port, database)

    Repo.start_link(
      database: database,
      username: user,
      password: password,
      hostname: hostname,
      port: port
    )
  end
end
