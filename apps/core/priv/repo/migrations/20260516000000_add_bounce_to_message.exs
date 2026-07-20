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

defmodule Prodigy.Core.Data.Repo.Migrations.AddBounceToMessage do
  use Ecto.Migration

  # When set, this message is a Return-to-Sender notification synthesized by
  # the server for the original sender. The mailbox-listing row's flags1
  # byte gets bit 0x04 OR'd in so the DOS client's MSZB016X.PGM LINKs to
  # MSZB025X.PGM (the bounce-parser) on read. Stored as a column so
  # get_message/get_mailbox_page can pick the right wire format without
  # parsing contents.
  def change do
    alter table(:message) do
      add :bounce, :boolean, default: false, null: false
    end
  end
end
