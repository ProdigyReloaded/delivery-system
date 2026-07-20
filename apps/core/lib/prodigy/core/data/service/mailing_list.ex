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

defmodule Prodigy.Core.Data.Service.MailingList do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Personal mailing / distribution lists for each user. Each row is a
  named list owned by `owner_id`; `list_number` is the client-facing
  1..N slot id used over the DIA wire. Names are limited to 19 chars
  by the DOS client. Membership is many-to-many via `mailing_list_members`
  pointing at the owner's own `address_book_entries`.
  """

  # Mirror of the DOS client's rule: mailing-list names cannot match the
  # Prodigy ID format (4 alpha + 2 digit + 1 hex alpha A-F, e.g. AAAA11A).
  @prodigy_id_regex ~r/^[A-Za-z]{4}\d{2}[A-Fa-f]$/

  schema "mailing_lists" do
    belongs_to(:owner, Prodigy.Core.Data.Service.User, type: :string)
    field(:name, :string)
    field(:list_number, :integer)
    field(:max_members, :integer, default: 10)

    many_to_many(:members, Prodigy.Core.Data.Service.AddressBookEntry,
      join_through: "mailing_list_members",
      join_keys: [mailing_list_id: :id, address_book_entry_id: :id]
    )

    timestamps()
  end

  def changeset(list, params \\ %{}) do
    list
    |> cast(params, [:owner_id, :name, :list_number, :max_members])
    |> validate_required([:owner_id, :name, :list_number])
    |> validate_length(:name, max: 19)
    |> validate_name_not_prodigy_id()
    |> validate_number(:max_members, greater_than: 0, less_than_or_equal_to: 20)
    |> unique_constraint([:owner_id, :list_number])
    |> unique_constraint([:owner_id, :name])
  end

  defp validate_name_not_prodigy_id(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if name && Regex.match?(@prodigy_id_regex, name) do
        [name: "cannot look like a Prodigy ID"]
      else
        []
      end
    end)
  end

  # Note: we do NOT block a mailing-list name that collides with an
  # existing address-book nickname for the same owner. The DOS client
  # SENDs the create-list request (0x0D0C) WITHOUT a matching RECEIVE,
  # so server-side rejection can't surface - returning any response
  # trips client OMCM 10 "out of sequence". Collision is handled at
  # send time via MessagingLists.resolve_recipients/2 instead.
end

defmodule Prodigy.Core.Data.Service.MailingListMember do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Join row linking a `MailingList` to one of the owner's
  `AddressBookEntry` rows. `position` is reserved for future
  ordering needs; nothing reads it today.
  """

  @primary_key false
  schema "mailing_list_members" do
    belongs_to(:mailing_list, Prodigy.Core.Data.Service.MailingList)
    belongs_to(:address_book_entry, Prodigy.Core.Data.Service.AddressBookEntry)
    field(:position, :integer)

    timestamps()
  end

  def changeset(member, params \\ %{}) do
    member
    |> cast(params, [:mailing_list_id, :address_book_entry_id, :position])
    |> validate_required([:mailing_list_id, :address_book_entry_id])
    # Explicit constraint name - Ecto's default would be
    # "mailing_list_members_mailing_list_id_address_book_entry_id_index"
    # (64 chars), which Postgres truncates on creation.  See
    # 20260517000000_rename_mailing_list_members_unique_index for the
    # rename to this shorter name.
    |> unique_constraint([:mailing_list_id, :address_book_entry_id],
      name: :mailing_list_members_link_index
    )
  end
end
