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

defmodule Prodigy.Core.Data.Service.ProfileSchema do
  @moduledoc """
  Single source of truth for every Prodigy profile attribute - keyed by
  TAC (tertiary action code), with metadata that drives the TCS
  dispatch, the JSONB storage layer, and the admin UI.

  ## Sources

  The registry is populated from XXCGTSYS
  (`applications/common/XXCGTSYS`) which is the Reception System's
  authoritative field list through Driver 8+. Metadata not in XXCGTSYS
  (format / source / security) is pulled from the 1987 Galambos /
  Heinz / Rudin "User Profile Record with Clarifications" memo where
  it overlaps; fields added post-1987 or whose format had to be
  inferred from the name + length are marked `provisional: true` so
  we can audit them as we recover more applications.

  ## Field metadata

    * `:name` - XXCGTSYS symbol.
    * `:label` - human-readable display name for the admin UI.
    * `:entity` - `:user` | `:household`. Picks which record's JSONB
      profile column the value lives in. User-slot TACs (e.g.,
      `0x011A`) declare `:user` + `:slot`; the dispatch resolver
      targets the User row matching the suffix.
    * `:slot` - `"A"` .. `"F"`, or `nil`.
    * `:type` - `:ascii`, `:binary`, `:date_mmddyy`.
    * `:length` - byte count on the wire.
    * `:source` - `:tpf`, `:oms`, or `:both` (PDF's T/O/B column).
    * `:group` / `:group_label` / `:index` - admin-UI grouping.
      `XXOPPROF.PGM` expands groups client-side, so we never see
      group-level TACs on the wire.
    * `:security` - `%{retrieve: [...], update: [...]}` scope lists.
      Enforced by Tools / RBAC later.
    * `:storage` - `:jsonb` (default) or `:password_column`.
    * `:provisional` - `true` when the type / source / security was
      inferred rather than cross-referenced against the PDF. Drop the
      flag as each app recovery reveals the ground truth.
  """

  @type tac :: non_neg_integer()
  @type slot :: String.t() | nil
  @type type :: :ascii | :binary | :date_mmddyy
  @type source :: :tpf | :oms | :both
  @type scope :: :subscriber | :user | :oms

  @type field :: %{
          name: String.t(),
          label: String.t(),
          entity: :user | :household,
          slot: slot(),
          type: type(),
          length: non_neg_integer(),
          source: source(),
          group: atom() | nil,
          group_label: String.t() | nil,
          index: non_neg_integer() | nil,
          security: %{retrieve: [scope()], update: [scope()]},
          storage: :jsonb | :password_column,
          provisional: boolean()
        }

  @default_security %{retrieve: [:subscriber, :oms], update: [:subscriber, :oms]}
  @default_entry %{
    slot: nil,
    source: :tpf,
    group: nil,
    group_label: nil,
    index: nil,
    security: @default_security,
    storage: :jsonb,
    provisional: false
  }

  # -- patterned field groups -------------------------------------

  # Household user slots A-F (6 fields x 6 slots = 36 TACs). The first
  # element of each tuple is the slot letter; the map is field-name ->
  # slot-relative TAC.
  @user_slot_defs [
    {"A", %{last: 0x011A, first: 0x011B, middle: 0x011C, title: 0x011D, access_level: 0x011F, indicators: 0x0120}},
    {"B", %{last: 0x0123, first: 0x0124, middle: 0x0125, title: 0x0126, access_level: 0x0128, indicators: 0x0129}},
    {"C", %{last: 0x012C, first: 0x012D, middle: 0x012E, title: 0x012F, access_level: 0x0131, indicators: 0x0132}},
    {"D", %{last: 0x0135, first: 0x0136, middle: 0x0137, title: 0x0138, access_level: 0x013A, indicators: 0x013B}},
    {"E", %{last: 0x013E, first: 0x013F, middle: 0x0140, title: 0x0141, access_level: 0x0143, indicators: 0x0144}},
    {"F", %{last: 0x0147, first: 0x0148, middle: 0x0149, title: 0x014A, access_level: 0x014C, indicators: 0x014D}}
  ]

  # Slot field-name -> the user's *own* TAC for the same datum. Only
  # name/title have a per-member equivalent; access_level / indicators
  # have no user-own TAC and stay on the household's profile.
  @user_own_name_tac %{last: 0x015E, first: 0x015F, middle: 0x0160, title: 0x0161}

  @user_slots_fields (for {slot, slot_tacs} <- @user_slot_defs,
                          {field_key, tac} <- slot_tacs,
                          into: %{} do
    group = String.to_atom("user_slot_#{String.downcase(slot)}")

    {name, label, type, length, index} =
      case field_key do
        :last -> {"PRF_USER_ITEM_LAST_#{slot}", "Last Name", :ascii, 20, 0}
        :first -> {"PRF_USER_ITEM_FIRST_#{slot}", "First Name", :ascii, 15, 1}
        :middle -> {"PRF_USER_ITEM_MIDDLE_#{slot}", "Middle", :ascii, 1, 2}
        :title -> {"PRF_USER_ITEM_TITLE_#{slot}", "Title", :ascii, 5, 3}
        :access_level -> {"PRF_ACCESS_LEVEL_#{slot}", "Access Level", :binary, 3, 4}
        :indicators -> {"PRF_INDICATORS_#{slot}", "Indicators", :binary, 2, 5}
      end

    {tac,
     Map.merge(@default_entry, %{
       name: name,
       label: "User #{slot} #{label}",
       entity: :user,
       slot: slot,
       type: type,
       length: length,
       group: group,
       group_label: "User #{slot}",
       index: index
     })}
  end)

  # Slot field TAC -> {slot_letter, user_own_tac} for the slot fields
  # that have a per-member User-row equivalent (last/first/middle/title).
  @slot_member_tacs (for {slot, slot_tacs} <- @user_slot_defs,
                         {field_key, tac} <- slot_tacs,
                         Map.has_key?(@user_own_name_tac, field_key),
                         into: %{} do
    {tac, {slot, Map.fetch!(@user_own_name_tac, field_key)}}
  end)

  # Personal Path jumpwords 1-20. Non-contiguous: 1-12 at 0x023F-0x024A
  # (PDF sec 11 relocation), 13-20 at 0x020A-0x0211. XXCGTSYS says 13 chars
  # per jumpword (shorter than the PDF's Driver-7 25); the 1990 XXCGTSYS
  # is more recent and reflects actual RS practice.
  @personal_path_fields (for {tac, index} <- [
                               {0x023F, 0},
                               {0x0240, 1},
                               {0x0241, 2},
                               {0x0242, 3},
                               {0x0243, 4},
                               {0x0244, 5},
                               {0x0245, 6},
                               {0x0246, 7},
                               {0x0247, 8},
                               {0x0248, 9},
                               {0x0249, 10},
                               {0x024A, 11},
                               {0x020A, 12},
                               {0x020B, 13},
                               {0x020C, 14},
                               {0x020D, 15},
                               {0x020E, 16},
                               {0x020F, 17},
                               {0x0210, 18},
                               {0x0211, 19}
                             ],
                             into: %{} do
    {tac,
     Map.merge(@default_entry, %{
       name: "PRF_PERSONAL_PATH_JUMPWORD_#{index + 1}",
       label: "Personal Path #{index + 1}",
       entity: :user,
       type: :ascii,
       length: 13,
       group: :personal_path,
       group_label: "Personal Path",
       index: index,
       security: %{retrieve: [:user], update: [:user]}
     })}
  end)

  # Credit cards 1-4 x (number, exp, name).
  @credit_card_fields (for card_num <- 1..4,
                           {field_key, offset, label, type, length} <- [
                             {:number, 0, "Number", :ascii, 20},
                             {:exp, 1, "Expiration", :ascii, 4},
                             {:name, 2, "Cardholder Name", :ascii, 30}
                           ],
                           into: %{} do
    base = 0x0167 + (card_num - 1) * 3
    tac = base + offset
    group = String.to_atom("credit_card_#{card_num}")

    name =
      case field_key do
        :number -> "PRF_USER_CREDIT_CARD_NUMBER_#{String.pad_leading("#{card_num}", 2, "0")}"
        :exp -> "PRF_USER_CREDIT_CARD_EXP_#{String.pad_leading("#{card_num}", 2, "0")}"
        :name -> "PRF_USER_CREDIT_CARD_NAME_#{String.pad_leading("#{card_num}", 2, "0")}"
      end

    {tac,
     Map.merge(@default_entry, %{
       name: name,
       label: "Credit Card #{card_num} #{label}",
       entity: :user,
       type: type,
       length: length,
       source: :both,
       group: group,
       group_label: "Credit Card #{card_num}",
       index: offset,
       security: %{
         retrieve: [:subscriber, :user, :oms],
         update: [:subscriber, :user, :oms]
       }
     })}
  end)

  # Bank providers v1 (original 3-bank scheme): provider, gateway_id,
  # provider_user per bank.
  @bank_provider_v1_fields (for bank <- 1..3,
                                {field_key, offset, label, length} <- [
                                  {:provider, 0, "Provider", 1},
                                  {:gateway_id, 1, "Gateway ID", 3},
                                  {:provider_user, 2, "Provider User", 20}
                                ],
                                into: %{} do
    base = 0x0173 + (bank - 1) * 3
    tac = base + offset
    group = String.to_atom("bank_v1_#{bank}")

    name =
      case field_key do
        :provider -> "PRF_BANK_PROVIDER_#{String.pad_leading("#{bank}", 2, "0")}"
        :gateway_id -> "PRF_GATEWAY_ID_#{String.pad_leading("#{bank}", 2, "0")}"
        :provider_user -> "PRF_BANK_PROVIDER_USER_#{String.pad_leading("#{bank}", 2, "0")}"
      end

    {tac,
     Map.merge(@default_entry, %{
       name: name,
       label: "Bank #{bank} #{label}",
       entity: :user,
       type: :ascii,
       length: length,
       source: :both,
       group: group,
       group_label: "Bank #{bank}",
       index: offset,
       security: %{
         retrieve: [:subscriber, :user, :oms],
         update: [:subscriber, :user, :oms]
       }
     })}
  end)

  # Banking TACs v2 (Driver 8+, 5 banks x 10 fields each, sequential
  # starting at 0x02C5). Bank 3 skips #733 per the XXCGTSYS comment
  # ("Skipped intentionally") - we honor that gap so 0x02DD has no entry.
  @bank_v2_bank_layout [
    {:gateway_id, "Gateway ID", 1},
    {:bank_code, "Bank Code", 3},
    {:state_code, "State Code", 1},
    {:status_code, "Status Code", 1},
    {:enable_date, "Enable Date", 4},
    {:disable_date, "Disable Date", 4},
    {:bill_date, "Bill Date", 4},
    {:charge_code, "Charge Code", 2},
    {:bank_info1, "Bank Info 1", 6},
    {:bank_info2, "Bank Info 2", 6}
  ]

  @bank_v2_starting_tacs %{
    1 => 0x02C5,
    2 => 0x02CF,
    3 => 0x02D9,
    4 => 0x02E4,
    5 => 0x02EE
  }

  @bank_v2_fields (for bank <- 1..5,
                       {field_key, label, length} <- @bank_v2_bank_layout,
                       offset = Enum.find_index(@bank_v2_bank_layout, fn {k, _, _} -> k == field_key end),
                       # Bank 3 skips offset 4 (the "#733 Skipped intentionally" gap).
                       not (bank == 3 and offset == 4),
                       into: %{} do
    base = @bank_v2_starting_tacs[bank]
    # For bank 3, TACs past the skip shift up by one.
    tac =
      cond do
        bank == 3 and offset > 4 -> base + offset + 1
        true -> base + offset
      end

    group = String.to_atom("bank_v2_#{bank}")

    name_field =
      case field_key do
        :gateway_id -> "GATEWAY_ID"
        :bank_code -> "BANK_CODE"
        :state_code -> "STATE_CODE"
        :status_code -> "STATUS_CODE"
        :enable_date -> "ENABLE_DATE"
        :disable_date -> "DISABLE_DATE"
        :bill_date -> "BILL_DATE"
        :charge_code -> "CHARGE_CODE"
        :bank_info1 -> "BANK_INFO1"
        :bank_info2 -> "BANK_INFO2"
      end

    {tac,
     Map.merge(@default_entry, %{
       name: "PRF_BANK#{bank}_#{name_field}",
       label: "Bank #{bank} #{label}",
       entity: :user,
       type: :ascii,
       length: length,
       group: group,
       group_label: "Bank #{bank} (v2)",
       index: offset,
       provisional: true
     })}
  end)

  # Repeating 5-slot groups: direct marketing responses, leisure,
  # magazines, personalization, categories.
  @repeating_5_groups [
    {0x01A1, "PRF_RESPONSE_TYPE", "Direct Marketing Response", :direct_mktg_responses, 2},
    {0x01A7, "PRF_LEISURE_ACTIVITY", "Leisure Activity", :leisure_activities, 2},
    {0x024C, "PRF_MAGAZINE_SUBSCRIPTION", "Magazine Subscription", :magazine_subscriptions, 2},
    {0x0251, "PRF_PERSONALIZATION", "Personalization", :personalization, 10},
    {0x025E, "PRF_CATEGORY", "Category", :ingram_categories, 1}
  ]

  @repeating_5_fields (for {base, name_prefix, label_prefix, group, length} <- @repeating_5_groups,
                           i <- 0..4,
                           into: %{} do
    tac = base + i
    slot_num = i + 1

    {tac,
     Map.merge(@default_entry, %{
       name: "#{name_prefix}_#{String.pad_leading("#{slot_num}", 2, "0")}",
       label: "#{label_prefix} #{slot_num}",
       entity: :user,
       type: :ascii,
       length: length,
       group: group,
       group_label: label_prefix,
       index: i,
       provisional: true
     })}
  end)

  # Repeating 3-slot groups (Ingram sections).
  @repeating_3_groups [
    {0x0263, "PRF_GROUP", "Ingram Group", :ingram_groups, 3},
    {0x0266, "PRF_SECTION", "Ingram Section", :ingram_sections, 3}
  ]

  @repeating_3_fields (for {base, name_prefix, label_prefix, group, length} <- @repeating_3_groups,
                           i <- 0..2,
                           into: %{} do
    tac = base + i
    slot_num = i + 1

    {tac,
     Map.merge(@default_entry, %{
       name: "#{name_prefix}_#{String.pad_leading("#{slot_num}", 2, "0")}",
       label: "#{label_prefix} #{slot_num}",
       entity: :user,
       type: :ascii,
       length: length,
       group: group,
       group_label: label_prefix,
       index: i,
       provisional: true
     })}
  end)

  # -- singleton core entries ---------------------------------------

  @core_fields %{
    # Residence / Billing Address
    0x0102 =>
      Map.merge(@default_entry, %{
        name: "PRF_BA_FIRST_LINE",
        label: "Address Line 1",
        entity: :household,
        type: :ascii,
        length: 26,
        source: :both,
        group: :residence_address,
        group_label: "Residence Address",
        index: 0
      }),
    0x0103 =>
      Map.merge(@default_entry, %{
        name: "PRF_BA_2ND_LINE",
        label: "Address Line 2",
        entity: :household,
        type: :ascii,
        length: 26,
        source: :both,
        group: :residence_address,
        group_label: "Residence Address",
        index: 1
      }),
    0x0104 =>
      Map.merge(@default_entry, %{
        name: "PRF_BA_CITY",
        label: "City",
        entity: :household,
        type: :ascii,
        length: 18,
        source: :both,
        group: :residence_address,
        group_label: "Residence Address",
        index: 2
      }),
    0x0105 =>
      Map.merge(@default_entry, %{
        name: "PRF_BA_STATE",
        label: "State",
        entity: :household,
        type: :ascii,
        length: 2,
        source: :both,
        group: :residence_address,
        group_label: "Residence Address",
        index: 3
      }),
    0x0106 =>
      Map.merge(@default_entry, %{
        name: "PRF_BA_ZIPCODE",
        label: "ZIP",
        entity: :household,
        type: :ascii,
        length: 9,
        source: :both,
        group: :residence_address,
        group_label: "Residence Address",
        index: 4
      }),
    0x0107 =>
      Map.merge(@default_entry, %{
        name: "PRF_RES_TELEPHONE",
        label: "Residence Telephone",
        entity: :household,
        type: :ascii,
        length: 10,
        source: :both
      }),
    0x010E =>
      Map.merge(@default_entry, %{
        name: "PRF_ENABLED_DATE",
        label: "Household Enabled",
        entity: :household,
        type: :date_mmddyy,
        length: 6
      }),
    0x010F =>
      Map.merge(@default_entry, %{
        name: "PRF_DISABLED_DATE",
        label: "Household Disabled",
        entity: :household,
        type: :date_mmddyy,
        length: 6
      }),
    0x0110 =>
      Map.merge(@default_entry, %{
        name: "PRF_DISABLED_REASON",
        label: "Disabled Reason",
        entity: :household,
        type: :ascii,
        length: 1
      }),
    0x0111 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSEHOLD_USERID",
        label: "Household ID",
        entity: :household,
        type: :ascii,
        length: 6
      }),
    0x0112 =>
      Map.merge(@default_entry, %{
        name: "PRF_SUBSCRIBER_SUFFIX",
        label: "Subscriber Suffix",
        entity: :household,
        type: :ascii,
        length: 1,
        source: :both
      }),
    0x0113 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSEHOLD_PASSWORD",
        label: "Household Password",
        entity: :household,
        type: :ascii,
        length: 10,
        security: %{retrieve: [:subscriber], update: [:subscriber]}
      }),
    0x0114 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSEHOLD_INCM_RANGE_CODE",
        label: "Income Range Code",
        entity: :household,
        type: :ascii,
        length: 1,
        source: :both
      }),
    0x0115 =>
      Map.merge(@default_entry, %{
        name: "PRF_SUFFIX_IN_USE_INDICATORS",
        label: "Suffix-In-Use Indicators",
        entity: :household,
        type: :binary,
        length: 1
      }),
    0x0116 =>
      Map.merge(@default_entry, %{
        name: "PRF_ACCOUNT_STATUS_FLAG",
        label: "Account Status Flag",
        entity: :household,
        type: :binary,
        length: 1
      }),

    # User Profile record - core identity + session-time bookkeeping.
    0x014E =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_PROFILE_USER_ID",
        label: "User ID",
        entity: :user,
        type: :ascii,
        length: 7
      }),
    0x014F =>
      Map.merge(@default_entry, %{
        name: "PRF_PASSWORD",
        label: "Password",
        entity: :user,
        type: :ascii,
        length: 10,
        security: %{retrieve: [:user], update: [:user]},
        storage: :password_column
      }),
    0x0150 =>
      Map.merge(@default_entry, %{
        name: "PRF_REGION",
        label: "Region",
        entity: :user,
        type: :binary,
        length: 1,
        source: :both,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x0152 =>
      Map.merge(@default_entry, %{
        name: "PRF_MAIL_COUNT",
        label: "Mail Count",
        entity: :user,
        type: :binary,
        length: 1
      }),
    0x0153 =>
      Map.merge(@default_entry, %{
        name: "PRF_ACCESS_CONTROL",
        label: "Access Control (CUGs, TOS)",
        entity: :user,
        type: :binary,
        length: 3
      }),
    0x0154 =>
      Map.merge(@default_entry, %{
        name: "PRF_COUNT_PASSWORD_CHANGE_TRYS",
        label: "Password Change Try Count",
        entity: :user,
        type: :binary,
        length: 1
      }),
    0x0155 =>
      Map.merge(@default_entry, %{
        name: "PRF_PORT_INDEX_ID",
        label: "Port Index ID",
        entity: :user,
        type: :binary,
        length: 4
      }),
    0x0156 =>
      Map.merge(@default_entry, %{
        name: "PRF_INDIC_FOR_APPLICATION_USE",
        label: "Application-Use Indicators",
        entity: :user,
        type: :ascii,
        length: 1
      }),
    0x0157 =>
      Map.merge(@default_entry, %{
        name: "PRF_GENDER",
        label: "Gender",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :both,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x0159 =>
      Map.merge(@default_entry, %{
        name: "PRF_DATE_USER_WAS_ENROLLED",
        label: "Date Enrolled",
        entity: :user,
        type: :date_mmddyy,
        length: 6,
        source: :both
      }),
    0x015A =>
      Map.merge(@default_entry, %{
        name: "PRF_DATE_USER_WAS_DELETED",
        label: "Date Deleted",
        entity: :user,
        type: :date_mmddyy,
        length: 6,
        source: :both
      }),
    0x015B =>
      Map.merge(@default_entry, %{
        name: "PRF_REASON_FOR_DELETION",
        label: "Deletion Reason",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :both,
        provisional: true
      }),
    0x015C =>
      Map.merge(@default_entry, %{
        name: "PRF_SOURCE_OF_DELETE",
        label: "Deletion Source",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :both
      }),
    0x015E =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_LAST_NAME",
        label: "Last Name",
        entity: :user,
        type: :ascii,
        length: 20,
        source: :both,
        group: :user_name,
        group_label: "Name",
        index: 0,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x015F =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_FIRST_NAME",
        label: "First Name",
        entity: :user,
        type: :ascii,
        length: 15,
        source: :both,
        group: :user_name,
        group_label: "Name",
        index: 1,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x0160 =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_MIDDLE_NAME",
        label: "Middle Name",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :both,
        group: :user_name,
        group_label: "Name",
        index: 2,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x0161 =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_TITLE",
        label: "Title",
        entity: :user,
        type: :ascii,
        length: 5,
        source: :both,
        group: :user_name,
        group_label: "Name",
        index: 3,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x0162 =>
      Map.merge(@default_entry, %{
        name: "PRF_DATE_OF_BIRTH",
        label: "Date of Birth",
        entity: :user,
        type: :date_mmddyy,
        length: 6,
        source: :both,
        security: %{
          retrieve: [:subscriber, :user, :oms],
          update: [:subscriber, :user, :oms]
        }
      }),
    0x0163 =>
      Map.merge(@default_entry, %{
        name: "PRF_PREFERRED_SHOP_CARD",
        label: "Preferred Shopping Card",
        entity: :user,
        type: :binary,
        length: 1,
        source: :both
      }),
    0x0164 =>
      Map.merge(@default_entry, %{
        name: "PRF_PREFERRED_TRAVEL_CARD",
        label: "Preferred Travel Card",
        entity: :user,
        type: :binary,
        length: 1,
        source: :both
      }),
    0x0166 =>
      Map.merge(@default_entry, %{
        name: "PRF_MARITAL_STATUS",
        label: "Marital Status",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :both
      }),

    # Travel (individual fields)
    0x0183 =>
      Map.merge(@default_entry, %{
        name: "PRF_AA_ADVANTAGE_NUMBER",
        label: "AA Advantage Number",
        entity: :user,
        type: :ascii,
        length: 10,
        source: :both,
        provisional: true
      }),
    0x0186 =>
      Map.merge(@default_entry, %{
        name: "PRF_SEAT_CODE",
        label: "Seat Code",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :both,
        provisional: true
      }),
    0x018A =>
      Map.merge(@default_entry, %{
        name: "PRF_TRAVEL_AGENT_CODE",
        label: "Travel Agent Code",
        entity: :user,
        type: :ascii,
        length: 3,
        source: :both,
        provisional: true
      }),
    0x018B =>
      Map.merge(@default_entry, %{
        name: "PRF_PRFRD_TRAVEL_AGENT_INDIC",
        label: "Preferred Travel Agent Indicator",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :both,
        provisional: true
      }),

    # Hardware
    0x0196 =>
      Map.merge(@default_entry, %{
        name: "PRF_PC_MAKE_MODEL",
        label: "PC Make/Model",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :oms,
        group: :hardware,
        group_label: "Hardware",
        index: 0,
        provisional: true
      }),
    0x0197 =>
      Map.merge(@default_entry, %{
        name: "PRF_MONITOR_MAKE_MODEL",
        label: "Monitor Make/Model",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :oms,
        group: :hardware,
        group_label: "Hardware",
        index: 1,
        provisional: true
      }),
    0x0198 =>
      Map.merge(@default_entry, %{
        name: "PRF_MODEM_MAKE_MODEL",
        label: "Modem Make/Model",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :oms,
        group: :hardware,
        group_label: "Hardware",
        index: 2,
        provisional: true
      }),
    0x0199 =>
      Map.merge(@default_entry, %{
        name: "PRF_PRINTER_MAKE_MODEL",
        label: "Printer Make/Model",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :oms,
        group: :hardware,
        group_label: "Hardware",
        index: 3,
        provisional: true
      }),
    0x01AC =>
      Map.merge(@default_entry, %{
        name: "PRF_NUTRITION_DIET_INFO_FLAGS",
        label: "Nutrition / Diet Flags",
        entity: :user,
        type: :binary,
        length: 2,
        source: :oms,
        provisional: true
      }),
    0x01B4 =>
      Map.merge(@default_entry, %{
        name: "PRF_MAIL_PURCHASE_PAST_YEAR",
        label: "Mail Purchases Past Year",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :oms,
        provisional: true
      }),
    0x01E5 =>
      Map.merge(@default_entry, %{
        name: "PRF_EDUCATION_CODE",
        label: "Education Code",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :oms,
        provisional: true
      }),
    0x01F0 =>
      Map.merge(@default_entry, %{
        name: "PRF_R_GROUP_CODE",
        label: "R-Group Code",
        entity: :user,
        type: :ascii,
        length: 2,
        source: :oms,
        provisional: true
      }),
    0x01F1 =>
      Map.merge(@default_entry, %{
        name: "PRF_TYPE_OF_HOUSING",
        label: "Housing Type",
        entity: :user,
        type: :ascii,
        length: 1,
        source: :oms,
        provisional: true
      }),
    0x01FD =>
      Map.merge(@default_entry, %{
        name: "PRF_INDUSTRY",
        label: "Industry",
        entity: :user,
        type: :ascii,
        length: 5,
        source: :oms,
        provisional: true
      }),

    # Misc user profile (Driver 7 new-TAC block)
    0x0226 =>
      Map.merge(@default_entry, %{
        name: "PRF_AIRLINE_MEAL_PREFERENCE",
        label: "Airline Meal Preference",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0227 =>
      Map.merge(@default_entry, %{
        name: "PRF_EAASY_SABRE_PASSWORD",
        label: "EAASY Sabre Password",
        entity: :user,
        type: :ascii,
        length: 10,
        security: %{retrieve: [:subscriber, :user], update: [:subscriber, :user]},
        provisional: true
      }),
    0x0228 =>
      Map.merge(@default_entry, %{
        name: "PRF_AUTO_SKIP",
        label: "Auto Skip",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x022B =>
      Map.merge(@default_entry, %{
        name: "PRF_KEYSTROKE_BUFFER",
        label: "Keystroke Buffer",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x022F =>
      Map.merge(@default_entry, %{
        name: "PRF_SOUND",
        label: "Sound",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0232 =>
      Map.merge(@default_entry, %{
        name: "PRF_USAGE_LEVEL",
        label: "Usage Level",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0233 =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_ACCESS_TO_FULLFILL",
        label: "Fulfillment Access",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0234 =>
      Map.merge(@default_entry, %{
        name: "PRF_RESELLER_NUMBER",
        label: "Reseller Number (Ingram)",
        entity: :user,
        type: :ascii,
        length: 6,
        group: :reseller,
        group_label: "Reseller",
        index: 0,
        provisional: true
      }),
    0x0235 =>
      Map.merge(@default_entry, %{
        name: "PRF_RESELLER_NAME",
        label: "Reseller Name",
        entity: :user,
        type: :ascii,
        length: 40,
        group: :reseller,
        group_label: "Reseller",
        index: 1,
        provisional: true
      }),
    0x0236 =>
      Map.merge(@default_entry, %{
        name: "PRF_RESELLER_CLASS",
        label: "Reseller Class",
        entity: :user,
        type: :ascii,
        length: 1,
        group: :reseller,
        group_label: "Reseller",
        index: 2,
        provisional: true
      }),
    0x0237 =>
      Map.merge(@default_entry, %{
        name: "PRF_RESELLER_TYPE",
        label: "Reseller Type",
        entity: :user,
        type: :ascii,
        length: 1,
        group: :reseller,
        group_label: "Reseller",
        index: 3,
        provisional: true
      }),
    0x0238 =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_CLASS",
        label: "User Class",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0239 =>
      Map.merge(@default_entry, %{
        name: "PRF_BUS_CLIENT_CODE",
        label: "Business Client Code",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x023A =>
      Map.merge(@default_entry, %{
        name: "PRF_USER_SECURITY_LEVEL",
        label: "User Security Level",
        entity: :user,
        type: :binary,
        length: 1,
        provisional: true
      }),
    0x023B =>
      Map.merge(@default_entry, %{
        name: "PRF_PERCENT_DISCOUNT",
        label: "Percent Discount",
        entity: :user,
        type: :ascii,
        length: 6,
        provisional: true
      }),
    0x023D =>
      Map.merge(@default_entry, %{
        name: "PRF_GAME_PROFILE",
        label: "Game Profile",
        entity: :user,
        type: :binary,
        length: 1,
        provisional: true
      }),
    0x023E =>
      Map.merge(@default_entry, %{
        name: "PRF_PREFERRED_TRAVEL_AGENT",
        label: "Preferred Travel Agent",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x024B =>
      Map.merge(@default_entry, %{
        name: "PRF_ACCOUNT_STATUS",
        label: "Account Status",
        entity: :user,
        type: :binary,
        length: 1,
        provisional: true
      }),

    # Ingram / commerce fields
    0x0256 =>
      Map.merge(@default_entry, %{
        name: "PRF_BUYER_CODE",
        label: "Buyer Code",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0257 =>
      Map.merge(@default_entry, %{
        name: "PRF_CREDIT_RATING",
        label: "Credit Rating",
        entity: :user,
        type: :ascii,
        length: 3,
        provisional: true
      }),
    0x0258 =>
      Map.merge(@default_entry, %{
        name: "PRF_ACCT_REC_BAL",
        label: "A/R Balance",
        entity: :user,
        type: :ascii,
        length: 10,
        provisional: true
      }),
    0x0259 =>
      Map.merge(@default_entry, %{
        name: "PRF_AMOUNT_ORDERED_TODAY",
        label: "Amount Ordered Today",
        entity: :user,
        type: :ascii,
        length: 10,
        provisional: true
      }),
    0x025A =>
      Map.merge(@default_entry, %{
        name: "PRF_CREDIT_LIMIT",
        label: "Credit Limit",
        entity: :user,
        type: :ascii,
        length: 10,
        provisional: true
      }),
    0x025B =>
      Map.merge(@default_entry, %{
        name: "PRF_PREFERRED_CUSTOMER",
        label: "Preferred Customer",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x025C =>
      Map.merge(@default_entry, %{
        name: "PRF_NEW_NAME",
        label: "New Name",
        entity: :user,
        type: :ascii,
        length: 10,
        provisional: true
      }),
    0x025D =>
      Map.merge(@default_entry, %{
        name: "PRF_CUG_ACCT_NUM",
        label: "CUG Account Number",
        entity: :user,
        type: :ascii,
        length: 20,
        provisional: true
      }),
    0x0269 =>
      Map.merge(@default_entry, %{
        name: "PRF_PREVIEW_HELP",
        label: "Preview Help",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),

    # Household-side Driver 8 additions
    0x026A =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_BILL_REF_NUM",
        label: "Household Bill Reference",
        entity: :household,
        type: :ascii,
        length: 10,
        provisional: true
      }),
    0x026B =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_CUG_ID",
        label: "Household CUG ID",
        entity: :household,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x026C =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_SERVICE_ID",
        label: "Household Service ID",
        entity: :household,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x026D =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_EXP_DATE",
        label: "Household Expiration Date",
        entity: :household,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x026E =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_GRAPH_ADAPTER",
        label: "Household Graph Adapter",
        entity: :household,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x026F =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_MSG_MEM_CLASS",
        label: "Household Msg Mem Class",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0270 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_OBJ_MEM_CLASS",
        label: "Household Obj Mem Class",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0271 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_GRAPH_ADAPTER_SC",
        label: "Household Graph Adapter Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0272 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_PC_MAKE_SC",
        label: "Household PC Make Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0273 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_MODEM_SC",
        label: "Household Modem Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0274 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_MONITOR_SC",
        label: "Household Monitor Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0275 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_PRINTER_SC",
        label: "Household Printer Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0276 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_INCOME_SC",
        label: "Household Income Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0277 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_RES_PHONE",
        label: "Household Res Phone",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0278 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_R_GROUP_SC",
        label: "Household R-Group Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0279 =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_S_GROUP_SC",
        label: "Household S-Group Source",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x027A =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_TYPE",
        label: "Household Type",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x027B =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_USE_LEVEL",
        label: "Household Use Level",
        entity: :household,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x027C =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_VERSION",
        label: "Household Version",
        entity: :household,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x027D =>
      Map.merge(@default_entry, %{
        name: "PRF_S_GROUP_CODE",
        label: "S-Group Code",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x027E =>
      Map.merge(@default_entry, %{
        name: "PRF_HOUSE_USER_CLASS",
        label: "Household User Class",
        entity: :household,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x027F =>
      Map.merge(@default_entry, %{
        name: "PRF_TIER_01_ENROLL_DATE",
        label: "Tier 1 Enrollment Date",
        entity: :user,
        type: :ascii,
        length: 8,
        provisional: true
      }),

    # Broker / trading
    0x0280 =>
      Map.merge(@default_entry, %{
        name: "PRF_ACTIVE_TRADER",
        label: "Active Trader",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0281 =>
      Map.merge(@default_entry, %{
        name: "PRF_BROKER_ACCOUNT",
        label: "Broker Account",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0282 =>
      Map.merge(@default_entry, %{
        name: "PRF_BROKER_MEMBER",
        label: "Broker Member",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0283 =>
      Map.merge(@default_entry, %{
        name: "PRF_CUG_SERVICE_ID",
        label: "CUG Service ID",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),

    # Campaign / promotion
    0x0284 =>
      Map.merge(@default_entry, %{
        name: "PRF_CAMPAIGN_CODE",
        label: "Campaign Code",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x0285 =>
      Map.merge(@default_entry, %{
        name: "PRF_FAST_PATH_FULFILL",
        label: "Fast-Path Fulfillment",
        entity: :user,
        type: :ascii,
        length: 10,
        provisional: true
      }),
    0x0286 =>
      Map.merge(@default_entry, %{
        name: "PRF_UNIQUE_IDENTIFIER",
        label: "Unique Identifier",
        entity: :user,
        type: :ascii,
        length: 20,
        provisional: true
      }),
    0x0287 =>
      Map.merge(@default_entry, %{
        name: "PRF_MSG_MEM_CLASS",
        label: "User Msg Mem Class",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0288 =>
      Map.merge(@default_entry, %{
        name: "PRF_OBJ_MEM_CLASS",
        label: "User Obj Mem Class",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0289 =>
      Map.merge(@default_entry, %{
        name: "PRF_OCCUP_CODE",
        label: "Occupation Code",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x028A =>
      Map.merge(@default_entry, %{
        name: "PRF_PROMO_DATE",
        label: "Promotion Date",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x028B =>
      Map.merge(@default_entry, %{
        name: "PRF_PROMO_OFFER_CODE",
        label: "Promotion Offer Code",
        entity: :user,
        type: :ascii,
        length: 20,
        provisional: true
      }),
    0x028C =>
      Map.merge(@default_entry, %{
        name: "PRF_PROMO_RESP_METHOD",
        label: "Promotion Response Method",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x028D =>
      Map.merge(@default_entry, %{
        name: "PRF_PROMO_RESP_TYPE",
        label: "Promotion Response Type",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),

    # "_SC" (source code) fields indicating provenance of other fields
    0x028E =>
      Map.merge(@default_entry, %{
        name: "PRF_DATE_OF_BIRTH_SC",
        label: "Date of Birth Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x028F =>
      Map.merge(@default_entry, %{
        name: "PRF_EDUCATION_CODE_SC",
        label: "Education Code Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0290 =>
      Map.merge(@default_entry, %{
        name: "PRF_GENDER_SC",
        label: "Gender Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0291 =>
      Map.merge(@default_entry, %{
        name: "PRF_INDUSTRY_CODE_SC",
        label: "Industry Code Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0292 =>
      Map.merge(@default_entry, %{
        name: "PRF_OCCUPATION_CODE_SC",
        label: "Occupation Code Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0293 =>
      Map.merge(@default_entry, %{
        name: "PRF_MARITIAL_STATUS_SC",
        label: "Marital Status Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0294 =>
      Map.merge(@default_entry, %{
        name: "PRF_MAIL_PURCHASE_SC",
        label: "Mail Purchase Source",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0295 =>
      Map.merge(@default_entry, %{
        name: "PRF_SIGNATURE_ON_FILE",
        label: "Signature on File",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x0296 =>
      Map.merge(@default_entry, %{
        name: "PRF_TRAVEL_TEL_NUM",
        label: "Travel Telephone",
        entity: :user,
        type: :ascii,
        length: 14,
        provisional: true
      }),

    # Travel card billing address
    0x0297 =>
      Map.merge(@default_entry, %{
        name: "PRF_TC_BA_FIRST_LINE",
        label: "Travel Card Line 1",
        entity: :user,
        type: :ascii,
        length: 26,
        group: :travel_card_billing_address,
        group_label: "Travel Card Billing Address",
        index: 0,
        provisional: true
      }),
    0x0298 =>
      Map.merge(@default_entry, %{
        name: "PRF_TC_BA_2ND_LINE",
        label: "Travel Card Line 2",
        entity: :user,
        type: :ascii,
        length: 26,
        group: :travel_card_billing_address,
        group_label: "Travel Card Billing Address",
        index: 1,
        provisional: true
      }),
    0x0299 =>
      Map.merge(@default_entry, %{
        name: "PRF_TC_BA_CITY",
        label: "Travel Card City",
        entity: :user,
        type: :ascii,
        length: 18,
        group: :travel_card_billing_address,
        group_label: "Travel Card Billing Address",
        index: 2,
        provisional: true
      }),
    0x029A =>
      Map.merge(@default_entry, %{
        name: "PRF_TC_BA_STATE",
        label: "Travel Card State",
        entity: :user,
        type: :ascii,
        length: 2,
        group: :travel_card_billing_address,
        group_label: "Travel Card Billing Address",
        index: 3,
        provisional: true
      }),
    0x029B =>
      Map.merge(@default_entry, %{
        name: "PRF_TC_BA_ZIPCODE",
        label: "Travel Card ZIP",
        entity: :user,
        type: :ascii,
        length: 9,
        group: :travel_card_billing_address,
        group_label: "Travel Card Billing Address",
        index: 4,
        provisional: true
      }),
    0x029C =>
      Map.merge(@default_entry, %{
        name: "PRF_VERSION",
        label: "Version",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),

    # Legacy banking enable/disable pairs (pre bank-v2 TAC block)
    0x029D =>
      Map.merge(@default_entry, %{
        name: "PRF_BANK_01_ENABLED",
        label: "Bank 1 Enabled",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x029E =>
      Map.merge(@default_entry, %{
        name: "PRF_BANK_01_DISABLED",
        label: "Bank 1 Disabled",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x029F =>
      Map.merge(@default_entry, %{
        name: "PRF_BANK_02_ENABLED",
        label: "Bank 2 Enabled",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x02A0 =>
      Map.merge(@default_entry, %{
        name: "PRF_BANK_02_DISABLED",
        label: "Bank 2 Disabled",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x02A1 =>
      Map.merge(@default_entry, %{
        name: "PRF_BANK_03_ENABLED",
        label: "Bank 3 Enabled",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x02A2 =>
      Map.merge(@default_entry, %{
        name: "PRF_BANK_03_DISABLED",
        label: "Bank 3 Disabled",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x02A3 =>
      Map.merge(@default_entry, %{
        name: "PRF_PASSPORT",
        label: "Passport",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x02A4 =>
      Map.merge(@default_entry, %{
        name: "PRF_GROCERY_PTR",
        label: "Grocery Pointer",
        entity: :user,
        type: :ascii,
        length: 4,
        provisional: true
      }),
    0x02A5 =>
      Map.merge(@default_entry, %{
        name: "PRF_ASK_EXPERT",
        label: "Ask Expert",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x02A6 =>
      Map.merge(@default_entry, %{
        name: "PRF_CUG_ID",
        label: "CUG ID",
        entity: :user,
        type: :ascii,
        length: 2,
        provisional: true
      }),
    0x02A7 =>
      Map.merge(@default_entry, %{
        name: "PRF_DRIVER_LIC_STATE",
        label: "Driver License State",
        entity: :user,
        type: :ascii,
        length: 2,
        group: :driver_license,
        group_label: "Driver License",
        index: 0,
        provisional: true
      }),
    0x02A8 =>
      Map.merge(@default_entry, %{
        name: "PRF_DRIVER_LIC_NUM",
        label: "Driver License Number",
        entity: :user,
        type: :ascii,
        length: 25,
        group: :driver_license,
        group_label: "Driver License",
        index: 1,
        provisional: true
      }),
    0x02A9 =>
      Map.merge(@default_entry, %{
        name: "PRF_PAYMENT_CODE",
        label: "Payment Code",
        entity: :user,
        type: :ascii,
        length: 1,
        provisional: true
      }),
    0x02AA =>
      Map.merge(@default_entry, %{
        name: "PRF_PAYMENT_TEXT",
        label: "Payment Text",
        entity: :user,
        type: :ascii,
        length: 20,
        provisional: true
      }),
    0x02AB =>
      Map.merge(@default_entry, %{
        name: "PRF_GROCERY_CONTACT_PHONE",
        label: "Grocery Contact Phone",
        entity: :user,
        type: :ascii,
        length: 10,
        group: :grocery,
        group_label: "Grocery",
        index: 0,
        provisional: true
      }),
    0x02AC =>
      Map.merge(@default_entry, %{
        name: "PRF_GROCERY_ITEM_COUNT",
        label: "Grocery Item Count",
        entity: :user,
        type: :ascii,
        length: 1,
        group: :grocery,
        group_label: "Grocery",
        index: 1,
        provisional: true
      }),
    0x02AD =>
      Map.merge(@default_entry, %{
        name: "PRF_GROCERY_STORE_REF_NUM",
        label: "Grocery Store Ref",
        entity: :user,
        type: :ascii,
        length: 4,
        group: :grocery,
        group_label: "Grocery",
        index: 2,
        provisional: true
      }),
    0x02AE =>
      Map.merge(@default_entry, %{
        name: "PRF_GROCERY_MEMBER_STATUS",
        label: "Grocery Member Status",
        entity: :user,
        type: :ascii,
        length: 2,
        group: :grocery,
        group_label: "Grocery",
        index: 3,
        provisional: true
      }),

    # Member Locator
    0x02AF =>
      Map.merge(@default_entry, %{
        name: "PRF_ML_DATE",
        label: "Member Locator Date",
        entity: :user,
        type: :ascii,
        length: 8,
        group: :member_locator,
        group_label: "Member Locator",
        index: 0,
        provisional: true
      }),
    0x02B0 =>
      Map.merge(@default_entry, %{
        name: "PRF_ML_INDICATOR",
        label: "Member Locator Indicator",
        entity: :user,
        # :binary, not :ascii - this is a 1-byte flag where 0x00 is a
        # valid "not in member list" value, and jsonb text cannot carry
        # \u0000. Previously declared :ascii, which crashed the session
        # on "remove yourself from the Member List" (2026-04-19). See
        # `project_profile_schema_ascii_audit.md` - several other
        # length-1 :ascii entries likely have the same latent bug.
        type: :binary,
        length: 1,
        group: :member_locator,
        group_label: "Member Locator",
        index: 1,
        provisional: true
      }),

    # Business Services at login
    0x02B7 =>
      Map.merge(@default_entry, %{
        name: "PRF_TIER_OF_SERVICE",
        label: "Tier of Service",
        entity: :user,
        type: :binary,
        length: 2,
        provisional: true
      }),
    0x02B8 =>
      Map.merge(@default_entry, %{
        name: "PRF_CCL_VERSION_NUM",
        label: "CCL Version Number",
        entity: :user,
        type: :binary,
        length: 2,
        provisional: true
      }),

    # Selection / shopping list
    0x02BA =>
      Map.merge(@default_entry, %{
        name: "PRF_SEL_STATUS",
        label: "Selection Status",
        entity: :user,
        type: :binary,
        length: 1,
        provisional: true
      }),
    0x02BB =>
      Map.merge(@default_entry, %{
        name: "PRF_SEL_NUM_ITEMS",
        label: "Selection Item Count",
        entity: :user,
        type: :binary,
        length: 2,
        provisional: true
      }),
    0x02BC =>
      Map.merge(@default_entry, %{
        name: "PRF_SEL_ITEM_LIST",
        label: "Selection Item List",
        entity: :user,
        type: :binary,
        length: 200,
        provisional: true
      }),
    0x02BD =>
      Map.merge(@default_entry, %{
        name: "PRF_SAVED_ORDER_DATE",
        label: "Saved Order Date",
        entity: :user,
        type: :ascii,
        length: 10,
        group: :saved_order,
        group_label: "Saved Order",
        index: 0,
        provisional: true
      }),
    0x02BE =>
      Map.merge(@default_entry, %{
        name: "PRF_SAVED_ORDER_STORE_NO",
        label: "Saved Order Store No",
        entity: :user,
        type: :ascii,
        length: 4,
        group: :saved_order,
        group_label: "Saved Order",
        index: 1,
        provisional: true
      }),
    0x02BF =>
      Map.merge(@default_entry, %{
        name: "PRF_SAVED_ORDER_PTR",
        label: "Saved Order Pointer",
        entity: :user,
        type: :ascii,
        length: 4,
        group: :saved_order,
        group_label: "Saved Order",
        index: 2,
        provisional: true
      }),

    # Session bookkeeping written by Logoff.
    0x02C2 =>
      Map.merge(@default_entry, %{
        name: "PRF_LAST_LOGON_DATE",
        label: "Last Logon Date",
        entity: :user,
        type: :ascii,
        length: 8
      }),
    0x02C4 =>
      Map.merge(@default_entry, %{
        name: "PRF_LAST_LOGON_TIME",
        label: "Last Logon Time",
        entity: :user,
        type: :ascii,
        length: 5
      }),

    # Game state
    0x02FB =>
      Map.merge(@default_entry, %{
        name: "PRF_MADMAZE_SAVE",
        label: "MadMaze Save State",
        entity: :user,
        type: :binary,
        length: 26
      }),
    0x02FE =>
      Map.merge(@default_entry, %{
        name: "PRF_MESSAGING_OPTIONS_FLD",
        label: "Messaging Options",
        entity: :user,
        type: :binary,
        length: 8,
        provisional: true
      }),
    0x02FF =>
      Map.merge(@default_entry, %{
        name: "PRF_AUTOLOGON_NICKNAME",
        label: "Autologon Nickname",
        entity: :user,
        type: :ascii,
        length: 8,
        provisional: true
      })
  }

  # Assemble the final map. Order of merges matters only if TACs collide
  # (which they shouldn't); later keys win.
  @fields @core_fields
          |> Map.merge(@user_slots_fields)
          |> Map.merge(@personal_path_fields)
          |> Map.merge(@credit_card_fields)
          |> Map.merge(@bank_provider_v1_fields)
          |> Map.merge(@bank_v2_fields)
          |> Map.merge(@repeating_5_fields)
          |> Map.merge(@repeating_3_fields)

  # -- public API ------------------------------------------------

  @doc "Full map of TAC -> field metadata."
  @spec all() :: %{tac() => field()}
  def all, do: @fields

  @doc """
  Fetch metadata for a single TAC. Returns `nil` for unknown TACs -
  callers decide whether to log-and-skip or reject per the plan's
  "strict on write, lenient on read" policy.
  """
  @spec get(tac()) :: field() | nil
  def get(tac) when is_integer(tac), do: Map.get(@fields, tac)

  @doc "True iff `tac` has a registry entry."
  @spec known?(tac()) :: boolean()
  def known?(tac) when is_integer(tac), do: Map.has_key?(@fields, tac)

  @doc """
  For a household user-slot field TAC that has a per-member User-row
  equivalent (last/first/middle/title - 0x011A..0x011D for slot A,
  0x0123..0x0126 for B, etc.), returns `{slot_letter, user_own_tac}`
  where `user_own_tac` is that member's own profile TAC for the datum
  (0x015E last, 0x015F first, 0x0160 middle, 0x0161 title). Returns
  `nil` for any other TAC - including the access_level / indicators
  slot TACs, which have no user-own equivalent and stay on the
  household.
  """
  @spec slot_member_tac(tac()) :: {String.t(), tac()} | nil
  def slot_member_tac(tac) when is_integer(tac), do: Map.get(@slot_member_tacs, tac)

  @doc "All TACs that target a given entity."
  @spec by_entity(:user | :household) :: %{tac() => field()}
  def by_entity(entity) when entity in [:user, :household] do
    :maps.filter(fn _tac, %{entity: e} -> e == entity end, @fields)
  end

  @doc """
  All TACs that target a given household slot (`\"A\"` .. `\"F\"`).
  Only entries with a non-nil `:slot` appear.
  """
  @spec by_slot(String.t()) :: %{tac() => field()}
  def by_slot(slot) when is_binary(slot) do
    :maps.filter(fn _tac, %{slot: s} -> s == slot end, @fields)
  end

  @doc "All TACs in a given logical group, ordered by `:index`."
  @spec by_group(atom()) :: [{tac(), field()}]
  def by_group(group) when is_atom(group) do
    @fields
    |> Enum.filter(fn {_tac, %{group: g}} -> g == group end)
    |> Enum.sort_by(fn {_tac, %{index: i}} -> i || 0 end)
  end

  @doc "All registered TACs, sorted ascending."
  @spec tacs() :: [tac()]
  def tacs, do: @fields |> Map.keys() |> Enum.sort()

  @doc """
  The string key under which a TAC is stored in the JSONB `profile`
  map - upper-case 4-char hex with no prefix, matching the encoding
  `Prodigy.Core.Data.Service.ProfileDispatch` writes. Convenience for
  callers that reach directly into `profile` without going through
  the dispatch layer (e.g., the session-bookkeeping writes in
  `Prodigy.Server.Service.Logoff`).
  """
  @spec jsonb_key(tac()) :: String.t()
  def jsonb_key(tac) when is_integer(tac) do
    tac
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
    |> String.upcase()
  end

  @doc """
  All TACs currently flagged `provisional: true` - entries whose
  type / source / security were inferred from XXCGTSYS rather than
  cross-referenced against the PDF. Drop the flag as applications are
  recovered and the ground truth becomes clear.
  """
  @spec provisional() :: %{tac() => field()}
  def provisional do
    :maps.filter(fn _tac, %{provisional: p} -> p end, @fields)
  end
end
