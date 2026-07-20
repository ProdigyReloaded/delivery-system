# Copyright 2026, Phillip Heller
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

defmodule Prodigy.Core.Objects.Ccdam do
  @moduledoc """
  Builds CCDAM (Common Code Data Access Method) database objects - the
  B-tree-on-objects format the reception system's data-access driver
  reads. Each search key becomes a tree: a sequence set (top tier),
  optional intermediate index pages, and leaf IDOs (Index Data Objects)
  carrying the records, all wrapped as ordinary Prodigy data objects
  via `Prodigy.Core.Objects.Codec.build/1`.

  Scope: `db_type` 0 (simple records) and 1 (target data with a TDO
  reference after each key), `db_driver` 1. That covers the apps this
  codebase generates server-side (Member List 3B/3L); `db_type` 3
  (Grolier) and `db_driver` 2 are not ported.

  The encoder is verified against captured golden fixtures of the
  on-wire format (see the module tests).

  ## Shape

      schema = %Ccdam.Schema{
        db_handle: "3B", db_type: 0, db_driver: 1,
        fields: [Ccdam.fixed("user_id", 7), Ccdam.fixed("state", 2), ...],
        search_keys: [%Ccdam.SearchKey{key_id: 1, name: "by_name",
                       fields: [{"last_name", 1}, {"first_name", 1}]}]
      }

      # DAD object (e.g. "3B000000.D01")
      dad_blob = Ccdam.dad_object(schema, length(records), version: 1)

      # one tree per key; `write` is called with each object blob
      Ccdam.build_index(schema, 1, records, version: 1, records_per_ido: 20,
                        keys_per_index_page: 10, write: fn blob -> ... end)

  `records` are plain maps keyed by field name (`%{"user_id" => "AAAA11A",
  ...}`); missing fields default to `""`.
  """

  alias Prodigy.Core.Objects.Codec

  # --- Field descriptors ---------------------------------------------

  defmodule Field do
    @moduledoc """
    A DAD field: `:fixed` (length-padded), `:varchar1`/`:varchar2`
    (length-prefixed), `:integer` (2-byte BE), `:decimal` (28-byte).
    """
    import Bitwise, only: [band: 2]

    @enforce_keys [:name, :kind]
    defstruct [:name, :kind, length: 0]

    @type kind :: :fixed | :varchar1 | :varchar2 | :integer | :decimal
    @type t :: %__MODULE__{name: String.t(), kind: kind(), length: non_neg_integer()}

    # DAD descriptor: <<type_code, extra::16-big>>. `extra` is the
    # length for :fixed, 0 otherwise.
    @kind_code %{varchar1: 1, varchar2: 2, decimal: 3, integer: 4, fixed: 5}

    @spec descriptor(t()) :: binary()
    def descriptor(%__MODULE__{kind: :fixed, length: len}), do: <<5, len::16-big>>
    def descriptor(%__MODULE__{kind: kind}), do: <<Map.fetch!(@kind_code, kind), 0::16-big>>

    @spec format(t(), term()) :: binary()
    def format(%__MODULE__{kind: :fixed, length: 1}, value) when is_integer(value),
      do: <<band(value, 0xFF)>>

    def format(%__MODULE__{kind: :fixed, length: len}, value),
      do: pad_ascii(to_string(value), len)

    def format(%__MODULE__{kind: :varchar1}, value) do
      data = ascii(to_string(value)) |> binary_part_max(255)
      <<byte_size(data)>> <> data
    end

    def format(%__MODULE__{kind: :varchar2}, value) do
      data = ascii(to_string(value)) |> binary_part_max(65_535)
      <<byte_size(data)::16-big>> <> data
    end

    def format(%__MODULE__{kind: :integer}, value),
      do: <<trunc_int(value)::16-big>>

    def format(%__MODULE__{kind: :decimal}, value) do
      # 28 chars: sign + 13 int digits + "." + 13 frac digits,
      # zero-padded on the left and space-padded to width.
      s = :erlang.float_to_binary(value * 1.0, decimals: 13)
      s = if String.starts_with?(s, "-"), do: s, else: "+" <> s
      s |> String.pad_leading(28, "0") |> binary_part_max(28) |> pad_ascii(28)
    end

    # Truncate to `len` ASCII bytes, right-pad with spaces to `len`.
    defp pad_ascii(str, len) do
      ascii(str) |> binary_part_max(len) |> String.pad_trailing(len)
    end

    defp ascii(str) do
      # The format is ASCII-only; replace non-ASCII bytes with '?' so a
      # stray accented name in a profile can't crash the nightly run.
      for <<b <- str>>, into: <<>>, do: <<if(b < 128, do: b, else: ??)>>
    end

    defp binary_part_max(bin, max) when byte_size(bin) <= max, do: bin
    defp binary_part_max(bin, max), do: binary_part(bin, 0, max)

    defp trunc_int(v) when is_integer(v), do: rem(v, 65_536)
    defp trunc_int(v), do: trunc_int(trunc(v))
  end

  # Convenience constructors.
  def fixed(name, length), do: %Field{name: name, kind: :fixed, length: length}
  def varchar1(name), do: %Field{name: name, kind: :varchar1}
  def varchar2(name), do: %Field{name: name, kind: :varchar2}
  def integer(name), do: %Field{name: name, kind: :integer}
  def decimal(name), do: %Field{name: name, kind: :decimal}

  # --- Search keys ---------------------------------------------------

  defmodule SearchKey do
    @moduledoc """
    An index definition. `fields` is an ordered list of
    `{field_name, type_byte}` - the records are sorted/keyed by
    concatenating those fields in order; `type_byte` is written verbatim
    into the DAD key descriptor (always `1` in the apps we generate).
    """
    @enforce_keys [:key_id, :name, :fields]
    defstruct [:key_id, :name, :fields]

    @type t :: %__MODULE__{
            key_id: non_neg_integer(),
            name: String.t(),
            fields: [{String.t(), non_neg_integer()}]
          }

    # DAD key blob: key_id, 0x00 reserved, n_fields, then per field:
    # field_index(1-based into the schema), type_byte.
    @spec encode(t(), %{String.t() => pos_integer()}) :: binary()
    def encode(%__MODULE__{key_id: id, fields: fields}, field_index) do
      body =
        for {fname, ftype} <- fields, into: <<>> do
          idx = Map.get(field_index, fname) || raise(KeyError, key: fname, term: field_index)
          <<idx, ftype>>
        end

      <<id, 0, length(fields)>> <> body
    end
  end

  # --- Schema --------------------------------------------------------

  defmodule Schema do
    @moduledoc "A CCDAM database: handle, type/driver, fields, search keys."
    @enforce_keys [:db_handle, :fields, :search_keys]
    defstruct db_handle: nil,
              db_type: 0,
              db_driver: 1,
              fields: [],
              search_keys: [],
              object_prefix: nil

    @type t :: %__MODULE__{
            db_handle: String.t(),
            db_type: 0 | 1,
            db_driver: 1,
            fields: [Prodigy.Core.Objects.Ccdam.Field.t()],
            search_keys: [Prodigy.Core.Objects.Ccdam.SearchKey.t()],
            object_prefix: String.t() | nil
          }

    @doc "Object-name prefix for index/leaf objects (defaults to the handle)."
    def prefix(%__MODULE__{object_prefix: p, db_handle: h}), do: p || h

    @doc "Total IDO-reference width = 8 - len(handle) (page digits + 1 tier digit)."
    def num_width(%__MODULE__{db_handle: h}), do: 8 - byte_size(h)

    @doc "Width of the page-number portion of an IDO ref (excludes the tier digit)."
    def page_num_width(%__MODULE__{} = s), do: num_width(s) - 1

    @doc "Map from field name to its 1-based index in `fields`."
    def field_index(%__MODULE__{fields: fields}) do
      fields |> Enum.with_index(1) |> Map.new(fn {f, i} -> {f.name, i} end)
    end

    @doc "Map from field name to its `Field` struct."
    def field_by_name(%__MODULE__{fields: fields}), do: Map.new(fields, &{&1.name, &1})

    @doc "Validate consistency; raises ArgumentError on problems."
    def validate!(%__MODULE__{} = s) do
      names = MapSet.new(s.fields, & &1.name)
      errors = []

      errors =
        Enum.reduce(s.search_keys, errors, fn k, acc ->
          Enum.reduce(k.fields, acc, fn {fname, _}, acc2 ->
            if MapSet.member?(names, fname),
              do: acc2,
              else: ["search key #{k.key_id} references unknown field #{inspect(fname)}" | acc2]
          end)
        end)

      key_ids = Enum.map(s.search_keys, & &1.key_id)
      errors = if key_ids == Enum.uniq(key_ids), do: errors, else: ["duplicate search key ids" | errors]
      errors = if length(s.fields) <= 25, do: errors, else: ["#{length(s.fields)} fields exceeds the CCDAM limit of 25" | errors]
      errors = if byte_size(s.db_handle) <= 6, do: errors, else: ["db_handle #{inspect(s.db_handle)} too long (max 6)" | errors]
      errors = if s.db_type in [0, 1], do: errors, else: ["unsupported db_type #{inspect(s.db_type)} (only 0 and 1 are ported)" | errors]
      errors = if s.db_driver == 1, do: errors, else: ["unsupported db_driver #{inspect(s.db_driver)} (only 1 is ported)" | errors]

      case errors do
        [] -> s
        _ -> raise ArgumentError, "CCDAM schema invalid:\n  - " <> Enum.join(Enum.reverse(errors), "\n  - ")
      end
    end
  end

  # --- DAD (Database Access Descriptor) ------------------------------

  @doc """
  Encode the DAD payload for `schema`. For `db_type` 1, `segments` is a
  list of field lists (one per segment); when omitted it defaults to a
  single segment containing all of `schema.fields`.
  """
  @spec encode_dad(Schema.t(), non_neg_integer(), keyword()) :: binary()
  def encode_dad(%Schema{} = schema, total_records, opts \\ []) do
    Schema.validate!(schema)
    fi = Schema.field_index(schema)
    header = <<schema.db_type, schema.db_driver, total_records::32-big>>

    field_block =
      case schema.db_type do
        0 ->
          <<length(schema.fields)>> <>
            (schema.fields |> Enum.map(&Field.descriptor/1) |> IO.iodata_to_binary())

        1 ->
          segments = Keyword.get(opts, :segments, [schema.fields])

          <<length(segments)>> <>
            (for seg <- segments, into: <<>> do
               <<length(seg)>> <> (seg |> Enum.map(&Field.descriptor/1) |> IO.iodata_to_binary())
             end)
      end

    key_block =
      <<length(schema.search_keys)>> <>
        (for k <- schema.search_keys, into: <<>> do
           blob = SearchKey.encode(k, fi)
           <<byte_size(blob)>> <> blob
         end)

    header <> field_block <> key_block
  end

  @doc """
  Build the DAD object blob - `<db_handle>000000` with extension `D`,
  sequence/set_size 1. Pass `:version` (default 1) and, for `db_type` 1,
  optional `:segments`. Returns the encoded Prodigy object.
  """
  @spec dad_object(Schema.t(), non_neg_integer(), keyword()) :: binary()
  def dad_object(%Schema{} = schema, total_records, opts \\ []) do
    Codec.build(%{
      name: dad_name(schema),
      ext: "D",
      sequence: 1,
      set_size: 1,
      version: Keyword.get(opts, :version, 1),
      data: encode_dad(schema, total_records, opts)
    })
  end

  defp dad_name(%Schema{} = schema), do: schema.db_handle <> String.duplicate("0", 8 - byte_size(schema.db_handle))

  # --- Index builder -------------------------------------------------

  @doc """
  Build the B-tree for one search key and emit its objects (sequence
  set, intermediate index pages, leaf IDOs). Each object blob is passed
  to the `:write` callback (default: collect and return as a list).

  Options:

    * `:write` - `fn blob -> any end`. Default collects into a list,
      which `build_index/4` then returns.
    * `:records_per_ido` - max records per leaf IDO. Default 12.
    * `:keys_per_index_page` - max keys per intermediate page; `0`
      (default) = flat tree (sequence set -> leaves only).
    * `:version` - object version. Default 1.
    * `:extra_data` - `fn record -> binary end`; appended verbatim after
      each leaf record's (compressed) key. Default `fn _ -> "" end`. For
      `db_type` 1 this is the `0x00` pages-byte + 7-byte TDO reference.
    * `:header`, `:trailer` - records prepended/appended before sorting.

  Returns `:ok` if a `:write` fn was given, else the list of blobs.
  """
  @spec build_index(Schema.t(), non_neg_integer(), [map()], keyword()) :: :ok | [binary()]
  def build_index(%Schema{} = schema, search_key_id, records, opts \\ []) when is_list(records) do
    Schema.validate!(schema)
    search_key = Enum.find(schema.search_keys, &(&1.key_id == search_key_id)) ||
                   raise ArgumentError, "no search key #{inspect(search_key_id)} in schema"

    write = Keyword.get(opts, :write)

    fields_in_key =
      Enum.map(search_key.fields, fn {fname, _} -> Map.fetch!(Schema.field_by_name(schema), fname) end)

    key_of = fn record -> for f <- fields_in_key, into: <<>>, do: Field.format(f, Map.get(record, f.name, "")) end
    extra_of = Keyword.get(opts, :extra_data, fn _ -> "" end)

    records_per_ido = Keyword.get(opts, :records_per_ido, 12)
    keys_per_index_page = Keyword.get(opts, :keys_per_index_page, 0)
    version = Keyword.get(opts, :version, 1)

    sorted =
      (List.wrap(Keyword.get(opts, :header)) ++
         Enum.sort_by(records, key_of) ++
         List.wrap(Keyword.get(opts, :trailer)))

    prefix = Schema.prefix(schema)
    page_w = Schema.page_num_width(schema)
    full_w = Schema.num_width(schema)
    null_ref = String.duplicate("0", full_w)

    # 0 records -> 0 leaf IDOs and an entry-less sequence set. Forcing a
    # phantom leaf here (we previously had `max(1, ...)`) leaves the
    # sequence set with a zero-length-key
    # entry pointing at an empty IDO, which the RS picker misreads as
    # a state code and indexes into MSPLSTAT - displays garbage.
    num_leaf = ceil_div(length(sorted), records_per_ido)

    leaf_tier =
      if keys_per_index_page > 0 and num_leaf > keys_per_index_page do
        depth_loop(num_leaf, keys_per_index_page, 2)
      else
        2
      end

    record_size =
      case schema.db_type do
        0 -> 2
        1 -> 7
      end

    emitted = []

    # --- leaf IDOs (deepest tier) ---
    {leaf_keys, emitted} =
      if num_leaf == 0 do
        {[], emitted}
      else
        Enum.reduce(1..num_leaf, {[], emitted}, fn leaf_num, {keys_acc, em} ->
          slice = slice_records(sorted, leaf_num, records_per_ido)
          ido_bytes = build_ido(slice, key_of, extra_of, true, schema.db_driver, full_w, leaf_num, num_leaf, leaf_tier, page_w, prefix)

          boundary = key_of.(List.last(slice))

          name = prefix <> base36_pad(leaf_num, page_w) <> Integer.to_string(leaf_tier)
          blob = Codec.build(%{name: name, ext: "S", sequence: search_key_id, set_size: 1, version: version, data: ido_bytes})
          {[{boundary, leaf_num} | keys_acc], [blob | em]}
        end)
        |> then(fn {acc, em} -> {Enum.reverse(acc), em} end)
      end

    # --- intermediate tiers, bottom-up ---
    {seq_children, seq_child_tier, emitted} =
      build_intermediate_tiers(leaf_keys, leaf_tier, leaf_tier, keys_per_index_page, prefix, page_w, search_key_id, version, emitted)

    # --- sequence set (tier 1) ---
    {first_ref, last_ref} =
      case seq_children do
        [] -> {null_ref, null_ref}
        _ ->
          {_k, first_num} = List.first(seq_children)
          {_k2, last_num} = List.last(seq_children)
          {base36_pad(first_num, page_w) <> Integer.to_string(seq_child_tier),
           base36_pad(last_num, page_w) <> Integer.to_string(seq_child_tier)}
      end

    ss_bytes =
      encode_sequence_set(
        length(sorted),
        record_size,
        Enum.map(seq_children, fn {k, _} -> k end),
        first_ref,
        last_ref
      )

    ss_name = prefix <> String.duplicate("0", full_w - 2) <> "11"
    ss_blob = Codec.build(%{name: ss_name, ext: "S", sequence: search_key_id, set_size: 1, version: version, data: ss_bytes})
    emitted = [ss_blob | emitted]

    blobs = Enum.reverse(emitted)

    if write do
      Enum.each(blobs, write)
      :ok
    else
      blobs
    end
  end

  @doc """
  Build all of `schema`'s search keys. `records_per_ido` and
  `keys_per_index_page` may be a single value (applied to every key) or
  a map of `key_id => value`. All other options match `build_index/4`.
  """
  @spec build_all_indexes(Schema.t(), [map()], keyword()) :: :ok | [binary()]
  def build_all_indexes(%Schema{} = schema, records, opts \\ []) do
    rpi = Keyword.get(opts, :records_per_ido, 12)
    kpi = Keyword.get(opts, :keys_per_index_page, 0)
    write = Keyword.get(opts, :write)

    result =
      for key <- schema.search_keys do
        key_opts =
          opts
          |> Keyword.put(:records_per_ido, per_key(rpi, key.key_id))
          |> Keyword.put(:keys_per_index_page, per_key(kpi, key.key_id))

        build_index(schema, key.key_id, records, key_opts)
      end

    if write, do: :ok, else: List.flatten(result)
  end

  defp per_key(v, _key_id) when is_integer(v), do: v
  defp per_key(map, key_id) when is_map(map), do: Map.get(map, key_id, 12)

  # --- sequence set / intermediate page / IDO encoders ---------------

  # Sequence set (tier 1), db_driver=1, db_type 0/1:
  #   19, 0, 0, 0           (4-byte fixed header; 19 = data-start offset)
  #   total_records::16-big (capped at 65535)
  #   first_ido (num_width ASCII), last_ido (num_width ASCII)
  #   record_size              (byte at offset 18; reached when num_width=6)
  #   [len(1), key]...
  defp encode_sequence_set(total_records, record_size, keys, first_ido, last_ido) do
    <<19, 0, 0, 0, min(total_records, 65_535)::16-big>> <>
      first_ido <> last_ido <> <<record_size>> <> length_prefixed(keys)
  end

  # Intermediate (non-leaf) index page:
  #   7, 0, 0, 0  starting_child::16-big  0  [len(1), key]...
  defp encode_intermediate_page(starting_child_id, keys) do
    <<7, 0, 0, 0, starting_child_id::16-big, 0>> <> length_prefixed(keys)
  end

  defp length_prefixed(items) do
    for item <- items, into: <<>>, do: <<byte_size(item)>> <> item
  end

  # One leaf IDO. `slice` = the records this leaf holds (already sorted).
  defp build_ido(slice, key_of, extra_of, is_leaf?, db_driver, full_w, leaf_num, num_leaf, leaf_tier, page_w, _prefix) do
    null_ref = String.duplicate("0", full_w)
    tier_digit = Integer.to_string(leaf_tier)
    prev_ref = if leaf_num > 1, do: base36_pad(leaf_num - 1, page_w) <> tier_digit, else: null_ref
    next_ref = if leaf_num < num_leaf, do: base36_pad(leaf_num + 1, page_w) <> tier_digit, else: null_ref

    {compressed, _last_key} =
      Enum.reduce(slice, {<<>>, nil}, fn record, {acc, prev_key} ->
        key = key_of.(record)
        extra = extra_of.(record)
        {acc <> encode_ido_record(prev_key, key, extra, db_driver), key}
      end)

    type_flag = if is_leaf?, do: 0x02, else: 0x00
    <<0x10, type_flag, length(slice)::16-big>> <> prev_ref <> next_ref <> compressed <> <<0x02>>
  end

  # One record inside an IDO (db_driver=1): 3-byte header
  # [entry_size, prefix_len, new_data_len] + new_data + extra_data.
  # First record (prev_key == nil) is never prefix-compressed.
  defp encode_ido_record(nil, key, extra, _db_driver) do
    new_len = byte_size(key)
    entry_size = 3 + new_len + byte_size(extra)
    <<entry_size, 0, new_len>> <> key <> extra
  end

  defp encode_ido_record(prev_key, key, extra, _db_driver) do
    {prefix_len, new_data} = prefix_compress(prev_key, key)
    new_len = byte_size(new_data)
    entry_size = 3 + new_len + byte_size(extra)
    <<entry_size, prefix_len, new_len>> <> new_data <> extra
  end

  # Common-prefix compression: only worth it if the shared prefix is
  # longer than the 3-byte header it costs.
  defp prefix_compress(prev, cur) do
    n = common_prefix_len(prev, cur, 0)
    if n > 3, do: {n, binary_part(cur, n, byte_size(cur) - n)}, else: {0, cur}
  end

  defp common_prefix_len(<<b, ra::binary>>, <<b, rb::binary>>, acc), do: common_prefix_len(ra, rb, acc + 1)
  defp common_prefix_len(_, _, acc), do: acc

  # Walk the leaf-key list into intermediate tiers, bottom-up. Returns
  # `{children_for_seq_set, child_tier, emitted_blobs}`. The reduce range
  # `(leaf_tier-1)..2//-1` is naturally empty for a flat tree
  # (leaf_tier=2), so kpi<=0 / flat layouts pass through unchanged.
  defp build_intermediate_tiers(child_keys, child_tier, leaf_tier, kpi, prefix, page_w, key_id, version, emitted) do
    if kpi <= 0 do
      {child_keys, child_tier, emitted}
    else
      Enum.reduce((leaf_tier - 1)..2//-1, {child_keys, child_tier, emitted}, fn tier,
                                                                                {kids, _kid_tier, em} ->
        tier_digit = Integer.to_string(tier)
        pages = Enum.chunk_every(kids, kpi)

        {parent_keys, em2, _next_page} =
          Enum.reduce(pages, {[], em, 1}, fn page_entries, {pacc, emm, page_num} ->
            {_first_key, first_child_num} = List.first(page_entries)
            starting_child_id = first_child_num - 1
            keys_only = Enum.map(page_entries, fn {k, _} -> k end)
            page_data = encode_intermediate_page(starting_child_id, keys_only)
            {boundary_key, _} = List.last(page_entries)
            name = prefix <> base36_pad(page_num, page_w) <> tier_digit

            blob =
              Codec.build(%{
                name: name,
                ext: "S",
                sequence: key_id,
                set_size: 1,
                version: version,
                data: page_data
              })

            {[{boundary_key, page_num} | pacc], [blob | emm], page_num + 1}
          end)

        {Enum.reverse(parent_keys), tier, em2}
      end)
    end
  end

  # --- numeric helpers -----------------------------------------------

  defp ceil_div(_a, 0), do: 0
  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp depth_loop(n, kpi, depth) when n > kpi, do: depth_loop(ceil_div(n, kpi), kpi, depth + 1)
  defp depth_loop(_n, _kpi, depth), do: depth

  defp slice_records(records, leaf_num, per) do
    records |> Enum.drop((leaf_num - 1) * per) |> Enum.take(per)
  end

  @base36 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

  @doc false
  def base36(0), do: "0"
  def base36(n) when is_integer(n) and n > 0, do: base36(n, [])
  defp base36(0, acc), do: List.to_string(acc)
  defp base36(n, acc), do: base36(div(n, 36), [Enum.at(@base36, rem(n, 36)) | acc])

  defp base36_pad(n, width), do: base36(n) |> String.pad_leading(width, "0")
end
