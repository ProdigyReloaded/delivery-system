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

defmodule Prodigy.Core.Data.Household do
  use Ecto.Schema

  @moduledoc """
  Schema specific to Households and related change functions
  """

  @primary_key {:id, :string, []}
  schema "household" do
    has_many(:users, Prodigy.Core.Data.User)
    field(:address_1, :string)
    field(:address_2, :string)
    field(:city, :string)
    field(:state, :string)
    field(:zipcode, :string)
    field(:telephone, :string)
    field(:enabled_date, :date)
    field(:disabled_date, :date)
    field(:disabled_reason, :string)
    field(:subscriber_suffix, :string)
    field(:household_password, :string)
    #      field :household_income_range_code, ??
    #      field :account_status_flag, ??

    # TODO much of the user data is denormalized within the household; it can probably be normalized and
    #      then exposed via the profile service in a denormalized form
    field(:user_a_last, :string)
    field(:user_a_first, :string)
    field(:user_a_middle, :string)
    field(:user_a_title, :string)
    field(:user_a_access_level, :string)
    field(:user_a_indicators, :string)
    field(:user_b_last, :string)
    field(:user_b_first, :string)
    field(:user_b_middle, :string)
    field(:user_b_title, :string)
    field(:user_b_access_level, :string)
    field(:user_b_indicators, :string)
    field(:user_c_last, :string)
    field(:user_c_first, :string)
    field(:user_c_middle, :string)
    field(:user_c_title, :string)
    field(:user_c_access_level, :string)
    field(:user_c_indicators, :string)
    field(:user_d_last, :string)
    field(:user_d_first, :string)
    field(:user_d_middle, :string)
    field(:user_d_title, :string)
    field(:user_d_access_level, :string)
    field(:user_d_indicators, :string)
    field(:user_e_last, :string)
    field(:user_e_first, :string)
    field(:user_e_middle, :string)
    field(:user_e_title, :string)
    field(:user_e_access_level, :string)
    field(:user_e_indicators, :string)
    field(:user_f_last, :string)
    field(:user_f_first, :string)
    field(:user_f_middle, :string)
    field(:user_f_title, :string)
    field(:user_f_access_level, :string)
    field(:user_f_indicators, :string)
  end

  def changeset(household, params \\ %{}) do
    household
    |> Ecto.Changeset.cast(params, [
      :address_1,
      :address_2,
      :city,
      :state,
      :zipcode,
      :telephone,
      :user_a_last,
      :user_a_first,
      :user_a_middle,
      :user_a_title,
      :user_b_last,
      :user_b_first,
      :user_b_middle,
      :user_b_title,
      :user_c_last,
      :user_c_first,
      :user_c_middle,
      :user_c_title,
      :user_d_last,
      :user_d_first,
      :user_d_middle,
      :user_d_title,
      :user_e_last,
      :user_e_first,
      :user_e_middle,
      :user_e_title,
      :user_f_last,
      :user_f_first,
      :user_f_middle,
      :user_f_title
    ])
  end
end
