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

defmodule Prodigy.Core.Data.Repo.Migrations.RenameMailingListMembersUniqueIndex do
  use Ecto.Migration

  # The default index name produced by
  # `create unique_index(:mailing_list_members,
  # [:mailing_list_id, :address_book_entry_id])` in
  # 20260514000000_create_messaging_lists.exs is 64 chars long and
  # gets truncated by Postgres (NAMEDATALEN=64, identifiers cap at 63).
  # The truncation makes Ecto's default `unique_constraint/2` lookup
  # fail to match, so duplicate-member inserts raise a raw
  # Ecto.ConstraintError instead of returning {:error, changeset}.
  # Rename to a short explicit name so the schema's unique_constraint
  # can reference it cleanly.
  def change do
    execute(
      "ALTER INDEX mailing_list_members_mailing_list_id_address_book_entry_id_inde RENAME TO mailing_list_members_link_index",
      "ALTER INDEX mailing_list_members_link_index RENAME TO mailing_list_members_mailing_list_id_address_book_entry_id_inde"
    )
  end
end
