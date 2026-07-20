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

defmodule Prodigy.Server.MemberList.Schema do
  @moduledoc """
  Static spec for the member-list CCDAM data set: the `3B` search
  database, the `3L` detail database, and the `MSPLSTAT.D01` state
  table. Wraps `Prodigy.Core.Objects.Ccdam` definitions for the runtime
  the reception-system Member List app expects.
  """

  alias Prodigy.Core.Objects.{Ccdam, Codec}
  alias Prodigy.Core.Objects.Ccdam.{Schema, SearchKey}

  # Tuning constants: records per IDO and keys per index page.
  @records_per_ido 20
  @keys_per_index_page 10

  # MSPLSTAT name + extension (8/3, space-padded).
  @msplstat_name "MSPLSTAT"

  # ----- 3B (search) -----

  @doc "The 3B search-database schema (db_type=0)."
  def schema_3b do
    %Schema{
      db_handle: "3B",
      db_type: 0,
      db_driver: 1,
      fields: [
        Ccdam.fixed("user_id", 7),
        Ccdam.fixed("state", 2),
        Ccdam.fixed("city", 18),
        Ccdam.fixed("unknown", 4),
        Ccdam.fixed("last_name", 20),
        Ccdam.fixed("first_name", 15),
        Ccdam.fixed("middle", 1),
        Ccdam.fixed("title", 5)
      ],
      search_keys: [
        %SearchKey{
          key_id: 1,
          name: "name_all_states",
          fields: [
            {"last_name", 1},
            {"first_name", 1},
            {"middle", 1},
            {"state", 1},
            {"title", 1},
            {"user_id", 1}
          ]
        },
        %SearchKey{
          key_id: 2,
          name: "name_city_state",
          fields: [
            {"state", 1},
            {"city", 1},
            {"last_name", 1},
            {"first_name", 1},
            {"middle", 1},
            {"title", 1},
            {"user_id", 1}
          ]
        },
        %SearchKey{key_id: 3, name: "states", fields: [{"state", 1}]},
        %SearchKey{
          key_id: 4,
          name: "cities_in_state",
          fields: [{"state", 1}, {"city", 1}]
        }
      ]
    }
  end

  # ----- 3L (detail) -----

  @doc """
  The 3L detail-database schema (db_type=1). 10 DAD fields land in
  `RDA15..RDA24` when op-12 fetches the per-member Y-object TDO; the
  IDO records key only on `user_id(7)` plus an 8-byte non-compressed
  extra (pages byte + 7-byte TDO ref).
  """
  def schema_3l do
    %Schema{
      db_handle: "3L",
      db_type: 1,
      db_driver: 1,
      fields: [
        Ccdam.fixed("user_id", 7),
        Ccdam.fixed("state", 2),
        Ccdam.fixed("city", 18),
        Ccdam.fixed("unknown1", 0),
        Ccdam.fixed("last_name", 20),
        Ccdam.fixed("first_name", 15),
        Ccdam.fixed("middle", 1),
        Ccdam.fixed("title", 5),
        Ccdam.fixed("unknown2", 0),
        Ccdam.fixed("unknown3", 0)
      ],
      search_keys: [%SearchKey{key_id: 1, name: "by_user_id", fields: [{"user_id", 1}]}]
    }
  end

  @doc """
  Build the `3L<NNNNNN>.Y01` per-member Y-object (TDO page 1). Body is
  `<<3, 0, 1>>` (3-byte header: data_offset=3, unused=0, total_pages=1)
  followed by the 10 fields formatted at their DAD widths.

  `ref6` is the 6-digit numeric portion of the TDO reference - the
  Y-object name will be `3L<ref6>` and the IDO points at it via
  `<<0>> + ref6 + "Y"` as record extra-data.
  """
  @spec build_y_object(map(), String.t(), keyword()) :: binary()
  def build_y_object(member, ref6, opts \\ []) when is_binary(ref6) and byte_size(ref6) == 6 do
    fields_in_order =
      schema_3l().fields
      |> Enum.map(&Ccdam.Field.format(&1, Map.get(member, &1.name, "")))
      |> IO.iodata_to_binary()

    body = <<3, 0, 1>> <> fields_in_order

    Codec.build(%{
      name: "3L" <> ref6,
      ext: "Y",
      sequence: 1,
      set_size: 1,
      version: Keyword.get(opts, :version, 1),
      data: body
    })
  end

  @doc """
  The 7-byte TDO reference string for a given 1-based index. Returns
  `"<NNNNNN>Y"` (e.g. `"000001Y"`).
  """
  @spec tdo_ref(non_neg_integer()) :: String.t()
  def tdo_ref(i) when is_integer(i) and i > 0 do
    String.pad_leading(Integer.to_string(i), 6, "0") <> "Y"
  end

  @doc """
  3L IDO extra-data builder: the 7-byte TDO ref preceded by the
  `0x00` pages byte. Hand this to `Ccdam.build_index/4` via
  `:extra_data`.
  """
  def y_object_extra_data(member) do
    <<0>> <> Map.fetch!(member, "_tdo_ref")
  end

  # ----- MSPLSTAT.D01 -----

  @doc """
  The state code -> full name table. Per entry: `<code(2)> '/' <len(name)+3 (1)> <name(N)>`
  - the length byte counts code + '/' + name.
  """
  def msplstat_object(opts \\ []) do
    data =
      for {code, name} <- states(), into: <<>> do
        <<code::binary, ?/, byte_size(name) + 3, name::binary>>
      end

    Codec.build(%{
      name: @msplstat_name,
      ext: "D",
      sequence: 1,
      set_size: 1,
      version: Keyword.get(opts, :version, 1),
      data: data
    })
  end

  @doc "Default `records_per_ido` for the name keys (1 and 2)."
  def records_per_ido, do: @records_per_ido

  @doc "Default `keys_per_index_page` for the name/city keys."
  def keys_per_index_page, do: @keys_per_index_page

  @doc "The 51 (code, name) pairs covering all US states + DC."
  def states do
    [
      {"AL", "ALABAMA"},
      {"AK", "ALASKA"},
      {"AZ", "ARIZONA"},
      {"AR", "ARKANSAS"},
      {"CA", "CALIFORNIA"},
      {"CO", "COLORADO"},
      {"CT", "CONNECTICUT"},
      {"DC", "WASHINGTON DC"},
      {"DE", "DELAWARE"},
      {"FL", "FLORIDA"},
      {"GA", "GEORGIA"},
      {"HI", "HAWAII"},
      {"ID", "IDAHO"},
      {"IL", "ILLINOIS"},
      {"IN", "INDIANA"},
      {"IA", "IOWA"},
      {"KS", "KANSAS"},
      {"KY", "KENTUCKY"},
      {"LA", "LOUISIANA"},
      {"ME", "MAINE"},
      {"MD", "MARYLAND"},
      {"MA", "MASSACHUSETTS"},
      {"MI", "MICHIGAN"},
      {"MN", "MINNESOTA"},
      {"MS", "MISSISSIPPI"},
      {"MO", "MISSOURI"},
      {"MT", "MONTANA"},
      {"NE", "NEBRASKA"},
      {"NV", "NEVADA"},
      {"NH", "NEW HAMPSHIRE"},
      {"NJ", "NEW JERSEY"},
      {"NM", "NEW MEXICO"},
      {"NY", "NEW YORK"},
      {"NC", "NORTH CAROLINA"},
      {"ND", "NORTH DAKOTA"},
      {"OH", "OHIO"},
      {"OK", "OKLAHOMA"},
      {"OR", "OREGON"},
      {"PA", "PENNSYLVANIA"},
      {"RI", "RHODE ISLAND"},
      {"SC", "SOUTH CAROLINA"},
      {"SD", "SOUTH DAKOTA"},
      {"TN", "TENNESSEE"},
      {"TX", "TEXAS"},
      {"UT", "UTAH"},
      {"VT", "VERMONT"},
      {"VA", "VIRGINIA"},
      {"WA", "WASHINGTON"},
      {"WV", "WEST VIRGINIA"},
      {"WI", "WISCONSIN"},
      {"WY", "WYOMING"}
    ]
  end
end
