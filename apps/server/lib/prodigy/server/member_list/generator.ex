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

defmodule Prodigy.Server.MemberList.Generator do
  @moduledoc """
  Nightly cron entry point: regenerates the Member List CCDAM data set
  from the live opted-in user population and atomically replaces it via
  `Prodigy.Core.Objects.Store.reconcile_prefix/2`.

  Outputs:

    * `3B000000.D01` - the 3B (search) DAD
    * `3B*.S{1..4}` - sequence set + intermediate + leaf IDOs for the
      four search keys (name_all_states, name_city_state, states,
      cities_in_state)
    * `3L000000.D01` - the 3L (detail) DAD
    * `3L*.S1` - sequence set + tier pages + leaf IDOs for the
      `by_user_id` key. Leaf records carry a 1-byte pages flag + 7-byte
      TDO reference as non-compressed extra-data.
    * `3L<NNNNNN>.Y01` - one Y-object per member; XXOPCCDG extracts the
      10 DAD fields from here at op-12 time.
    * `MSPLSTAT.D01` - the static state code -> name table.

  The whole set is candidacy 1 (`:none`), so the DOS client never
  version-checks it; we hand-pick `version: 1` by default for the same
  reason. `Store.reconcile_prefix` replaces every prior-run object in
  the `3B`/`3L`/`MSPLSTAT` namespace, so a member who removed themselves
  takes their Y-object with them and a population shrink past an
  `records_per_ido` boundary drops the now-orphaned leaf IDO.

  Hand-callable for dev/manual runs:

      iex> Prodigy.Server.MemberList.Generator.run()

  Or via the release: `bin/server rpc 'Prodigy.Server.MemberList.Generator.run()'`.
  The Quantum scheduler calls it nightly per `config/config.exs`.
  """

  require Logger

  alias Prodigy.Core.Objects.{Ccdam, Store}
  alias Prodigy.Server.MemberList.{Schema, Source}

  @prefixes ["3B", "3L", "MSPLSTAT"]

  @doc """
  Build the full Member List object set from the current opted-in user
  population and write it. Options:

    * `:version` - candidacy/version byte (default `1`).
    * `:source` - 0-arity function returning the list of normalized
      member records. Defaults to `&Source.list_eligible/0`. Tests pass
      a fixed list here so they don't need DB seeds.

  Returns `{:ok, %{members, upserted, deleted}}` on success or
  `{:error, reason}` if the reconcile transaction rolls back.
  """
  @spec run(keyword()) ::
          {:ok, %{members: non_neg_integer(), upserted: non_neg_integer(), deleted: non_neg_integer()}}
          | {:error, term()}
  def run(opts \\ []) do
    version = Keyword.get(opts, :version, 1)
    source = Keyword.get(opts, :source, &Source.list_eligible/0)

    members =
      source.()
      |> Enum.with_index(1)
      |> Enum.map(fn {m, i} -> Map.put(m, "_tdo_ref", Schema.tdo_ref(i)) end)

    blobs = build_blobs(members, version)

    case Store.reconcile_prefix(@prefixes, blobs) do
      {:ok, %{upserted: u, deleted: d}} ->
        Logger.info(
          "[member_list] #{length(members)} listed; #{u} object(s) upserted, #{d} stale dropped"
        )

        {:ok, %{members: length(members), upserted: u, deleted: d}}

      {:error, reason} = err ->
        Logger.error("[member_list] failed: #{inspect(reason)}")
        err
    end
  end

  # ---- internals ------------------------------------------------------

  # Pure: members (with `_tdo_ref` already assigned) -> list of object
  # blobs. Exposed for tests (no DB roundtrip).
  @doc false
  def build_blobs(members, version) do
    s3b = Schema.schema_3b()
    s3l = Schema.schema_3l()

    rpi = Schema.records_per_ido()
    kpi = Schema.keys_per_index_page()

    name_opts = [records_per_ido: rpi, keys_per_index_page: kpi, version: version]

    blobs_3b =
      [
        Ccdam.dad_object(s3b, length(members), version: version)
        | Ccdam.build_index(s3b, 1, members, name_opts)
      ] ++
        Ccdam.build_index(s3b, 2, members, name_opts) ++
        Ccdam.build_index(s3b, 3, distinct_states(members), records_per_ido: 100, version: version) ++
        Ccdam.build_index(s3b, 4, distinct_cities(members), name_opts)

    blobs_3l =
      [Ccdam.dad_object(s3l, length(members), version: version)] ++
        Enum.map(members, fn m -> Schema.build_y_object(m, ref6_of(m), version: version) end) ++
        Ccdam.build_index(s3l, 1, members,
          records_per_ido: rpi,
          keys_per_index_page: kpi,
          version: version,
          extra_data: &Schema.y_object_extra_data/1
        )

    blobs_3b ++ blobs_3l ++ [Schema.msplstat_object(version: version)]
  end

  # Distinct states with non-blank state (Source already filters on
  # `state != ""`, so this is just `uniq`).
  defp distinct_states(members) do
    members
    |> Enum.map(&%{"state" => &1["state"]})
    |> Enum.uniq()
    |> Enum.sort_by(& &1["state"])
  end

  # Distinct (state, city) pairs with non-blank city. A blank city
  # entry would render uselessly in the city picker.
  defp distinct_cities(members) do
    members
    |> Enum.reject(&(&1["city"] == ""))
    |> Enum.map(&%{"state" => &1["state"], "city" => &1["city"]})
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["state"], &1["city"]})
  end

  defp ref6_of(member), do: binary_part(Map.fetch!(member, "_tdo_ref"), 0, 6)
end
