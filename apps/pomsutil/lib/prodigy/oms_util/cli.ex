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

defmodule Prodigy.OmsUtil.CLI do
  @moduledoc false

  alias Prodigy.Core.Data.Util

  def usage(mode, message \\ "")

  def usage(:terse, message) do
    IO.puts("#{message}\n")

    exit(:shutdown)
  end

  def usage(:verbose, message) do
    IO.puts("#{message}\n")

    script = :escript.script_name()

    IO.puts("""
      pomsutil - a utility for manipulating Prodigy Reloaded user accounts

      Usage:

        #{script} [-h | --help] <command> { command arguments ... }

        --help    This help
        -u, --user <username>   - the username to use when connecting to the
                                  Prodigy database, defaults to DB_USER
        -h, --host <hostname>   - the database hostname, defaults to DB_HOST
        -p, --port <port>       - the database port number, defaults to
                                  DB_PORT, or 5432 if unset
        -d, --database <name>   - the database name, defaulst to DB_NAME

      Datasource:

          The following environment variables are utilized when an alternative is
          not provided as an argument:

          DB_HOST
          DB_USER
          DB_PORT      (defaults to 5432)
          DB_PASS
          DB_NAME

          If DB_PASS is unset, then the user will be prompted for a password.

      Commands:

        list-households [--like <pattern>]
          Displays a listing of household accounts found at <datasource>

        list-users [--like <pattern>]
          Displays a listing of user accounts found at <datasource>

        create [XXXX[YY]] [password]
          When no arguments, XXXX, or XXXXYY are given, creates a household
          with household ID next in sequence, or with XXXXYY as specified.

          Creates the "A" user record, with the given password, or if none is
          given, generates one randomly which is printed to the console.

          If XXXXYY already exists, an error is given.

        delete <XXXXYY[Z]>
          Deletes household and/or user accounts matching the given argument.

        reset <XXXXYYZ> [password]
          Resets the password for the specified user account to the given
          password, or if none is given, geneates on randomly which is printed
          to the console.

        clear <XXXXYY[Z]>
          Terminate any active sessions for the specified account and conclude
          the related sessions in the database.
    """)

    exit(:shutdown)
  end

  def main(args) do
    {parsed, rest, _invalid} =
      OptionParser.parse(args,
        aliases: [
          d: :database,
          p: :port,
          h: :host,
          u: :username
        ],
        strict: [
          help: :boolean,
          user: :string,
          host: :string,
          port: :integer,
          database: :string,
          like: :string
        ]
      )

    args = Enum.into(parsed, %{})

    if Map.get(args, :help, false), do: usage(:verbose)

    if length(rest) < 1, do: usage(:verbose)

    [command | rest] = rest
    command = String.downcase(command)

    Util.start_repo()

    case command do
      "list-households" ->
        ListAccount.exec(:household, rest, args)

      "list-users" ->
        ListAccount.exec(:user, rest, args)

      "create" ->
        id =
          case length(rest) do
            0 ->
              :assign

            _ ->
              [id | _rest] = rest
              id
          end

        args = %{
          id: id
        }

        Create.exec(rest, args)

      "delete" ->
        #        Delete.exec(rest, args)
        IO.puts("unimplemented")

      "reset" ->
        #        Reset.exec(rest, args)
        IO.puts("unimplemented")

      "clear" ->
        #        Clear.exec(rest, args)
        IO.puts("unimplemented")

      _ ->
        usage(:verbose)
    end
  end
end
