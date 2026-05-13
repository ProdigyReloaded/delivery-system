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

defmodule Prodigy.Core.Data.Repo.Migrations.BackfillObjectContentHashAndKeywords do
  use Ecto.Migration
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Objects.Codec

  @moduledoc """
  Walks every existing `object` row, computes the canonicalized
  content_hash, and extracts any keyword-navigation segment into the
  new `keyword` table. Idempotent: re-running regenerates the same
  values and upserts keywords, so nothing diverges on replay.

  After this migration completes, `object.content_hash NOT NULL` is
  enforced.
  """

  def up do
    flush()

    Repo.transaction(
      fn ->
        stream =
          from(o in "object",
            select: %{
              name: o.name,
              sequence: o.sequence,
              type: o.type,
              version: o.version,
              contents: o.contents
            }
          )
          |> Repo.stream()

        Enum.each(stream, fn row ->
          hash = Codec.content_hash(row.contents)

          Repo.update_all(
            from(o in "object",
              where:
                o.name == ^row.name and
                  o.sequence == ^row.sequence and
                  o.type == ^row.type and
                  o.version == ^row.version
            ),
            set: [content_hash: hash]
          )

          maybe_index_keyword(row)
        end)
      end,
      timeout: :infinity
    )

    alter table(:object) do
      modify(:content_hash, :binary, null: false)
    end
  end

  def down do
    alter table(:object) do
      modify(:content_hash, :binary, null: true)
    end

    Repo.delete_all("keyword")
    Repo.update_all("object", set: [content_hash: nil])
  end

  # Parse + extract keyword; ignore objects whose blobs the codec can't
  # handle (shouldn't happen for real data, but we don't want a backfill
  # to crash on one bad row). Latest version wins - we upsert so a
  # second row in the same object family with the same keyword just
  # overwrites the pointer.
  defp maybe_index_keyword(%{contents: blob} = row) do
    with {:ok, parsed} <- Codec.parse(blob),
         {:ok, keyword} <- Codec.extract_keyword(parsed) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        "keyword",
        [
          %{
            keyword: keyword,
            object_name: row.name,
            object_sequence: row.sequence,
            object_type: row.type,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:object_name, :object_sequence, :object_type, :updated_at]},
        conflict_target: :keyword
      )
    else
      _ -> :ok
    end
  end
end
