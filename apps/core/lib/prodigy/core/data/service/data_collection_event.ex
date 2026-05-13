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

defmodule Prodigy.Core.Data.Service.DataCollectionEvent do
  @moduledoc """
  One row per parsed record from the RS client's data-collection
  stream. Persisted by `Prodigy.Server.Service.DataCollection`.

  Two kinds:

    * `"object"` - user viewed an object for a stretch of time. Carries
      `object_name`, `object_sequence`, `object_type`, plus the source
      record's `record_type` byte (meaning not yet fully decoded - kept
      for reference).
    * `"function"` - user invoked a function key (exit/undo/path/help/...).
      Carries `function_class`, one of the class codes the logon-time
      bitmask addresses.

  Both share `session_id`, `user_id`, and `duration_seconds`
  (minutes x 60 + seconds from the wire payload).

  Individual records sent in batches and do not seem to carry system time,
  so all the events will appear to be at the time the batch was delivered.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "data_collection_event" do
    belongs_to :session, Prodigy.Core.Data.Service.Session
    field :user_id, :string
    field :kind, :string

    # object-kind fields
    field :object_name, :string
    field :object_sequence, :integer
    field :object_type, :integer
    field :record_type, :integer

    # function-kind fields
    field :function_class, :integer

    # common
    field :duration_seconds, :integer
    field :raw_record, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @permitted ~w(
    session_id user_id kind object_name object_sequence object_type
    record_type function_class duration_seconds raw_record
  )a

  def changeset(event, attrs) do
    event
    |> cast(attrs, @permitted)
    |> validate_required([:user_id, :kind, :duration_seconds])
    |> validate_inclusion(:kind, ["object", "function"])
  end
end
