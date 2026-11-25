# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Prodigy.OdbUtil.GcuRecipe do
  @moduledoc """
  Lossless reader and text-run editor for the GCULIST 0x50020001 recipe format.

  Records are length-prefixed, not fixed-width. Unknown records and the original
  NAPLPS (0x0B02) are preserved. Only printable ASCII runs in stencil NAPLPS
  (0x0702) are editable; positioning, line breaks and drawing bytes stay intact.
  Selectors are case-sensitive list names followed by a one-based run number.
  """
  @magic <<"GCULIST", 0, 0x50, 2, 0, 1>>
  @max_size 16 * 1024 * 1024
  defstruct header: [], lists: []

  def max_size, do: @max_size

  @doc "Parse and validate record boundaries, list counts and ordered names."
  def parse(binary) when is_binary(binary) do
    protect(fn ->
      require!(byte_size(binary) <= @max_size, "recipe exceeds the 16 MiB limit")

      case binary do
        <<@magic, size::16-little, rest::binary>> when byte_size(rest) >= size ->
          <<header::binary-size(size), blocks::binary>> = rest
          header = records(header, 14)
          lists = blocks(blocks, 14 + size)
          <<count::16-little>> = sized!(value!(header, <<5, 1>>), 2, "list count")
          names = names!(value!(header, <<6, 1>>))
          actual = Enum.map(lists, &list_name/1)
          require!(count == length(lists), "list count does not match recipe blocks")
          require!(names == actual, "header list names do not match recipe blocks")
          require!(length(Enum.uniq(actual)) == count, "duplicate list names")
          %__MODULE__{header: header, lists: lists}

        _ ->
          fail!("invalid or truncated GCULIST 0x50020001 recipe header")
      end
    end)
  end

  @doc "List editable runs. Selectors always refer to the unmodified input recipe."
  def fields(%__MODULE__{lists: lists}) do
    Enum.flat_map(lists, fn records ->
      name = list_name(records)

      records
      |> value!(<<7, 2>>)
      |> runs()
      |> Enum.with_index(1)
      |> Enum.map(fn {{offset, text}, index} ->
        %{
          selector: "#{name}:#{index}",
          list: name,
          index: index,
          text: text,
          offset: offset,
          bytes: byte_size(text)
        }
      end)
    end)
  end

  @doc "Replace multiple selectors atomically in memory and rebuild all lengths."
  def replace(%__MODULE__{} = recipe, replacements) when is_list(replacements) do
    protect(fn ->
      selectors =
        Enum.map(replacements, fn
          {selector, text} when is_binary(selector) and is_binary(text) ->
            require!(ascii?(text), "replacement text must be printable ASCII without line breaks")
            selector

          _ ->
            fail!("replacements must be {selector, text} pairs")
        end)

      require!(
        length(selectors) == length(Enum.uniq(selectors)),
        "duplicate replacement selector"
      )

      known = MapSet.new(Enum.map(fields(recipe), & &1.selector))

      Enum.each(selectors, fn selector ->
        require!(MapSet.member?(known, selector), "unknown text selector: #{selector}")
      end)

      changes = Map.new(replacements)

      lists =
        Enum.map(recipe.lists, fn records ->
          name = list_name(records)

          Enum.map(records, fn
            {<<7, 2>>, stencil} ->
              {<<7, 2>>, replace_runs(stencil, name, changes)}

            record ->
              record
          end)
        end)

      header = encode_records(recipe.header)

      result =
        IO.iodata_to_binary([
          @magic,
          u16!(byte_size(header)),
          header,
          Enum.map(lists, fn records ->
            body = encode_records(records)
            [<<0, 2>>, u16!(byte_size(body)), body]
          end)
        ])

      require!(byte_size(result) <= @max_size, "result exceeds the 16 MiB limit")
      result
    end)
  end

  defp records(binary, offset), do: records(binary, offset, [])
  defp records(<<>>, _offset, acc), do: Enum.reverse(acc)

  defp records(<<tag::binary-size(2), size::16-little, rest::binary>>, offset, acc)
       when byte_size(rest) >= size do
    <<value::binary-size(size), tail::binary>> = rest
    records(tail, offset + 4 + size, [{tag, value} | acc])
  end

  defp records(_, offset, _acc), do: fail!("truncated record at byte #{offset}")

  defp blocks(binary, offset), do: blocks(binary, offset, [])
  defp blocks(<<>>, _offset, acc), do: Enum.reverse(acc)

  defp blocks(<<0, 2, size::16-little, rest::binary>>, offset, acc)
       when byte_size(rest) >= size do
    <<body::binary-size(size), tail::binary>> = rest
    list = records(body, offset + 4)
    list_name(list)
    value!(list, <<7, 2>>)
    blocks(tail, offset + 4 + size, [list | acc])
  end

  defp blocks(_, offset, _acc), do: fail!("invalid or truncated list block at byte #{offset}")

  defp value!(records, tag) do
    case for({^tag, value} <- records, do: value) do
      [value] -> value
      [] -> fail!("missing record #{Base.encode16(tag)}")
      _ -> fail!("duplicate record #{Base.encode16(tag)}")
    end
  end

  defp list_name(records) do
    case names!(value!(records, <<1, 2>>)) do
      [name] -> name
      _ -> fail!("list name must be one nonempty NUL-terminated ASCII string")
    end
  end

  defp names!(binary) do
    names = :binary.split(binary, <<0>>, [:global])

    case Enum.reverse(names) do
      ["" | rest] ->
        result = Enum.reverse(rest)
        require!(Enum.all?(result, &(byte_size(&1) > 0 and ascii?(&1))), "invalid list name")
        result

      _ ->
        fail!("list names must be NUL-terminated ASCII strings")
    end
  end

  defp sized!(value, size, label) do
    require!(byte_size(value) == size, "invalid #{label} size")
    value
  end

  # In the supported 8-bit NAPLPS stream, GL printable bytes hold text and
  # GR bytes hold drawing commands/operands. Keep all control bytes opaque.
  defp runs(binary), do: runs(binary, 0, nil, [])
  defp runs(<<>>, _offset, nil, acc), do: Enum.reverse(acc)
  defp runs(<<>>, _offset, {_start, _bytes} = run, acc), do: Enum.reverse([finish(run) | acc])

  defp runs(<<byte, rest::binary>>, offset, run, acc) when byte in 0x20..0x7E do
    run =
      case run do
        nil -> {offset, [byte]}
        {start, bytes} -> {start, [byte | bytes]}
      end

    runs(rest, offset + 1, run, acc)
  end

  defp runs(<<_byte, rest::binary>>, offset, nil, acc), do: runs(rest, offset + 1, nil, acc)

  defp runs(<<_byte, rest::binary>>, offset, run, acc),
    do: runs(rest, offset + 1, nil, [finish(run) | acc])

  defp finish({start, bytes}), do: {start, bytes |> Enum.reverse() |> :erlang.list_to_binary()}

  defp replace_runs(stencil, name, changes) do
    spans = runs(stencil)

    targeted? =
      spans
      |> Enum.with_index(1)
      |> Enum.any?(fn {_, i} -> Map.has_key?(changes, "#{name}:#{i}") end)

    if targeted? do
      require!(
        Enum.all?(:binary.bin_to_list(stencil), fn byte ->
          byte in 0x20..0x7E or byte >= 0xA0 or byte in [10, 13, 15]
        end),
        "selected stencil uses unsupported NAPLPS controls or encoding"
      )
    end

    {parts, offset} =
      spans
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {{start, text}, index}, {parts, offset} ->
        prefix = binary_part(stencil, offset, start - offset)
        replacement = Map.get(changes, "#{name}:#{index}", text)
        {[parts, prefix, replacement], start + byte_size(text)}
      end)

    IO.iodata_to_binary([parts, binary_part(stencil, offset, byte_size(stencil) - offset)])
  end

  defp encode_records(records) do
    records
    |> Enum.map(fn {tag, value} -> [tag, u16!(byte_size(value)), value] end)
    |> IO.iodata_to_binary()
  end

  defp u16!(n) do
    require!(n <= 65_535, "record or list exceeds the 16-bit length limit")
    <<n::16-little>>
  end

  defp ascii?(binary), do: Enum.all?(:binary.bin_to_list(binary), &(&1 in 0x20..0x7E))
  defp require!(true, _message), do: :ok
  defp require!(false, message), do: fail!(message)
  defp fail!(message), do: throw({:gcu_error, message})

  defp protect(fun) do
    {:ok, fun.()}
  catch
    {:gcu_error, message} -> {:error, message}
  end
end
