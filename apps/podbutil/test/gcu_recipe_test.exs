# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Prodigy.OdbUtil.GcuRecipeTest do
  use ExUnit.Case, async: true
  alias Prodigy.OdbUtil.GcuRecipe
  import ExUnit.CaptureIO

  defp record(tag, value), do: <<tag::binary, byte_size(value)::16-little, value::binary>>

  defp list(name, stencil) do
    IO.iodata_to_binary([
      record(<<1, 2>>, name <> <<0>>),
      record(<<2, 2>>, <<0>>),
      record(<<3, 2>>, <<0, 0, 1, 0, 1, 0>>),
      record(<<7, 2>>, stencil),
      record(<<99, 2>>, <<0, 255, 7>>),
      record(<<11, 2>>, <<0x0F, "unchanged original", 0xA5>>)
    ])
  end

  defp recipe do
    header =
      IO.iodata_to_binary([
        record(<<1, 1>>, "TEST.RCP" <> <<0>>),
        record(<<99, 1>>, <<8, 7, 6>>),
        record(<<5, 1>>, <<2::16-little>>),
        record(<<6, 1>>, "Title" <> <<0>> <> "Body" <> <<0>>)
      ])

    lists = [
      list("Title", <<0xB3, 0xC0, 0x0F, "Old title", 0xA5>>),
      list("Body", <<0xB1, "First", 13, 10, "Second", 0xA5>>)
    ]

    IO.iodata_to_binary([
      <<"GCULIST", 0, 0x50, 2, 0, 1, byte_size(header)::16-little>>,
      header,
      Enum.map(lists, &<<0, 2, byte_size(&1)::16-little, &1::binary>>)
    ])
  end

  test "lists named runs with stable one-based selectors and round-trips unknown records" do
    input = recipe()
    assert {:ok, parsed} = GcuRecipe.parse(input)

    assert Enum.map(GcuRecipe.fields(parsed), &{&1.selector, &1.text}) ==
             [{"Title:1", "Old title"}, {"Body:1", "First"}, {"Body:2", "Second"}]

    assert {:ok, ^input} = GcuRecipe.replace(parsed, [])
  end

  test "multiple replacements change only stencil text and length words" do
    {:ok, parsed} = GcuRecipe.parse(recipe())

    assert {:ok, result} =
             GcuRecipe.replace(parsed, [{"Title:1", "New"}, {"Body:2", "Longer second line"}])

    assert {:ok, edited} = GcuRecipe.parse(result)
    assert edited.header == parsed.header

    for {before, after_list} <- Enum.zip(parsed.lists, edited.lists) do
      assert Enum.reject(before, &(elem(&1, 0) == <<7, 2>>)) ==
               Enum.reject(after_list, &(elem(&1, 0) == <<7, 2>>))
    end

    assert {<<7, 2>>, <<0xB3, 0xC0, 0x0F, "New", 0xA5>>} in hd(edited.lists)

    assert {<<7, 2>>, <<0xB1, "First", 13, 10, "Longer second line", 0xA5>>} in Enum.at(
             edited.lists,
             1
           )
  end

  test "rejects unknown and duplicate selectors before returning any output" do
    {:ok, parsed} = GcuRecipe.parse(recipe())
    assert {:error, _} = GcuRecipe.replace(parsed, [{"Title:1", "OK"}, {"Title:2", "bad"}])
    assert {:error, _} = GcuRecipe.replace(parsed, [{"Title:1", "A"}, {"Title:1", "B"}])
    assert {:error, _} = GcuRecipe.replace(parsed, [{"title:1", "case sensitive"}])
  end

  test "rejects injected controls, Unicode and record or enclosing-list overflow" do
    {:ok, parsed} = GcuRecipe.parse(recipe())

    for value <- ["line\nbreak", <<0x1B>>, "café", <<0xA5>>] do
      assert {:error, _} = GcuRecipe.replace(parsed, [{"Title:1", value}])
    end

    for size <- [65_500, 65_536] do
      assert {:error, _} = GcuRecipe.replace(parsed, [{"Title:1", String.duplicate("a", size)}])
    end

    assert {:ok, result} = GcuRecipe.replace(parsed, [{"Title:1", ""}])
    assert {:ok, _} = GcuRecipe.parse(result)
  end

  test "rejects every truncated prefix and trailing or mismatched records" do
    input = recipe()

    for size <- 0..(byte_size(input) - 1) do
      assert {:error, _} = GcuRecipe.parse(binary_part(input, 0, size))
    end

    assert {:error, _} = GcuRecipe.parse(input <> <<1>>)

    assert {:error, _} =
             GcuRecipe.parse(
               :binary.replace(input, "Title" <> <<0>>, "Other" <> <<0>>, [:global])
               |> then(&binary_part(&1, 0, byte_size(&1) - 1))
             )

    assert {:error, _} =
             GcuRecipe.parse(:binary.replace(input, <<5, 1, 2, 0, 2, 0>>, <<5, 1, 2, 0, 1, 0>>))

    assert {:error, _} = GcuRecipe.parse(:binary.replace(input, "Body" <> <<0>>, "Else" <> <<0>>))
  end

  test "refuses to edit a stencil using unsupported encoding shifts" do
    input = :binary.replace(recipe(), <<0xB3, 0xC0, 0x0F>>, <<0x0E, 0xC0, 0x0F>>)
    assert {:ok, parsed} = GcuRecipe.parse(input)
    assert {:error, _} = GcuRecipe.replace(parsed, [{"Title:1", "Unsafe"}])
    assert {:ok, ^input} = GcuRecipe.replace(parsed, [])
  end

  test "CLI lists and fills without a database, rejects bad arguments and never overwrites" do
    dir = Path.join(System.tmp_dir!(), "gcu-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    input = Path.join(dir, "in.rcp")
    output = Path.join(dir, "out.rcp")
    File.write!(input, recipe())

    assert capture_io(fn -> assert Prodigy.OdbUtil.GcuCLI.run(["list", input]) == 0 end) =~
             "Body:2"

    capture_io(fn ->
      assert Prodigy.OdbUtil.GcuCLI.run([
               "fill",
               input,
               "--output",
               output,
               "--set",
               "Title:1=Welcome",
               "--set",
               "Body:1=Lab ready"
             ]) == 0
    end)

    original = File.read!(input)
    edited = File.read!(output)

    for args <- [
          ["fill", input, "--output", output, "--set", "Title:1=X"],
          ["fill", input, "--output", input, "--set", "Title:1=X"],
          ["fill", input, "--output", output <> "x", "--set", "Unknown:1=X"],
          ["fill", input, "--output", output <> "x", "--set", "Title:1=X", "--set", "Title:1=Y"],
          ["list", input, "--bogus"],
          ["fill", input, "--output", output <> "x", "--set", "broken"],
          ["fill", input, "--output", output <> "x"],
          [
            "fill",
            input,
            "--output",
            output <> "x",
            "--output",
            output <> "y",
            "--set",
            "Title:1=X"
          ]
        ] do
      capture_io(:stderr, fn -> assert Prodigy.OdbUtil.GcuCLI.run(args) == 2 end)
    end

    refute File.exists?(output <> "x")
    assert File.read!(input) == original
    assert File.read!(output) == edited
  end
end
