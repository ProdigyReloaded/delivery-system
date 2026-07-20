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

defmodule Prodigy.Core.Data.Service.EnrollerTest do
  @moduledoc """
  Lives in `:portal` only because portal carries the DataCase; the
  module under test (`Prodigy.Core.Data.Service.Enroller`) is in
  `:core`. Same arrangement as `objects_store_test.exs`.
  """
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Core.Data.Service.Enroller

  describe "create_subscriber/3 — default Personal Path entries" do
    test "plants the three default path jumpwords for an un-named subscriber" do
      {:ok, {_household, user}} = Enroller.create_subscriber("PATH01", "SECRET")

      assert user.profile["023F"] == "HEADLINES"
      assert user.profile["0240"] == "WEATHER MAP"
      assert user.profile["0241"] == "HIGHLIGHTS"

      # And nothing else got planted on the un-named path - no name/title.
      refute Map.has_key?(user.profile, "015E")
      refute Map.has_key?(user.profile, "015F")
      refute Map.has_key?(user.profile, "0161")
    end

    test "plants the same defaults alongside the name fields when :enroll_name is given" do
      {:ok, {_household, user}} =
        Enroller.create_subscriber("PATH02", "SECRET", enroll_name: {"Ada", "Lovelace"})

      assert user.profile["023F"] == "HEADLINES"
      assert user.profile["0240"] == "WEATHER MAP"
      assert user.profile["0241"] == "HIGHLIGHTS"

      assert user.profile["015F"] == "Ada"
      assert user.profile["015E"] == "Lovelace"
      assert user.profile["0161"] == "Mr."
      assert user.profile["0157"] == "M"
    end

    test "leaves the remaining 17 path slots absent — empty by intent, not 13-space padding" do
      {:ok, {_household, user}} = Enroller.create_subscriber("PATH03", "SECRET")

      # Slots 4..12 (TACs 0x0242..0x024A) and 13..20 (TACs 0x020A..0x0211).
      contiguous = for tac <- 0x0242..0x024A, do: tac_key(tac)
      second_range = for tac <- 0x020A..0x0211, do: tac_key(tac)

      for key <- contiguous ++ second_range do
        refute Map.has_key?(user.profile, key),
               "expected slot #{key} to be absent, found #{inspect(user.profile[key])}"
      end
    end
  end

  defp tac_key(tac),
    do: tac |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.upcase()
end
