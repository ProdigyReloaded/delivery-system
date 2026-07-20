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

defmodule Prodigy.Server.MemberList.Source do
  @moduledoc """
  Reads the opted-in member set out of the live user/household tables
  and returns it as a list of normalized record maps suitable for the
  CCDAM index. The map keys match the `Ccdam.Schema` field names so the
  default index builder can format them directly.

  Eligibility (all must hold):

    * `user.date_enrolled` is not nil and `user.date_deleted` is nil.
    * The user's household exists and is not disabled
      (`household.disabled_date` is nil).
    * `user.profile["02B0"]` (`PRF_ML_INDICATOR`) decodes to a non-zero
      byte. The TAC is `:binary`-typed in `ProfileSchema` (jsonb cannot
      carry `\\u0000`), so the stored value is base64 of the 1-byte flag.
    * `user.profile["015E"]` (last name) is non-blank - without a last
      name there's nothing to index under.
    * `household.profile["0105"]` (state) is non-blank - the state/city
      indexes need a state. City may be blank; those records simply
      won't appear under the city-scoped keys.
  """

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.User

  import Ecto.Query

  # TAC keys as they sit in the JSONB profile maps (4-digit uppercase hex).
  # The indicator itself (0x02B0) is hidden behind `User.in_member_list?/1`.
  @last_name "015E"
  @first_name "015F"
  @middle_name "0160"
  @title "0161"
  @hh_state "0105"
  @hh_city "0104"

  @doc """
  Query the DB for eligible users (the SQL-side filters: enrolled and
  not deleted, with a non-disabled household preloaded) and project
  each through `to_record/1`. Returns the records in `user.id` order
  for determinism.
  """
  @spec list_eligible() :: [map()]
  def list_eligible do
    from(u in User,
      where: not is_nil(u.date_enrolled) and is_nil(u.date_deleted),
      preload: :household,
      order_by: [asc: u.id]
    )
    |> Repo.all()
    |> Enum.flat_map(&to_record/1)
  end

  @doc """
  Apply the eligibility rules to one preloaded `%User{}` and return
  either `[record_map]` or `[]`. Exposed for unit tests; the production
  pipeline goes through `list_eligible/0`.
  """
  @spec to_record(User.t()) :: [map()]
  def to_record(%User{household: nil}), do: []
  def to_record(%User{household: %{disabled_date: d}}) when not is_nil(d), do: []

  def to_record(%User{} = u) do
    profile = u.profile || %{}
    hh_profile = (u.household && u.household.profile) || %{}

    last = trim(Map.get(profile, @last_name))
    state = trim(Map.get(hh_profile, @hh_state))

    cond do
      not User.in_member_list?(u) -> []
      last == "" -> []
      state == "" -> []
      true ->
        [
          %{
            "user_id" => u.id,
            "state" => state,
            "city" => trim(Map.get(hh_profile, @hh_city)),
            "unknown" => "",
            "last_name" => last,
            "first_name" => trim(Map.get(profile, @first_name)),
            "middle" => trim(Map.get(profile, @middle_name)),
            "title" => trim(Map.get(profile, @title))
          }
        ]
    end
  end

  defp trim(nil), do: ""
  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v), do: to_string(v) |> String.trim()
end
