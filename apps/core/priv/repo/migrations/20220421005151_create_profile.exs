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

defmodule Prodigy.Core.Data.Repo.Migrations.CreateProfile do
  use Ecto.Migration

  def change do
    create table(:household, primary_key: false) do
      add :id, :string, primary_key: true  # aka the "household_userid"; if the subscriber is USER12A, this is USER12
      add :address_1, :string
      add :address_2, :string
      add :city, :string
      add :state, :string
      add :zipcode, :string
      add :telephone, :string
      add :enabled_date, :date
      add :disabled_date, :date
      add :disabled_reason, :string
      add :subscriber_suffix, :string
      add :household_password, :string
#      add :household_income_range_code, ??
#      add :account_status_flag, ??
      add :user_a_last, :string
      add :user_a_first, :string
      add :user_a_middle, :string
      add :user_a_title, :string
      add :user_a_access_level, :string
      add :user_a_indicators, :string
      add :user_b_last, :string
      add :user_b_first, :string
      add :user_b_middle, :string
      add :user_b_title, :string
      add :user_b_access_level, :string
      add :user_b_indicators, :string
      add :user_c_last, :string
      add :user_c_first, :string
      add :user_c_middle, :string
      add :user_c_title, :string
      add :user_c_access_level, :string
      add :user_c_indicators, :string
      add :user_d_last, :string
      add :user_d_first, :string
      add :user_d_middle, :string
      add :user_d_title, :string
      add :user_d_access_level, :string
      add :user_d_indicators, :string
      add :user_e_last, :string
      add :user_e_first, :string
      add :user_e_middle, :string
      add :user_e_title, :string
      add :user_e_access_level, :string
      add :user_e_indicators, :string
      add :user_f_last, :string
      add :user_f_first, :string
      add :user_f_middle, :string
      add :user_f_title, :string
      add :user_f_access_level, :string
      add :user_f_indicators, :string
    end

    create table(:user, primary_key: false) do
      add :id, :string, primary_key: true
      add :household_id, references(:household, type: :string)
      add :password, :string
      add :logged_on, :boolean
#      add :region, ??
#      add :mail_count, ??
#      add :access_control, ??
#      add :pw_change_try_count, ??
#      add :port_index_id, ??
#      add :indicators_for_application_usage, ??
      add :gender, :string
      add :date_enrolled, :date
      add :date_deleted, :date
#      add :delete_reason, ??
#      add :delete_source, ??
      add :last_name, :string
      add :first_name, :string
      add :middle_name, :string
      add :title, :string
      add :birthdate, :date
      # many more
    end
  end
end
