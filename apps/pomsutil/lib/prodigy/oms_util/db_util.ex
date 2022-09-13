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

defmodule Prodigy.OmsUtil.DbUtil do
  @moduledoc false
  def start(argv) do
    {uri, rest} =
      if Enum.empty?(argv) do
        {URI.parse("db://"), []}
      else
        [uri | rest] = argv
        {URI.parse(uri), rest}
      end

    database =
      (uri.path && String.slice(uri.path, 1..(String.length(uri.path) - 1))) ||
        System.get_env("DB_NAME", "")

    user = uri.userinfo || System.get_env("DB_USER", "")
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

    hostname =
      (uri.host != nil && String.length(uri.host) > 0 && uri.host) ||
        System.get_env("DB_HOST", "localhost")

    port = uri.port || String.to_integer(System.get_env("DB_PORT", "5432"))

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
