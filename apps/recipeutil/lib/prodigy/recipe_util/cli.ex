defmodule RecipeUtil.CLI do

  alias Prodigy.Core.Data.Util

  defp usage(:verbose, message \\ "") do
    IO.puts("#{message}\n")

    script = :escript.script_name()

    IO.puts("""
      RecipeUtil - A utility for manipulating GCU recipe files for the Prodigy System

      Usage:

        #{script} [-h | --help] [-r | --recurse] <command> { command arguments ... }

        -h, --help    This help
    """)

    exit(:shutdown)
  end



  def main(args) do
    {parsed, rest, _invalid} =
      OptionParser.parse(args,
        aliases: [
          d: :dest,
          s: :source,
          h: :help,
          p: :page_setup,
          n: :news_setup
        ],
        strict: [
          help: :boolean,
          dest: :string,
          source: :string,
          page_setup: :boolean,
          news_setup: :boolean
        ]
      )

    args = Enum.into(parsed, %{})

    dest = Map.get(args, :dest)
    IO.puts("Here's some args, rest is #{rest}, dest is #{dest}")
    IO.inspect(args)

    if Map.get(args, :help, false), do: usage(:verbose)

    Util.start_repo()

    RecipeUtil.File.run(args)

  end
end
