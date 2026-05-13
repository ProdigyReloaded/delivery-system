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

defmodule Prodigy.Core.Data.Service.ProfileBackfillTest do
  @moduledoc """
  Only the encoding helpers on `ProfileBackfill` are live in the
  runtime path (used by `UserForm.profile_patch` and `ProfileDispatch`).
  The per-row `user/1` / `household/1` functions are still called by
  the one-time backfill migration on fresh installs; they harmlessly
  produce empty maps because the named profile columns no longer
  exist on the schema.
  """
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.ProfileBackfill

  describe "tac_key/1" do
    test "pads to four uppercase hex digits" do
      assert ProfileBackfill.tac_key(0x0102) == "0102"
      assert ProfileBackfill.tac_key(0x014F) == "014F"
      assert ProfileBackfill.tac_key(0x02FB) == "02FB"
    end

    test "handles TACs whose hex uses lowercase a-f natively" do
      assert ProfileBackfill.tac_key(0x011A) == "011A"
    end
  end

  describe "encode/2" do
    test ":ascii values pass through" do
      assert ProfileBackfill.encode("Smith", :ascii) == "Smith"
      assert ProfileBackfill.encode("", :ascii) == ""
    end

    test ":binary values base64-encode" do
      assert ProfileBackfill.encode(<<1, 2, 3>>, :binary) == Base.encode64(<<1, 2, 3>>)
    end

    test ":date_mmddyy formats a Date struct as MMDDYY" do
      assert ProfileBackfill.encode(~D[1976-03-05], :date_mmddyy) == "030576"
      assert ProfileBackfill.encode(~D[2025-12-31], :date_mmddyy) == "123125"
    end

    test ":date_mmddyy passes through a pre-formatted string" do
      assert ProfileBackfill.encode("01011988", :date_mmddyy) == "01011988"
    end

    test "nil values encode to nil (caller drops)" do
      assert ProfileBackfill.encode(nil, :ascii) == nil
      assert ProfileBackfill.encode(nil, :binary) == nil
      assert ProfileBackfill.encode(nil, :date_mmddyy) == nil
    end
  end
end
