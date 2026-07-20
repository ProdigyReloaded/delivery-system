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

defmodule Prodigy.Core.Data.Service.AddressBookEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Personal address book entries for each user. Each row is one nickname
  that `owner_id` has assigned to another service user (`target_user_id`).
  `entry_number` is the 1..50 client-facing slot id that the DIA wire
  protocol uses to refer to the entry; nicknames are limited to 18 chars
  by the DOS client. Cross-references via `mailing_list_members` let a
  single entry appear in multiple of the owner's mailing lists.
  """

  # Prodigy ID format: 4 alpha + 2 digit + 1 hex alpha A-F (e.g. AAAA11A).
  # The DOS client refuses to accept nicknames that match this pattern;
  # we mirror that here so a non-conforming client can't bypass the rule.
  @prodigy_id_regex ~r/^[A-Za-z]{4}\d{2}[A-Fa-f]$/

  schema "address_book_entries" do
    belongs_to(:owner, Prodigy.Core.Data.Service.User, type: :string)
    belongs_to(:target_user, Prodigy.Core.Data.Service.User, type: :string)
    field(:nickname, :string)
    field(:entry_number, :integer)

    many_to_many(:mailing_lists, Prodigy.Core.Data.Service.MailingList,
      join_through: "mailing_list_members",
      join_keys: [address_book_entry_id: :id, mailing_list_id: :id]
    )

    timestamps()
  end

  def changeset(entry, params \\ %{}) do
    entry
    |> cast(params, [:owner_id, :target_user_id, :nickname, :entry_number])
    |> validate_required([:owner_id, :target_user_id, :nickname, :entry_number])
    |> validate_length(:nickname, max: 18)
    |> validate_nickname_not_prodigy_id()
    |> validate_number(:entry_number, greater_than: 0, less_than_or_equal_to: 50)
    |> unique_constraint([:owner_id, :entry_number])
    |> unique_constraint([:owner_id, :nickname])
    |> unique_constraint([:owner_id, :target_user_id])
    |> foreign_key_constraint(:target_user_id)
    |> foreign_key_constraint(:owner_id)
  end

  defp validate_nickname_not_prodigy_id(changeset) do
    validate_change(changeset, :nickname, fn :nickname, nickname ->
      if nickname && Regex.match?(@prodigy_id_regex, nickname) do
        [nickname: "cannot look like a Prodigy ID"]
      else
        []
      end
    end)
  end

  # Note: we do NOT block a nickname that collides with an existing
  # mailing-list name. Collision is handled at send time via
  # MessagingLists.resolve_recipients/2 with the precedence rule
  # "nickname wins over mailing-list" (principle of least astonishment:
  # one address resolution beats expansion). See messaging_lists.ex.
end
