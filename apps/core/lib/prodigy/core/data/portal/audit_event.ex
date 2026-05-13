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

defmodule Prodigy.Core.Data.Portal.AuditEvent do
  @moduledoc """
  Append-only record of a portal-side action worth remembering:
  grants, revokes, role changes, destructive admin actions. Written
  inside the same transaction as the operation that caused it, so
  failures can't leave the audit log out of sync with state.

  `actor_id` is nullable - bootstrap seeds and background jobs have
  no portal-user actor.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "portal_audit_events" do
    belongs_to :actor, Prodigy.Core.Data.Portal.User
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    field :details, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:actor_id, :action, :target_type, :target_id, :details])
    |> validate_required([:action])
  end
end
