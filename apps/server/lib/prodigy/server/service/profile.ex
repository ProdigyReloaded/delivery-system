# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Server.Service.Profile do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Profile Requests
  """

  require Logger
  require Ecto.Query
  use EnumType

  alias Prodigy.Core.Data.{Household, Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context


  defp identity(input) do
    input
  end

  defp trim_whitespace(input) do
    String.trim(input)
  end

  defp todate(input) do
    Timex.parse!(input, "{0M}{0D}{YY}") |> Timex.to_date()
  end

  defp to2digitdate(input) do
    parsed_date = todate(input)
    if parsed_date.year >= 2039 do
      %{ parsed_date | year: parsed_date.year - 100}
    else
      parsed_date
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def get_user_changeset(entries) do
    Enum.reduce(entries, %{}, fn entry, changeset ->
      {tac, value} = entry

      {key, xlat} =
        case tac do
          0x14E -> {:id, &identity/1}
          0x14F -> {:password, &identity/1}
          0x150 -> {:region, &identity/1}
          0x152 -> {:mail_count, &identity/1}
          0x153 -> {:access_control, &identity/1}
          0x154 -> {:pw_change_try_count, &identity/1}
          0x155 -> {:port_index_id, &identity/1}
          0x156 -> {:indicators_for_application_usage, &identity/1}
          0x157 -> {:gender, &identity/1}
          0x159 -> {:date_enrolled, &todate/1}
          0x15A -> {:date_deleted, &todate/1}
          0x15B -> {:delete_reason, &identity/1}
          0x15C -> {:delete_source, &identity/1}
          0x15E -> {:last_name, &identity/1}
          0x15F -> {:first_name, &identity/1}
          0x160 -> {:middle_name, &identity/1}
          0x161 -> {:title, &identity/1}
          0x162 -> {:birthdate, &to2digitdate/1}
          0x20A -> {:prf_path_jumpword_13, &trim_whitespace/1}
          0x20B -> {:prf_path_jumpword_14, &trim_whitespace/1}
          0x20C -> {:prf_path_jumpword_15, &trim_whitespace/1}
          0x20D -> {:prf_path_jumpword_16, &trim_whitespace/1}
          0x20E -> {:prf_path_jumpword_17, &trim_whitespace/1}
          0x20F -> {:prf_path_jumpword_18, &trim_whitespace/1}
          0x210 -> {:prf_path_jumpword_19, &trim_whitespace/1}
          0x211 -> {:prf_path_jumpword_20, &trim_whitespace/1}
          0x23F -> {:prf_path_jumpword_1, &trim_whitespace/1}
          0x240 -> {:prf_path_jumpword_2, &trim_whitespace/1}
          0x241 -> {:prf_path_jumpword_3, &trim_whitespace/1}
          0x242 -> {:prf_path_jumpword_4, &trim_whitespace/1}
          0x243 -> {:prf_path_jumpword_5, &trim_whitespace/1}
          0x244 -> {:prf_path_jumpword_6, &trim_whitespace/1}
          0x245 -> {:prf_path_jumpword_7, &trim_whitespace/1}
          0x246 -> {:prf_path_jumpword_8, &trim_whitespace/1}
          0x247 -> {:prf_path_jumpword_9, &trim_whitespace/1}
          0x248 -> {:prf_path_jumpword_10, &trim_whitespace/1}
          0x249 -> {:prf_path_jumpword_11, &trim_whitespace/1}
          0x24A -> {:prf_path_jumpword_12, &trim_whitespace/1}
          0x2C2 -> {:prf_last_logon_date, &trim_whitespace/1}
          0x2C4 -> {:prf_last_logon_time, &trim_whitespace/1}
          0x2FB -> {:prf_madmaze_save, &identity/1}
          _ -> {nil, nil}
        end

      if key == nil, do: changeset, else: Map.put(changeset, key, xlat.(value))
    end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def get_household_changeset(entries) do
    Enum.reduce(entries, %{}, fn entry, changeset ->
      {tac, value} = entry

      {key, xlat} =
        case tac do
          0x102 -> {:address_1, &identity/1}
          0x103 -> {:address_2, &identity/1}
          0x104 -> {:city, &identity/1}
          0x105 -> {:state, &identity/1}
          0x106 -> {:zipcode, &identity/1}
          0x107 -> {:telephone, &identity/1}
          0x10E -> {:enabled_date, &todate/1}
          0x10F -> {:disabled_date, &todate/1}
          0x110 -> {:disabled_reason, &identity/1}
          0x111 -> {:id, &identity/1}
          0x112 -> {:subscriber_suffix, &identity/1}
          0x113 -> {:household_password, &identity/1}
          0x114 -> {:household_income_range_code, &identity/1}
          0x115 -> {:suffix_in_use_indicators, &identity/1}
          0x116 -> {:account_status_flag, &identity/1}
          0x11A -> {:user_a_last, &identity/1}
          0x11B -> {:user_a_first, &identity/1}
          0x11C -> {:user_a_middle, &identity/1}
          0x11D -> {:user_a_title, &identity/1}
          0x11F -> {:user_a_access_level, &identity/1}
          0x120 -> {:user_a_indicators, &identity/1}
          0x123 -> {:user_b_last, &identity/1}
          0x124 -> {:user_b_first, &identity/1}
          0x125 -> {:user_b_middle, &identity/1}
          0x126 -> {:user_b_title, &identity/1}
          0x128 -> {:user_b_access_level, &identity/1}
          0x129 -> {:user_b_indicators, &identity/1}
          0x12C -> {:user_c_last, &identity/1}
          0x12D -> {:user_c_first, &identity/1}
          0x12E -> {:user_c_middle, &identity/1}
          0x12F -> {:user_c_title, &identity/1}
          0x131 -> {:user_c_access_level, &identity/1}
          0x132 -> {:user_c_indicators, &identity/1}
          0x135 -> {:user_d_last, &identity/1}
          0x136 -> {:user_d_first, &identity/1}
          0x137 -> {:user_d_middle, &identity/1}
          0x138 -> {:user_d_title, &identity/1}
          0x13A -> {:user_d_access_level, &identity/1}
          0x13B -> {:user_d_indicators, &identity/1}
          0x13E -> {:user_e_last, &identity/1}
          0x13F -> {:user_e_first, &identity/1}
          0x140 -> {:user_e_middle, &identity/1}
          0x141 -> {:user_e_title, &identity/1}
          0x143 -> {:user_e_access_level, &identity/1}
          0x144 -> {:user_e_indicators, &identity/1}
          0x147 -> {:user_f_last, &identity/1}
          0x148 -> {:user_f_first, &identity/1}
          0x149 -> {:user_f_middle, &identity/1}
          0x14A -> {:user_f_title, &identity/1}
          0x14C -> {:user_f_access_level, &identity/1}
          0x14D -> {:user_f_indicators, &identity/1}
          _ -> {nil, nil}
        end

      if key == nil, do: changeset, else: Map.put(changeset, key, xlat.(value))
    end)
  end

  def get_tac(tac, user, household) do
    res = get_value(tac, user, household)

    <<tac::16-big>> <>
      case res do
        nil -> <<0x0>>
        _ -> <<byte_size(res), res::binary>>
      end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def get_value(tac, user, household) do
    case tac do
      0x102 -> household.address_1
      0x103 -> household.address_2
      0x104 -> household.city
      0x105 -> household.state
      0x106 -> household.zipcode
      0x107 -> household.telephone
      0x10E -> household.enabled_date
      0x10F -> household.disabled_date
      0x110 -> household.disabled_reason
      0x111 -> household.id
      0x112 -> household.subscriber_suffix
      0x113 -> household.household_password
      0x114 -> household.household_income_range_code
      0x115 -> household.suffix_in_use_indicators
      0x116 -> household.account_status_flag
      0x11A -> household.user_a_last
      0x11B -> household.user_a_first
      0x11C -> household.user_a_middle
      0x11D -> household.user_a_title
      0x11F -> household.user_a_access_level
      0x120 -> household.user_a_indicators
      0x123 -> household.user_b_last
      0x124 -> household.user_b_first
      0x125 -> household.user_b_middle
      0x126 -> household.user_b_title
      0x128 -> household.user_b_access_level
      0x129 -> household.user_b_indicators
      0x12C -> household.user_c_last
      0x12D -> household.user_c_first
      0x12E -> household.user_c_middle
      0x12F -> household.user_c_title
      0x131 -> household.user_c_access_level
      0x132 -> household.user_c_indicators
      0x135 -> household.user_d_last
      0x136 -> household.user_d_first
      0x137 -> household.user_d_middle
      0x138 -> household.user_d_title
      0x13A -> household.user_d_access_level
      0x13B -> household.user_d_indicators
      0x13E -> household.user_e_last
      0x13F -> household.user_e_first
      0x140 -> household.user_e_middle
      0x141 -> household.user_e_title
      0x143 -> household.user_e_access_level
      0x144 -> household.user_e_indicators
      0x147 -> household.user_f_last
      0x148 -> household.user_f_first
      0x149 -> household.user_f_middle
      0x14A -> household.user_f_title
      0x14C -> household.user_f_access_level
      0x14D -> household.user_f_indicators
      0x14E -> user.id
      0x14F -> user.password
      0x150 -> user.region
      0x152 -> user.mail_count
      0x153 -> user.access_control
      0x154 -> user.pw_change_try_count
      0x155 -> user.port_index_id
      0x156 -> user.indicators_for_application_usage
      0x157 -> user.gender
      0x159 -> user.date_enrolled
      0x15A -> user.date_deleted
      0x15B -> user.delete_reason
      0x15C -> user.delete_source
      0x15E -> user.last_name
      0x15F -> user.first_name
      0x160 -> user.middle_name
      0x161 -> user.title
      0x162 -> user.birthdate
      0x20A -> user.prf_path_jumpword_13
      0x20B -> user.prf_path_jumpword_14
      0x20C -> user.prf_path_jumpword_15
      0x20D -> user.prf_path_jumpword_16
      0x20E -> user.prf_path_jumpword_17
      0x20F -> user.prf_path_jumpword_18
      0x210 -> user.prf_path_jumpword_19
      0x211 -> user.prf_path_jumpword_20
      0x23F -> user.prf_path_jumpword_1
      0x240 -> user.prf_path_jumpword_2
      0x241 -> user.prf_path_jumpword_3
      0x242 -> user.prf_path_jumpword_4
      0x243 -> user.prf_path_jumpword_5
      0x244 -> user.prf_path_jumpword_6
      0x245 -> user.prf_path_jumpword_7
      0x246 -> user.prf_path_jumpword_8
      0x247 -> user.prf_path_jumpword_9
      0x248 -> user.prf_path_jumpword_10
      0x249 -> user.prf_path_jumpword_11
      0x24A -> user.prf_path_jumpword_12
      0x2C2 -> user.prf_last_logon_date
      0x2C4 -> user.prf_last_logon_time
      0x2FB -> user.prf_madmaze_save

      _ ->
        Logger.error("User requested profile value for unhandled TAC #{inspect(tac, base: :hex)}")
        " "
    end
  end

  def parse_request_values(payload, entries \\ [])

  def parse_request_values(<<>>, entries) do
    entries
  end

  def parse_request_values(payload, entries) do
    <<tac::16-big, length, value::binary-size(length), rest::binary>> = payload
    parse_request_values(rest, entries ++ [{tac, value}])
  end

  def handle(%Fm0{payload: payload} = request, %Context{user: user} = context) do
    Logger.debug("[profile] request packet: #{inspect(request, base: :hex, limit: :infinity)}")

    <<
      0x13,                           # pac
      action,                         # sac
      which_user,                     # 1 for same user as is logged in
      other_user_id::binary-size(7),  # if not same user, then user_id here
      filler::binary-size(5),         # some filler bytes
      _count::16-big,                 # number of tacs (tertiary action codes) requested
      rest::binary                    # the tertiary action codes
    >> = payload

    entries = parse_request_values(rest)

    Logger.debug("#{inspect(entries, base: :hex, limit: :infinity)}")

    # rest is in the form of:  << tac::16-little, length, value::binary-size(length) >>
    # parse it into a list of tuples in the form { tac, value }
    # then, the list will be passed into the retrieve or update method

    values =
      case action do
        # Retrieve; iterate over the length value, pulling out << tac::16-little, 0x0 >>
        0x03 ->
          Enum.reduce(entries, <<>>, fn entry, buf ->
            {tac, _val} = entry
            buf <> get_tac(tac, user, user.household)
          end)

        0x04 ->
          Logger.info("Profile update received for user #{user.id}")

          household_changeset = get_household_changeset(entries)

          user_changeset =
            Map.merge(get_user_changeset(entries), %{
              date_enrolled: Timex.today()
            })

          Repo.transaction(fn ->
            Repo.update(Household.changeset(user.household, household_changeset))
            Repo.update(User.changeset(user, user_changeset))
          end)

          payload
      end

    payload = <<
      0x13,
      action,
      which_user,
      other_user_id::binary-size(7),
      filler::binary-size(5),
      0x0::16-big,
      values::binary
    >>

    {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
  end
end
