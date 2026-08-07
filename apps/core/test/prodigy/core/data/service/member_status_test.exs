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

defmodule Prodigy.Core.Data.Service.MemberStatusTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.MemberStatus

  test "suffix-in-use bits accumulate and round-trip through base64" do
    p = %{} |> MemberStatus.put_suffix_in_use("A") |> MemberStatus.put_suffix_in_use("C")

    # A=0x01, C=0x04 -> 0x05
    assert Base.decode64!(p[MemberStatus.suffix_key()]) == <<0x05>>
  end

  test "put_indicators encodes active/enrolled in byte 1, NUL byte 2" do
    p = MemberStatus.put_indicators(%{}, "B", true, false)
    assert Base.decode64!(p[MemberStatus.indicators_key("B")]) == <<0x01, 0x00>>
    assert MemberStatus.active?(p, "B")
    refute MemberStatus.enrolled?(p, "B")

    p2 = MemberStatus.put_indicators(%{}, "B", false, true)
    assert Base.decode64!(p2[MemberStatus.indicators_key("B")]) == <<0x02, 0x00>>
    refute MemberStatus.active?(p2, "B")
    assert MemberStatus.enrolled?(p2, "B")
  end

  test "set_enrolled preserves the active bit" do
    p = MemberStatus.put_indicators(%{}, "D", true, false)
    p = MemberStatus.set_enrolled(p, "D")
    assert Base.decode64!(p[MemberStatus.indicators_key("D")]) == <<0x03, 0x00>>
    assert MemberStatus.active?(p, "D")
    assert MemberStatus.enrolled?(p, "D")
  end

  test "missing indicator reads as active but not enrolled (legacy)" do
    assert MemberStatus.active?(%{}, "A")
    refute MemberStatus.enrolled?(%{}, "A")
  end

  test "suffix_of takes the last id character, upcased" do
    assert MemberStatus.suffix_of("ABCD12A") == "A"
    assert MemberStatus.suffix_of("abcd12f") == "F"
  end
end
