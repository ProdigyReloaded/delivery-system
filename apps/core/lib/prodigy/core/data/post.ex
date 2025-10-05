# Copyright 2022-2025, Phillip Heller
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

defmodule Prodigy.Core.Data.Post do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @moduledoc """
  Schema for Bulletin Board posts and replies
  """

  schema "post" do
    belongs_to(:topic, Prodigy.Core.Data.Topic)
    field(:sent_date, :utc_datetime)
    field(:in_reply_to, :integer)  # NULL for top-level posts, post_id for replies
    field(:to_id, :string, default: "")  # Empty defaults to "All"
    field(:from_id, :string)  # user_id from posting context
    field(:subject, :string)
    field(:body, :binary)  # Using binary to match message.contents pattern

    # Virtual fields for computed values (not stored in DB)
    field(:reply_count, :integer, virtual: true)
    field(:last_reply_date, :utc_datetime, virtual: true)
    field(:to_name, :string, virtual: true)  # Derived from user_id
    field(:from_name, :string, virtual: true)  # Derived from user_id

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:topic_id, :sent_date, :in_reply_to, :to_id,
      :from_id, :subject, :body])
    |> validate_required([:topic_id, :sent_date, :from_id, :subject, :body])
    |> foreign_key_constraint(:topic_id)
    |> foreign_key_constraint(:in_reply_to)
  end

  @doc """
  Query to load a post with reply count and last reply date.
  This should be used when fetching posts for display.
  """
  def with_reply_stats(query) do
    from p in query,
         left_join: r in __MODULE__,
         on: r.in_reply_to == p.id,
         group_by: p.id,
         select: %{p |
           reply_count: count(r.id),
           last_reply_date: max(r.sent_date)
         }
  end

  @doc """
  Query to load a post with the from_name populated from the user table.
  """
  def with_from_name(query) do
    from p in query,
         left_join: u in Prodigy.Core.Data.User,
         on: u.id == p.from_id,
         select: %{p |
           from_name: fragment("COALESCE(?, ?)", u.first_name, p.from_id)
         }
  end
end
