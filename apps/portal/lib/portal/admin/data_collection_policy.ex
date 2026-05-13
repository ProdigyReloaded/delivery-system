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

defmodule Prodigy.Portal.Admin.DataCollectionPolicy do
  @moduledoc """
  Admin helper for the per-user `data_collection_policy` row. Each of
  the 14 flags toggles one bit the logon response sends to the RS
  client; see `Prodigy.Server.Service.Logon` for the wire layout and
  `Prodigy.Server.Service.DataCollection` for the resulting record
  stream.

  Operators don't edit all 14 bits at once - they flip one at a time
  while troubleshooting. Each toggle is a row-level upsert so the
  change lands in the policy table immediately and the next logon
  response picks it up.
  """
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.DataCollectionPolicy

  # Order + labels for the admin UI. The field atoms match the schema.
  @fields [
    {:ad, "Ad"},
    {:pwindow, "Pop-up window"},
    {:element, "Element"},
    {:template, "Template"},
    {:exit, "Exit"},
    {:undo, "Undo"},
    {:path, "Path"},
    {:help, "Help"},
    {:jump, "Jump"},
    {:back, "Back"},
    {:next, "Next"},
    {:commit, "Commit"},
    {:action, "Action"},
    {:look, "Look"}
  ]

  @doc "Ordered list of `{field, label}` pairs for UI rendering."
  def fields, do: @fields

  @doc "Just the field atoms - useful for toggle_all / validation."
  def field_atoms, do: Enum.map(@fields, fn {f, _} -> f end)

  @doc """
  Returns the policy row for `user_id`, or a fresh struct with all
  flags nil if no row exists yet. Nil is treated as false everywhere
  downstream; the logon path's `bool2int` coerces it.
  """
  def get(user_id) when is_binary(user_id) do
    case Repo.get(DataCollectionPolicy, user_id) do
      nil -> %DataCollectionPolicy{user_id: user_id}
      policy -> policy
    end
  end

  @doc """
  Sets a single flag on the user's policy row, upserting if needed.
  Returns `{:ok, policy}`.
  """
  def set(user_id, field, value)
      when is_binary(user_id) and is_atom(field) and is_boolean(value) do
    validate_field!(field)

    row = get(user_id)
    attrs = Map.put(%{}, field, value)

    {:ok, upsert(row, attrs)}
  end

  @doc """
  Flips `field` on the user's policy row (nil / false -> true,
  true -> false).
  """
  def toggle(user_id, field) do
    row = get(user_id)
    set(user_id, field, not Map.get(row, field, false) == true)
  end

  @doc "Sets every flag to `value`."
  def set_all(user_id, value) when is_boolean(value) do
    attrs = Map.new(@fields, fn {f, _} -> {f, value} end)
    row = get(user_id)
    {:ok, upsert(row, attrs)}
  end

  @doc """
  Persists every flag from the supplied policy struct in one upsert.
  Used by the admin edit modal's Save button: toggles update a
  working copy in memory, and this lands all 14 flags atomically
  when the operator commits.
  """
  def save(user_id, %DataCollectionPolicy{} = working) when is_binary(user_id) do
    attrs =
      Map.new(field_atoms(), fn f ->
        {f, Map.get(working, f) == true}
      end)

    row = get(user_id)
    {:ok, upsert(row, attrs)}
  end

  # Ecto's default changeset flow doesn't support a string PK upsert
  # cleanly; the schema uses user_id as the primary key but has no
  # changeset. Use raw inserts with on_conflict: :replace for the
  # touched fields.
  defp upsert(%DataCollectionPolicy{user_id: user_id} = row, attrs) do
    merged =
      Enum.reduce(attrs, Map.from_struct(row) |> Map.delete(:__meta__), fn {k, v}, acc ->
        Map.put(acc, k, v)
      end)
      |> Map.put(:user_id, user_id)

    replace_fields = Enum.map(attrs, fn {k, _} -> k end)

    {1, [returned]} =
      Repo.insert_all(
        DataCollectionPolicy,
        [merged],
        on_conflict: {:replace, replace_fields},
        conflict_target: :user_id,
        returning: true
      )

    returned
  end

  defp validate_field!(field) do
    unless field in field_atoms() do
      raise ArgumentError, "unknown data_collection_policy field: #{inspect(field)}"
    end

    :ok
  end
end
