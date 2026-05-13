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

defmodule Prodigy.Core.Objects.Store do
  @moduledoc """
  Transactional store operations for Prodigy binary objects.

  Lives in `:core` so both the portal admin upload pipeline and the
  `podbutil` CLI / seed-time import run objects through the same
  content-compare + keyword-indexing flow. The admin context
  (`Prodigy.Portal.Admin.Objects`) delegates its write path here; CLI
  callers use `insert_or_bump/1` directly.

  Behaviour summary:

  * Every upload is compared against the latest version for its
    `(name, sequence, type)` by `content_hash` (SHA-256 of the
    canonicalized blob - version bits zeroed, candidacy preserved).
  * If no prior row exists, the upload lands at its declared version.
  * If content matches, nothing is written and the row is returned as
    `:unchanged`.
  * If content differs, a new row is inserted at `latest.version + 1`,
    wrapping on the 13-bit ceiling (8191 -> 0). TODO: the server's wire
    protocol should recognize the wrap.
  * Inside the same transaction we maintain the `keyword` index -
    any keyword previously pointing at the object's triple is deleted
    and the new one (from the 0x71 segment) is inserted. A collision
    with a different object's keyword returns
    `{:error, {:keyword_collision, kw, owner_obj_id, new_obj_id}}`
    and rolls the whole batch back.
  * On success, broadcasts `:objects_upserted` on the
    `service:objects` topic so admin LVs refresh. Broadcasts are
    skipped when `Prodigy.Core.PubSub` isn't running (CLI without a
    supervision tree, tests with mocked PubSub, ...).

  The schema path for the row insert intentionally stays narrow so it
  can't be talked into modifying anything outside the object row; the
  keyword side is its own changeset with a unique-constraint on
  `keyword`.

  TODO:

  * Inspect candidacy value and bump `ITRC0001.D` when objects with the
    NoVersioning bit are updated.
  * Get browser storage working for the client-side experience so that
    the RS isn't downloading the distribution `STAGE.DAT` and every
    update on every connection.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Keyword, Object}
  alias Prodigy.Core.Objects.Codec

  @pubsub Prodigy.Core.PubSub
  @topic "service:objects"

  @doc "Topic admin LVs (and any other subscriber) listen on."
  def topic, do: @topic

  # parse helper

  @doc """
  Parse a blob into the attrs map `insert_or_bump/1` expects. Returns
  `{:ok, map}` on any blob whose 18-byte header decodes; body segment
  errors degrade gracefully to `keyword: nil` rather than rejecting
  the upload.
  """
  @spec parse_import_blob(binary()) :: {:ok, map()} | {:error, atom()}
  def parse_import_blob(blob) when is_binary(blob) do
    case Codec.parse_header(blob) do
      {:ok, h} ->
        {:ok,
         %{
           name: h.name,
           sequence: h.sequence,
           type: h.type,
           version: h.version,
           contents: blob,
           content_hash: Codec.content_hash(blob),
           keyword: try_extract_keyword(blob)
         }}

      {:error, _} = err ->
        err
    end
  end

  def parse_import_blob(_), do: {:error, :too_short}

  defp try_extract_keyword(blob) do
    case Codec.parse(blob) do
      {:ok, parsed} ->
        case Codec.extract_keyword(parsed) do
          {:ok, kw} -> kw
          :none -> nil
        end

      {:error, _} ->
        nil
    end
  end

  # insert_or_bump

  @doc """
  Commit a batch of parsed uploads.

  Options:

    * `:on_keyword_collision` - what to do when an upload claims a
      keyword another object already owns. Defaults to `:error`
      (returns `{:error, {:keyword_collision, ...}}` and rolls the
      whole batch back). Pass `:skip` to leave the existing claim
      alone, insert the object without a keyword row, and surface the
      collision in `result.skipped_keywords`. `:skip` is what the
      podbutil / seed import uses so bulk bootstrap against
      canonically-inconsistent data doesn't halt on the first
      duplicate.

  Returns:

    * `{:ok, %{inserted: [...], bumped: [...], unchanged: [...],
       skipped_keywords: [...], keywords_changed?: boolean()}}`
    * `{:error, {:keyword_collision, keyword, owner_id, new_id}}`
      (only when `on_keyword_collision: :error`)
    * `{:error, {:object_insert_failed, name, changeset_errors}}`
    * `{:error, reason}` - any other transactional failure.

  Each disposition list entry is `%{name, sequence, type, version,
  keyword}`; bumped rows additionally carry `:previous_version`.
  Skipped-keyword entries are
  `%{keyword, owner_obj_id, new_obj_id}`.

  `keywords_changed?` is `true` iff at least one row in the batch
  added, removed, or moved a keyword - measured by comparing the
  pre-existing keyword text for each object's `(name, sequence,
  type)` against the new keyword extracted from its blob. Callers
  use this to decide whether a downstream keyword-index rebuild is
  warranted.
  """
  @spec insert_or_bump([map()], keyword()) ::
          {:ok,
           %{
             inserted: [map()],
             bumped: [map()],
             unchanged: [map()],
             skipped_keywords: [map()],
             keywords_changed?: boolean()
           }}
          | {:error, term()}
  def insert_or_bump(parsed, opts \\ [])
  def insert_or_bump([], _opts), do: {:ok, Map.put(empty_result(), :keywords_changed?, false)}

  def insert_or_bump(parsed, opts) when is_list(parsed) do
    mode = Elixir.Keyword.get(opts, :on_keyword_collision, :error)

    # DBConnection's default 15 s cap trips on batches over ~20k rows
    # because each row does a SELECT + INSERT serially. Callers that
    # know their batch size (the HTTP upload controller) override
    # this; local CLI imports default to 15 s.
    txn_opts = [timeout: Elixir.Keyword.get(opts, :timeout, 15_000)]

    case Repo.transaction(fn -> do_insert_or_bump(parsed, mode) end, txn_opts) do
      {:ok, %{} = result} ->
        broadcast(:objects_upserted)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_insert_or_bump(parsed, mode) do
    Enum.reduce_while(parsed, empty_accumulator(), fn attrs, acc ->
      case apply_one(attrs, mode) do
        {:ok, {disposition, row_summary, collisions, kw_changed?}} ->
          {:cont,
           acc
           |> Map.update!(disposition, &[row_summary | &1])
           |> Map.update!(:skipped_keywords, &(collisions ++ &1))
           |> Map.update!(:keywords_changed?, &(&1 or kw_changed?))}

        {:error, reason} ->
          Repo.rollback(reason)
          {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      %{} = result ->
        %{
          inserted: Enum.reverse(result.inserted),
          bumped: Enum.reverse(result.bumped),
          unchanged: Enum.reverse(result.unchanged),
          skipped_keywords: Enum.reverse(result.skipped_keywords),
          keywords_changed?: result.keywords_changed?
        }

      other ->
        other
    end)
  end

  defp empty_result,
    do: %{inserted: [], bumped: [], unchanged: [], skipped_keywords: []}

  defp empty_accumulator,
    do: Map.put(empty_result(), :keywords_changed?, false)

  defp apply_one(%{name: n, sequence: s, type: t} = attrs, mode) do
    case latest_version_row(n, s, t) do
      nil ->
        insert_with_keyword(attrs, mode, :inserted)

      %{content_hash: existing_hash, version: v} when existing_hash == attrs.content_hash ->
        # Content-identical repeat: no DB writes on either the object
        # side or the keyword side, so keywords definitionally haven't
        # changed.
        {:ok, {:unchanged, row_summary(%{attrs | version: v}, attrs.keyword), [], false}}

      %{version: v} ->
        %{attrs | version: wrap_version(v + 1)}
        |> insert_with_keyword(mode, :bumped, previous_version: v)
    end
  end

  # Insert the object row, then attempt to claim its keyword. On a
  # collision with another object's existing keyword the mode decides
  # the behavior: :error halts the whole batch; :skip leaves the
  # existing claim alone and records the attempt in the result's
  # skipped_keywords list. The object row itself always lands.
  defp insert_with_keyword(attrs, mode, disposition, summary_extras \\ []) do
    with {:ok, obj} <- insert_object(attrs) do
      case set_keyword(obj, attrs.keyword, mode) do
        {:ok, :set, kw_changed?} ->
          {:ok,
           {disposition, row_summary(obj, attrs.keyword) |> Map.merge(Map.new(summary_extras)),
            [], kw_changed?}}

        {:ok, :skipped, collision, kw_changed?} ->
          # Row recorded with keyword: nil - the caller knows the
          # object landed but the keyword claim was refused.
          {:ok,
           {disposition, row_summary(obj, nil) |> Map.merge(Map.new(summary_extras)),
            [collision], kw_changed?}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp insert_object(attrs) do
    %Object{}
    |> cast(attrs, [:name, :sequence, :type, :version, :contents, :content_hash])
    |> validate_required([:name, :sequence, :type, :version, :contents, :content_hash])
    |> unique_constraint([:name, :sequence, :type, :version], name: :object_pkey)
    |> Repo.insert()
    |> case do
      {:ok, obj} ->
        {:ok, obj}

      {:error, changeset} ->
        {:error, {:object_insert_failed, attrs.name, changeset_errors(changeset)}}
    end
  end

  defp set_keyword(obj, nil, _mode) do
    old = take_old_keyword_for(obj)
    # Dropping to no keyword is a change iff there was one before.
    {:ok, :set, old != nil}
  end

  defp set_keyword(%Object{} = obj, keyword, mode) when is_binary(keyword) do
    old = take_old_keyword_for(obj)
    kw_unchanged? = old == keyword

    # Pre-check the keyword table before we try to insert, because a
    # Postgres unique-constraint violation inside the surrounding
    # Repo.transaction puts the whole txn into an aborted state, which
    # means we can't follow up with a SELECT to resolve the owner for
    # a friendly error message. take_old_keyword_for/1 already removed
    # any row pointing at THIS object, so any row we find here must
    # belong to someone else.
    case Repo.get(Keyword, keyword) do
      nil ->
        case do_insert_keyword(keyword, obj) do
          {:ok, _} -> {:ok, :set, not kw_unchanged?}
          {:error, _} = err -> err
        end

      existing ->
        collision = %{
          keyword: keyword,
          owner_obj_id:
            format_obj_id(existing.object_name, existing.object_sequence, existing.object_type),
          new_obj_id: format_obj_id(obj.name, obj.sequence, obj.type)
        }

        case mode do
          :error ->
            {:error,
             {:keyword_collision, keyword, collision.owner_obj_id, collision.new_obj_id}}

          :skip ->
            # Object lost its keyword to a squatter. Effectively moves
            # from `old` (if any) -> nil; that's a change iff old was
            # non-nil.
            {:ok, :skipped, collision, old != nil}
        end
    end
  end

  # Delete any existing keyword rows pointing at THIS object and
  # return the single keyword text that was there (or `nil`). The
  # `keyword` table has a one-keyword-per-object invariant enforced
  # upstream, so at most one row is deleted; we pull it before the
  # DELETE via RETURNING so callers can compare old vs new.
  defp take_old_keyword_for(%Object{name: n, sequence: s, type: t}) do
    {_count, rows} =
      from(k in Keyword,
        where: k.object_name == ^n and k.object_sequence == ^s and k.object_type == ^t,
        select: k.keyword
      )
      |> Repo.delete_all()

    List.first(rows || [])
  end

  defp do_insert_keyword(keyword, %Object{} = obj) do
    %Keyword{}
    |> Keyword.changeset(%{
      keyword: keyword,
      object_name: obj.name,
      object_sequence: obj.sequence,
      object_type: obj.type
    })
    |> Repo.insert()
  end

  defp format_obj_id(name, sequence, type),
    do: "#{String.trim(name)}##{sequence}/0x#{Integer.to_string(type, 16)}"

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end

  defp wrap_version(n) when n <= 0x1FFF, do: n
  defp wrap_version(_), do: 0

  defp latest_version_row(name, sequence, type) do
    from(o in Object,
      where: o.name == ^name and o.sequence == ^sequence and o.type == ^type,
      order_by: [desc: o.version],
      limit: 1,
      select: %{version: o.version, content_hash: o.content_hash}
    )
    |> Repo.one()
  end

  defp row_summary(%Object{} = obj, keyword) do
    %{
      name: obj.name,
      sequence: obj.sequence,
      type: obj.type,
      version: obj.version,
      keyword: keyword
    }
  end

  defp row_summary(%{} = attrs, keyword) do
    %{
      name: attrs.name,
      sequence: attrs.sequence,
      type: attrs.type,
      version: attrs.version,
      keyword: keyword
    }
  end

  # read helpers

  @doc """
  Fetch the full `%Object{}` row by composite PK, including the raw
  `contents` blob. Used by the admin download controller and by any
  tooling that needs to stream the bytes back out.
  """
  def get_blob(name, sequence, type, version)
      when is_binary(name) and is_integer(sequence) and is_integer(type) and
             is_integer(version) do
    Repo.get_by(Object, name: name, sequence: sequence, type: type, version: version)
  end

  @doc """
  Delete one object row by composite PK and re-derive the keyword
  claim for the logical object `(name, sequence, type)`.

  Behaviour, in rules:

    * If no other versions of the same `(name, sequence, type)`
      remain, any `keyword` row pointing at that triple is removed.
    * Otherwise the highest remaining version is consulted. The
      keyword table is updated to match what *it* would claim
      (extracted from its blob via the same codec path the insert
      flow uses).
    * `keywords_changed?` is `true` iff the `keyword` table actually
      changed as a result. Callers use it to decide whether to
      trigger a keyword-index rebuild.

  Returns `:not_found` if no object matches; otherwise
  `{:ok, %{object: %Object{}, keywords_changed?: boolean}}`. Broadcasts
  `:objects_deleted` on success.
  """
  def delete(name, sequence, type, version) do
    result =
      Repo.transaction(fn ->
        case Repo.get_by(Object, name: name, sequence: sequence, type: type, version: version) do
          nil ->
            Repo.rollback(:not_found)

          %Object{} = obj ->
            do_delete_one(obj, name, sequence, type)
        end
      end)

    case result do
      {:ok, %{} = out} ->
        broadcast(:objects_deleted)
        {:ok, out}

      {:error, :not_found} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete a batch of objects by composite PK, all within one
  transaction. Each delete runs the same per-row re-derive-keyword
  logic `delete/4` does, so the net keyword-table state after the
  batch matches what serial single-deletes would produce.

  `pks` is a list of `{name, sequence, type, version}` tuples. Missing
  rows are silently skipped (recorded in `:missing`) rather than
  rolling the whole batch back - the admin's filter-driven bulk
  delete inherently races concurrent single deletes, and blowing up
  on a missing PK would force the operator to re-filter and retry.

  Returns `{:ok, %{count, keywords_changed?, missing}}` where
  `count` is the number of rows actually removed and
  `keywords_changed?` is the OR of every row's keyword-table change
  flag. Broadcasts `:objects_deleted` once for the whole batch.
  """
  def delete_many(pks, opts \\ [])
  def delete_many([], _opts), do: {:ok, %{count: 0, keywords_changed?: false, missing: []}}

  def delete_many(pks, opts) when is_list(pks) do
    txn_opts = [timeout: Elixir.Keyword.get(opts, :timeout, 60_000)]

    result =
      Repo.transaction(
        fn ->
          Enum.reduce(
            pks,
            %{count: 0, keywords_changed?: false, missing: []},
            fn {n, s, t, v}, acc ->
              case Repo.get_by(Object, name: n, sequence: s, type: t, version: v) do
                nil ->
                  %{acc | missing: [{n, s, t, v} | acc.missing]}

                %Object{} = obj ->
                  %{keywords_changed?: kw} = do_delete_one(obj, n, s, t)

                  %{
                    acc
                    | count: acc.count + 1,
                      keywords_changed?: acc.keywords_changed? or kw
                  }
              end
            end
          )
        end,
        txn_opts
      )

    case result do
      {:ok, out} ->
        if out.count > 0, do: broadcast(:objects_deleted)
        {:ok, out}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_delete_one(%Object{} = obj, name, sequence, type) do
    {:ok, deleted} = Repo.delete(obj)
    kw_changed? = re_derive_keyword(name, sequence, type)
    %{object: deleted, keywords_changed?: kw_changed?}
  end

  # Sets the keyword table for `(name, sequence, type)` to whatever the
  # highest remaining version's blob says it should be. Returns `true`
  # iff the keyword table was actually mutated.
  defp re_derive_keyword(name, sequence, type) do
    current = current_keyword_for(name, sequence, type)

    desired =
      case highest_remaining_blob(name, sequence, type) do
        nil -> nil
        blob -> try_extract_keyword(blob)
      end

    cond do
      current == desired ->
        false

      is_nil(desired) ->
        delete_keyword_for(name, sequence, type)
        true

      true ->
        delete_keyword_for(name, sequence, type)
        case reclaim_keyword(desired, name, sequence, type) do
          :ok -> true
          # Another object owns the desired keyword. We've already
          # removed our stale row, which counts as a change. The live
          # owner's claim is left undisturbed.
          :collision -> true
        end
    end
  end

  defp current_keyword_for(name, sequence, type) do
    from(k in Keyword,
      where:
        k.object_name == ^name and k.object_sequence == ^sequence and
          k.object_type == ^type,
      select: k.keyword
    )
    |> Repo.one()
  end

  defp delete_keyword_for(name, sequence, type) do
    from(k in Keyword,
      where:
        k.object_name == ^name and k.object_sequence == ^sequence and
          k.object_type == ^type
    )
    |> Repo.delete_all()
  end

  defp highest_remaining_blob(name, sequence, type) do
    from(o in Object,
      where: o.name == ^name and o.sequence == ^sequence and o.type == ^type,
      order_by: [desc: o.version],
      limit: 1,
      select: o.contents
    )
    |> Repo.one()
  end

  defp reclaim_keyword(keyword, name, sequence, type) do
    case Repo.get(Keyword, keyword) do
      nil ->
        %Keyword{}
        |> Keyword.changeset(%{
          keyword: keyword,
          object_name: name,
          object_sequence: sequence,
          object_type: type
        })
        |> Repo.insert()

        :ok

      %Keyword{} ->
        # Live keyword already claimed by another object - leave it.
        :collision
    end
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  rescue
    _ -> :ok
  end
end
