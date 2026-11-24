# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Prodigy.OdbUtil.GcuCLI do
  @moduledoc false
  alias Prodigy.OdbUtil.GcuRecipe

  @usage """
  Usage:
    podbutil gcu list INPUT.RCP
    podbutil gcu fill INPUT.RCP --output OUTPUT.RCP --set 'List:1=New text'
    mix prodigy.gcu list INPUT.RCP

  Repeat --set to replace multiple runs. Selectors are case-sensitive and come
  from list. Only printable ASCII is supported; line breaks and drawing/layout
  controls remain unchanged. Output must be a new file. No database is used.
  """

  def run(argv) do
    {options, rest, invalid} =
      OptionParser.parse(argv, strict: [set: :keep, output: :keep, help: :boolean])

    cond do
      invalid != [] ->
        error("invalid option: #{inspect(invalid)}")

      options[:help] ->
        IO.puts(@usage)
        0

      rest == [] ->
        error(@usage)

      true ->
        dispatch(rest, options)
    end
  end

  defp dispatch(["list", input], []) do
    with {:ok, binary} <- read(input),
         {:ok, recipe} <- GcuRecipe.parse(binary) do
      for field <- GcuRecipe.fields(recipe) do
        IO.puts("#{field.selector}\t#{inspect(field.text, printable_limit: :infinity)}")
      end

      0
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch(["fill", input], options) do
    outputs = Keyword.get_values(options, :output)
    settings = Keyword.get_values(options, :set)

    with [output] <- outputs,
         true <- settings != [],
         true <- Path.expand(input) != Path.expand(output),
         {:ok, replacements} <- assignments(settings),
         {:ok, binary} <- read(input),
         {:ok, recipe} <- GcuRecipe.parse(binary),
         {:ok, result} <- GcuRecipe.replace(recipe, replacements),
         :ok <- File.write(output, result, [:exclusive, :binary]) do
      IO.puts("Wrote #{output} (#{length(replacements)} replacements)")
      0
    else
      {:error, reason} -> error(reason)
      _ -> error("fill requires one new --output path and at least one --set selector=text")
    end
  end

  defp dispatch(_, _), do: error(@usage)

  defp assignments(settings) do
    Enum.reduce_while(settings, {:ok, []}, fn setting, {:ok, acc} ->
      case :binary.split(setting, "=") do
        [selector, text] when byte_size(selector) > 0 -> {:cont, {:ok, [{selector, text} | acc]}}
        _ -> {:halt, {:error, "each --set must be selector=text"}}
      end
    end)
  end

  defp read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        result = IO.binread(device, GcuRecipe.max_size() + 1)
        File.close(device)

        case result do
          :eof -> {:ok, <<>>}
          {:error, reason} -> {:error, reason}
          binary -> {:ok, binary}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp error(reason) do
    text = if is_atom(reason), do: :file.format_error(reason), else: reason
    IO.puts(:stderr, "gcu: #{text}")
    2
  end
end
