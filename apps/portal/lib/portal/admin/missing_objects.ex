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

defmodule Prodigy.Portal.Admin.MissingObjects do
  @moduledoc """
  Read context for the Deficits tab on /admin/service/objects.
  Surfaces the `missing_objects` roster maintained by
  `Prodigy.Server.Service.Tocs.record_deficit/4`.

  Default sort: hit_count desc (worst offenders first), then
  last_seen desc as a tiebreaker. Filter knob: name substring,
  matched as a case-insensitive contains against
  `missing_objects.name`.
  """
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.MissingObject

  @doc """
  List rows. `opts`:
    * `:name_filter` - case-insensitive substring on the name column.
    * `:limit` - defaults to 500 (the table is bounded by the number
      of unique missing identities, expected to be small).
  """
  def list(opts \\ []) do
    name_filter = Keyword.get(opts, :name_filter, "")
    limit = Keyword.get(opts, :limit, 500)

    query =
      from m in MissingObject,
        order_by: [desc: m.hit_count, desc: m.last_seen],
        limit: ^limit

    query =
      case String.trim(to_string(name_filter)) do
        "" -> query
        needle -> from m in query, where: ilike(m.name, ^"%#{needle}%")
      end

    Repo.all(query)
  end

  @doc """
  Total deficit row count across all sources - useful for the tab
  badge ("Deficits (12)") so operators see at-a-glance whether
  there's anything to review.
  """
  def count do
    Repo.aggregate(MissingObject, :count, :name)
  end

  @doc """
  Forget about a deficit row entirely. Used when the operator has
  fixed the missing content (e.g. uploaded the missing object) and
  wants the row off the roster. Re-occurrence after delete will just
  reinsert with hit_count=1.
  """
  def delete(name, sequence, type)
      when is_binary(name) and is_integer(sequence) and is_integer(type) do
    Repo.delete_all(
      from m in MissingObject,
        where: m.name == ^name and m.sequence == ^sequence and m.type == ^type
    )

    :ok
  end
end
