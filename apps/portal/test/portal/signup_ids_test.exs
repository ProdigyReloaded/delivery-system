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

defmodule Prodigy.Portal.SignupIdsTest do
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Portal.SignupIds

  describe "validate_custom/2" do
    test "accepts a well-formed unreserved id" do
      assert :ok = SignupIds.validate_custom("QRST01")
    end

    test "rejects bad format" do
      assert {:error, :bad_format} = SignupIds.validate_custom("abc")
    end

    test "rejects a reserved prefix by default" do
      assert {:error, :reserved} = SignupIds.validate_custom("PHIL00")
    end

    test "rejects profanity regardless of bypass" do
      assert {:error, :profanity} = SignupIds.validate_custom("FUCK00")

      assert {:error, :profanity} =
               SignupIds.validate_custom("FUCK00", bypass_reserved: true)
    end

    test "bypass_reserved lets a reserved prefix through" do
      assert :ok = SignupIds.validate_custom("PHIL00", bypass_reserved: true)
    end

    test "bypass_reserved still rejects bad format" do
      assert {:error, :bad_format} =
               SignupIds.validate_custom("X", bypass_reserved: true)
    end
  end
end
