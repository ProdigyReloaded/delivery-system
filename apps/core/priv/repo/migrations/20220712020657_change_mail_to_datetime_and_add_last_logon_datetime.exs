# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Core.Data.Repo.Migrations.ChangeMailToDatetimeAndAddLastLogonDatetime do
  use Ecto.Migration

  def change do
    alter table(:user) do
      add :prf_last_logon_time, :string
      add :prf_last_logon_date, :string
    end

    alter table(:message) do
      modify :sent_date, :timestamp
      modify :retain_date, :timestamp
    end
  end
end
