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

defmodule Prodigy.OdbUtil.CLI do
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

    # TODO - add options for import:
    #   -u | --update : if an object already exists with the same version as the object given, compare the objects and
    #     if they are different, then increment the given object's version # and insert
    #   -s | --skip : if an object already exists with the same version as the object given, compare the objects and
    #     if they are different, then skip, otherwise error out.  (if they are the same, they are always skipped)
    # TODO - add support for ITRC0001D update
    #   check every updated object; if any are "noversion", then prompt for "Force RS version check?", default to No
    #   add argument --force-version-check

    IO.puts("""
      PodbUtl - a utility for manipulating the Prodigy Reloaded Object Database

      Usage:

        #{script} [-h | --help] <command> { command arguments ... }

        --help    This help
        -u, --user <username>   - the username to use when connecting to the
                                  Prodigy database, defaults to DB_USER
        -h, --host <hostname>   - the database hostname, defaults to DB_HOST
        -p, --port <port>       - the database port number, defaults to
                                  DB_PORT, or 5432 if unset
        -d, --database <name>   - the database name, defaulst to DB_NAME

        --like <pattern>   - only apply to objects whose name matches the
                             postgresql LIKE pattern.  Use % to match any
                             characters and _ to match a single character.
                             Defaults to % for "dir", and empty otherwise

        --type N           - only apply to objects of type N, can be specified
                             multiple times.
                             Defaults to all.

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

        dir [--like <pattern>]
          Displays a directory listing of objects found at <datasource>

        export [-d | --dest <path>] [--like <pattern>]
          Export objects from <datasource>

          -d, --dest <target> - writes the files to the specified target
                                duplicate files will be suffixed with an
                                incrementing non-zero integer.
                                Defaults to the current working directory.

        import <path1> ... <pathN>
          Import specified objects to <datasource>

          <path1> ... <pathN> - filesystem paths, globs, or directories.
                                Directory args are expanded to all regular
                                files directly inside them (one level, not
                                recursive). Useful for batches that would
                                overflow the shell's ARG_MAX via glob.

          All objects will be imported within a single transaction, so if
          any are unable to be imported, none should be.

          HTTP mode:
            --url <base>            Upload via the portal's HTTP API
                                    instead of the local Repo. When
                                    supplied, DB_* env vars are not
                                    consulted.
            --api-key-file <path>   File containing the plaintext API
                                    key (one line, whitespace trimmed).
            --api-key-env <var>     Read the key from the given env var.
                                    Default: PRODIGY_API_KEY.
            --insecure              Skip TLS cert verification. Use
                                    against dev stacks where Caddy's
                                    internal CA isn't on the host trust
                                    store. Never use against prod.

          Without --url, podbutil connects directly to Postgres as before.

        list-object-types
          Lists all object types
    """)

    exit(:shutdown)
  end

  def list_object_types do
    IO.puts("""
    Object Types

    0x0 - Page Format Object
    0x4 - Page Template Object
    0x8 - Page Element Object
    0xC - Program Object
    0xE - Window Object
    """)

    exit(:shutdown)
  end

  def main(args) do
    #    Supervisor.start_link([{Prodigy.Database.Repo, []}], strategy: :one_for_one)

    {parsed, rest, _invalid} =
      OptionParser.parse(args,
        aliases: [
          c: :comment,
          d: :dest,
          h: :help
        ],
        strict: [
          help: :boolean,
          dest: :string,
          like: :string,
          type: :keep,
          comment: :string,
          url: :string,
          api_key_file: :string,
          api_key_env: :string,
          insecure: :boolean
        ]
      )

    args = Enum.into(parsed, %{})

    if Map.get(args, :help, false), do: usage(:verbose)

    if length(rest) < 1, do: usage(:verbose)

    [command | rest] = rest
    command = String.downcase(command)

    case command do
      "list-object-types" ->
        list_object_types()

      "dir" ->
        Util.start_repo()
        Dir.exec(rest, %{like: Map.get(args, :like, "%")})

      "export" ->
        Util.start_repo()
        Export.exec(rest, %{like: Map.get(args, :like, "%"), target: resolve_target(args)})

      "import" ->
        # HTTP mode if --url is supplied - skips the local Repo start
        # entirely so podbutil can run without DB_* env vars. Local
        # mode still uses the Repo as before.
        if Map.has_key?(args, :url) do
          Import.exec_http(rest, args)
        else
          Util.start_repo()
          Import.exec(rest, args)
        end

      _ ->
        usage(:verbose)
    end
  end

  defp resolve_target(args) do
    target = Map.get(args, :dest, ".")

    case File.exists?(target) do
      true ->
        case File.stat(target) do
          {:ok, %File.Stat{type: :directory}} ->
            Path.expand(target)

          {:error, errno} ->
            usage(:terse, "Error accessing destination path '#{target}: #{errno}")

          _ ->
            usage(:terse, "Error accessing destination path '#{target}', it is not a directory")
        end

      _ ->
        usage(:terse, "Destination path '#{target}' does not exist.")
    end
  end
end
