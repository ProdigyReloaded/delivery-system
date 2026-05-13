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

defmodule Prodigy.Portal.Settings do
  @moduledoc """
  Read/write facade over the `portal_settings` key/value store. Values
  are JSON-encoded on the way in and decoded on the way out so callers
  can stash booleans, integers, or short lists without thinking about
  serialization.

  Mutations record the actor and write an audit-log entry via
  `Prodigy.Portal.Authz.write_audit!/5`. Read access is unauthenticated
  at this layer - callers (LVs, plugs) do their own scope check before
  acting on a value.
  """
  alias Prodigy.Core.Data.Portal.Setting
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Authz

  @doc """
  Fetch the value for `key`. Returns `default` if the row doesn't
  exist or the stored value fails to decode.

  Examples:

      Settings.get("invitation_only", false)
      #=> false  (when no row yet)
  """
  def get(key, default \\ nil) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil ->
        default

      %Setting{value: raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          _ -> default
        end
    end
  end

  @doc """
  Upsert `key` with `value`. `actor_id` is the portal-user id of
  whoever made the change; pass `nil` for system / bootstrap writes
  (e.g. from a migration helper or an ops script).

  The encoded value goes into the row verbatim; readers decode JSON
  on the way out so any JSON-representable shape is fair game.
  """
  def put(actor_id, key, value)
      when is_binary(key) and (is_integer(actor_id) or is_nil(actor_id)) do
    encoded = Jason.encode!(value)

    attrs = %{
      key: key,
      value: encoded,
      updated_by_id: actor_id
    }

    {:ok, setting} =
      %Setting{}
      |> Setting.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:value, :updated_by_id, :updated_at]},
        conflict_target: :key
      )

    if actor_id do
      Authz.write_audit!(actor_id, "set.setting", "portal_setting", key, %{value: encoded})
    end

    {:ok, setting}
  end

  @doc "Convenience: returns `true` if the system is in invitation-only mode."
  def invitation_only? do
    get("invitation_only", false) == true
  end
end
