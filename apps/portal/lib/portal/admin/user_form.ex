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

defmodule Prodigy.Portal.Admin.UserForm do
  @moduledoc """
  Form-only view model for the admin Users-tab edit modal. The service
  `User` and `Household` schemas don't cast the name/title/address/
  jumpword columns - those live in each entity's JSONB `profile` map
  keyed by TAC. This module is the thin layer that lets the LiveView
  keep doing `<.input field={f[:first_name]}>` etc. without coupling
  back to the removed columns.

  The form layout is declared as data in `@layout` and drives both the
  embedded schema and the template. Each field spec carries `entity`
  (`:user` or `:household`) so `profile_patch/1` returns two patches
  the caller applies to the correct JSONB map.

  * `from_user/1` - derive a form struct from a User (with preloaded
    household), sourcing values via the JSONB-backed accessors so the
    initial render is correct regardless of whether a field was
    written through admin, wire, or enrollment paths.
  * `changeset/2` - ordinary Ecto changeset over the embedded schema;
    runs a number validation on `concurrency_limit` plus a per-TAC
    max-length check.
  * `profile_patch/1` - returns `%{user: user_patch, household:
    household_patch}` keyed by TAC hex strings (with `:__delete__` for
    cleared fields).
  * `layout/0` - the ordered list of tabs the template renders.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Prodigy.Core.Data.Service.{Household, ProfileBackfill, ProfileSchema, User}

  # --- layout + field catalog ----------------------------------------

  @title_options ~w(Mr. Mrs. Ms. Dr. Miss)
  @gender_options [{"(unspecified)", ""}, {"Male", "M"}, {"Female", "F"}]

  @path_tacs (for n <- 1..20 do
                cond do
                  n <= 12 -> {n, 0x023F + (n - 1)}
                  true -> {n, 0x020A + (n - 13)}
                end
              end)

  @layout [
    %{
      id: :info,
      tab: "Personal info",
      groups: [
        %{
          title: "Status",
          fields: [
            %{
              label: "Enrolled",
              type: :readonly,
              source: :user,
              value_fn: &__MODULE__.format_enrolled/1
            },
            %{
              label: "Last logon",
              type: :readonly,
              source: :user,
              value_fn: &__MODULE__.format_last_logon/1
            }
          ]
        },
        %{
          title: "Name",
          fields: [
            # Grouped rendering - the three underlying fields each keep
            # their own schema field + TAC (expanded below into
            # @all_fields for cast/patch), but render as one horizontal
            # row under a single "Name" label so the edit modal fits on
            # a laptop.
            %{
              type: :name_row,
              label: "Name",
              entity: :user,
              subfields: [
                %{field: :first_name, tac: 0x015F, placeholder: "First"},
                %{field: :middle_name, tac: 0x0160, placeholder: "M", maxlength: 1},
                %{field: :last_name, tac: 0x015E, placeholder: "Last"}
              ]
            },
            %{
              field: :title,
              label: "Title",
              type: :select,
              tac: 0x0161,
              entity: :user,
              prompt: "(none)",
              options: @title_options
            }
          ]
        },
        %{
          title: "Personal details",
          fields: [
            %{
              field: :gender,
              label: "Gender",
              type: :select,
              tac: 0x0157,
              entity: :user,
              options: @gender_options
            },
            %{field: :birthdate, label: "Birthdate", type: :date, tac: 0x0162, entity: :user}
          ]
        },
        %{
          title: "Account",
          fields: [
            %{
              field: :concurrency_limit,
              label: "Concurrency limit",
              type: :number,
              min: 0,
              tac: nil,
              entity: :user
            }
          ]
        },
        %{
          title: "Member List",
          fields: [
            # tac: nil keeps this out of the generic build_patch flow;
            # profile_patch/1 writes 0x02B0 + 0x02AF together (mirroring
            # MSPLADD1/MSPLDEL1 in TBOL).
            %{
              field: :in_member_list,
              label: "Listed in Member List",
              type: :checkbox,
              tac: nil,
              entity: :user
            },
            %{
              label: "Last change",
              type: :readonly,
              source: :user,
              value_fn: &__MODULE__.format_member_list_date/1
            }
          ]
        }
      ]
    },
    %{
      id: :household,
      tab: "Household info",
      groups: [
        %{
          title: "Status",
          fields: [
            %{
              label: "Enabled",
              type: :readonly,
              source: :household,
              value_fn: &__MODULE__.format_enabled/1
            }
          ]
        },
        %{
          title: "Address",
          fields: [
            %{
              field: :address_1,
              label: "Address line 1",
              type: :text,
              tac: 0x0102,
              entity: :household
            },
            %{
              field: :address_2,
              label: "Address line 2",
              type: :text,
              tac: 0x0103,
              entity: :household
            },
            %{field: :city, label: "City", type: :text, tac: 0x0104, entity: :household},
            %{field: :state, label: "State", type: :text, tac: 0x0105, entity: :household},
            %{field: :zipcode, label: "ZIP", type: :text, tac: 0x0106, entity: :household}
          ]
        },
        %{
          title: "Contact",
          fields: [
            %{
              field: :telephone,
              label: "Telephone",
              type: :text,
              tac: 0x0107,
              entity: :household
            }
          ]
        }
      ]
    },
    %{
      id: :path,
      tab: "Personal Path",
      groups: [
        %{
          title: nil,
          description:
            "Jumpwords for the 20 numbered path shortcuts (max 13 characters each).",
          columns: 2,
          fields:
            for {n, tac} <- @path_tacs do
              %{
                field: String.to_atom("path_#{n}"),
                label: "Path #{n}",
                type: :text,
                tac: tac,
                entity: :user
              }
            end
        }
      ]
    }
  ]

  # Flat list of editable field specs (readonly entries are display-
  # only and don't participate in cast/patch). Composite entries like
  # :name_row are expanded inline into their subfield specs so
  # downstream metadata (field atoms, TAC maps) doesn't need to know
  # about the grouping.
  @all_fields Enum.flat_map(@layout, fn tab ->
                Enum.flat_map(tab.groups, fn g ->
                  Enum.flat_map(g.fields, fn
                    %{type: :readonly} ->
                      []

                    %{type: :name_row, entity: entity, subfields: subfields} ->
                      Enum.map(subfields, fn sf ->
                        %{field: sf.field, tac: sf.tac, entity: entity, type: :text}
                      end)

                    f ->
                      [f]
                  end)
                end)
              end)

  @all_field_atoms for f <- @all_fields, do: f.field
  @user_tac_fields for f <- @all_fields,
                       f.entity == :user and not is_nil(f.tac),
                       do: {f.field, f.tac}
  @household_tac_fields for f <- @all_fields,
                            f.entity == :household and not is_nil(f.tac),
                            do: {f.field, f.tac}

  @doc "Ordered list of tabs (each with groups + fields). Consumed by the template."
  def layout, do: @layout

  # --- embedded schema -----------------------------------------------

  @primary_key false
  embedded_schema do
    # User-backed fields
    field(:first_name, :string)
    field(:middle_name, :string)
    field(:last_name, :string)
    field(:title, :string)
    field(:gender, :string)
    field(:birthdate, :date)

    for {n, _tac} <- @path_tacs do
      field(String.to_atom("path_#{n}"), :string)
    end

    field(:concurrency_limit, :integer)

    # Member-list opt-in (PRF_ML_INDICATOR 0x02B0). Modeled as a plain
    # boolean here; profile_patch/1 translates back to the 1-byte
    # base64-encoded JSONB form and stamps PRF_ML_DATE (0x02AF) on flip.
    field(:in_member_list, :boolean)

    # Household-backed fields
    field(:address_1, :string)
    field(:address_2, :string)
    field(:city, :string)
    field(:state, :string)
    field(:zipcode, :string)
    field(:telephone, :string)
  end

  # --- public API ----------------------------------------------------

  @doc """
  Build a form struct from a User (with preloaded household), sourcing
  all values via the JSONB-backed accessors.
  """
  def from_user(%User{household: %Household{} = household} = user) do
    profile = user.profile || %{}

    path_values =
      for {n, tac} <- @path_tacs, into: %{} do
        {String.to_atom("path_#{n}"), Map.get(profile, tac_key(tac))}
      end

    %__MODULE__{
      first_name: User.first_name(user),
      middle_name: User.middle_name(user),
      last_name: User.last_name(user),
      title: User.title(user),
      gender: User.gender(user),
      birthdate: User.birthdate(user),
      concurrency_limit: user.concurrency_limit,
      in_member_list: User.in_member_list?(user),
      address_1: Household.address_1(household),
      address_2: Household.address_2(household),
      city: Household.city(household),
      state: Household.state(household),
      zipcode: Household.zipcode(household),
      telephone: Household.telephone(household)
    }
    |> struct(path_values)
  end

  def from_user(%User{} = user), do: from_user(%User{user | household: %Household{}})

  @doc "Validate form input. Nil concurrency rejected; negatives too."
  def changeset(%__MODULE__{} = form, attrs \\ %{}) do
    form
    |> cast(attrs, @all_field_atoms)
    |> validate_required([:concurrency_limit])
    |> validate_number(:concurrency_limit, greater_than_or_equal_to: 0)
    |> validate_lengths()
  end

  @doc """
  Translate changes into two TAC-keyed JSONB patches - one for the
  user record, one for the household - suitable for merging into each
  entity's `profile` map. Cleared values become `:__delete__` so the
  key is removed.
  """
  def profile_patch(%Ecto.Changeset{} = cs) do
    %{
      user: build_patch(cs, @user_tac_fields) |> merge_member_list_patch(cs),
      household: build_patch(cs, @household_tac_fields)
    }
  end

  # When the admin flips `in_member_list`, write the 1-byte indicator
  # (base64-encoded; ProfileSchema declares 0x02B0 as :binary) and stamp
  # 0x02AF with today's date. Mirrors MSPLADD1/MSPLDEL1 in TBOL, which
  # write both fields together via LINK profile_pgm. No-op when the
  # checkbox value didn't change.
  defp merge_member_list_patch(user_patch, %Ecto.Changeset{} = cs) do
    case Map.fetch(cs.changes, :in_member_list) do
      :error ->
        user_patch

      {:ok, new_value} ->
        indicator = if new_value, do: <<1>>, else: <<0>>

        user_patch
        |> Map.put(tac_key(0x02B0), Base.encode64(indicator))
        |> Map.put(tac_key(0x02AF), format_sys_date(Date.utc_today()))
    end
  end

  # Today's date in the DOS client's hard-coded `MMDDYYYY` form with a
  # `19YY` century prefix (parity with how the wire-side path stamps
  # PRF_ML_DATE - see User.member_list_date for the format note).
  defp format_sys_date(%Date{month: m, day: d, year: y}) do
    pad = fn n -> n |> Integer.to_string() |> String.pad_leading(2, "0") end
    pad.(m) <> pad.(d) <> "19" <> pad.(rem(y, 100))
  end

  @doc """
  Apply a profile patch to an existing profile map - `:__delete__`
  removes keys, other values overwrite.
  """
  def apply_patch(profile, patch) do
    Enum.reduce(patch, profile, fn
      {key, :__delete__}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # --- helpers -------------------------------------------------------

  defp build_patch(cs, tac_fields) do
    Enum.reduce(tac_fields, %{}, fn {field, tac}, acc ->
      case Map.fetch(cs.changes, field) do
        :error ->
          acc

        {:ok, nil} ->
          Map.put(acc, tac_key(tac), :__delete__)

        {:ok, value} ->
          case ProfileSchema.get(tac) do
            nil ->
              acc

            meta ->
              case ProfileBackfill.encode(value, meta.type) do
                nil -> acc
                encoded -> Map.put(acc, tac_key(tac), encoded)
              end
          end
      end
    end)
  end

  # Enforce per-TAC max length from ProfileSchema so the admin can't
  # save a value wider than the DOS client can fit on the wire.
  defp validate_lengths(changeset) do
    tac_fields = @user_tac_fields ++ @household_tac_fields

    Enum.reduce(tac_fields, changeset, fn {field, tac}, cs ->
      case ProfileSchema.get(tac) do
        %{type: :ascii, length: len} when is_integer(len) and len > 0 ->
          validate_length(cs, field, max: len)

        _ ->
          cs
      end
    end)
  end

  defp tac_key(tac), do: ProfileBackfill.tac_key(tac)

  # --- read-only formatters ------------------------------------------
  # Referenced from the layout via `&__MODULE__.format_*/1` so module-
  # attribute evaluation at compile time captures them cleanly.

  @doc false
  def format_enrolled(%User{date_enrolled: nil}), do: "No - user hasn't completed TCS enrollment"
  def format_enrolled(%User{date_enrolled: %Date{} = d}), do: "Yes - #{Date.to_iso8601(d)}"

  @doc false
  def format_last_logon(%User{} = user) do
    # Logoff stamps these as "MM/DD/YYYY" + "HH.MM" per
    # apps/server/lib/prodigy/server/service/logoff.ex - we show them
    # as-is so admins see exactly what the wire value is.
    date = User.last_logon_date(user)
    time = User.last_logon_time(user)

    cond do
      is_nil(date) and is_nil(time) -> "Never"
      true -> [date, time] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    end
  end

  @doc false
  def format_enabled(%Household{enabled_date: nil}), do: "-"
  def format_enabled(%Household{enabled_date: %Date{} = d}), do: Date.to_iso8601(d)

  @doc """
  Display string for the read-only "Last change" row in the Member List
  group. Renders the stored `MMDDYYYY` as `MM/DD/YY` (the last two
  digits match what the DOS client paints in the picker). Returns `-`
  when the user has never been opted in or out.
  """
  def format_member_list_date(%User{} = u) do
    case User.member_list_date(u) do
      nil ->
        "-"

      <<m::binary-2, d::binary-2, _cc::binary-2, yy::binary-2>> ->
        "#{m}/#{d}/#{yy}"

      raw ->
        raw
    end
  end
end
