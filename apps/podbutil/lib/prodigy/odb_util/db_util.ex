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

defmodule Prodigy.OdbUtil.DbUtil do
  @moduledoc false

  def start(argv) do
    database = System.get_env("DB_NAME", "")
    user = System.get_env("DB_USER", "")
    password = System.get_env("DB_PASS", nil)

    password =
      cond do
        password == nil ->
          IO.puts("TODO - prompt for password")

        #        Mix.Tasks.Hex.password_get("Password: ")
        #        |> String.replace_trailing("\n","")
        true ->
          password
      end

    hostname = System.get_env("DB_HOST", "localhost")
    port = String.to_integer(System.get_env("DB_PORT", "5432"))

    if user == nil or user == "" or
         password == nil or password == "" or
         hostname == nil or hostname == "" or
         port == nil or port == "" or
         database == nil or database == "" do
      IO.puts("A username, password, hostname, port number, and database name must be specified.")
      exit(:shutdown)
    end

    Prodigy.Core.Data.Repo.start_link(
      database: database,
      username: user,
      password: password,
      hostname: hostname,
      port: port
    )

    {database, user, hostname, port}
  end
end
