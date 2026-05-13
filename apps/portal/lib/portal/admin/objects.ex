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

defmodule Prodigy.Portal.Admin.Objects do
  @moduledoc """
  Queries + actions the admin "Objects" tab calls into. The write
  pipeline (content-compare / auto-bump / keyword indexing /
  broadcast) lives in `Prodigy.Core.Objects.Store` so `podbutil` and
  seed-time imports run through the same flow; this module owns the
  portal-specific concerns:

  * `list/0` - LEFT JOIN on `keyword` so each row carries its keyword.
  * `type_label/1`, `known_types/0` - UI labels.
  * `parse_import_blob/1`, `insert_many/1`, `get_blob/4`, `delete/4`
    delegate to `Store`.
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Keyword, Object}
  alias Prodigy.Core.Objects.Store

  @doc "Topic admin LVs subscribe to for live object lifecycle events."
  defdelegate topic, to: Store

  @doc """
  All object rows with `(contents octet_length)` as `:size` and the
  keyword LEFT-JOINed from the `keyword` table on
  `(name, sequence, type)`. Ordered by name asc, seq asc, type asc,
  version desc.
  """
  def list do
    from(o in Object,
      left_join: k in Keyword,
      on:
        k.object_name == o.name and
          k.object_sequence == o.sequence and
          k.object_type == o.type,
      select: %{
        name: o.name,
        sequence: o.sequence,
        type: o.type,
        version: o.version,
        size: fragment("octet_length(?)", o.contents),
        keyword: k.keyword
      },
      order_by: [asc: o.name, asc: o.sequence, asc: o.type, desc: o.version]
    )
    |> Repo.all()
  end

  @doc "Human label for each known object type byte."
  def type_label(0x0), do: "Page Format"
  def type_label(0x4), do: "Page Template"
  def type_label(0x8), do: "Page Element"
  def type_label(0xC), do: "Program"
  def type_label(0xE), do: "Window"
  def type_label(n) when is_integer(n), do: "0x" <> Integer.to_string(n, 16)

  @doc "All known object type codes, in the order the admin filter lists them."
  def known_types, do: [0x0, 0x4, 0x8, 0xC, 0xE]

  # --- delegations ---------------------------------------------------

  defdelegate parse_import_blob(blob), to: Store

  @doc """
  Admin-facing alias for `Store.insert_or_bump/1`. Same return shape:
  `{:ok, %{inserted, bumped, unchanged}}` or `{:error, reason}`.
  """
  defdelegate insert_many(parsed), to: Store, as: :insert_or_bump

  defdelegate get_blob(name, sequence, type, version), to: Store
  defdelegate delete(name, sequence, type, version), to: Store
  defdelegate delete_many(pks), to: Store
end
