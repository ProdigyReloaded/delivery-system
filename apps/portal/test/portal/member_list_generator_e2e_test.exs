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

defmodule Prodigy.Portal.MemberListGeneratorE2ETest do
  @moduledoc """
  End-to-end coverage for `Prodigy.Server.MemberList.Generator.run/1`:
  drive it with an in-memory member list via the `:source` injection and
  assert the `object` table reflects the result, including a
  second-run reconcile that drops a departed member's Y-object.

  Lives in `:portal` only because portal carries the DataCase. The
  module under test is in `:server`. See `objects_store_test.exs` for
  the same reason.
  """
  use Prodigy.Portal.DataCase, async: true

  import Ecto.Query
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Object
  alias Prodigy.Server.MemberList.{Generator, Schema}

  defp member(id, last, first, state, city, opts \\ []) do
    %{
      "user_id" => id,
      "state" => state,
      "city" => city,
      "unknown" => "",
      "last_name" => last,
      "first_name" => first,
      "middle" => Keyword.get(opts, :middle, ""),
      "title" => Keyword.get(opts, :title, "Mr."),
      "unknown1" => "",
      "unknown2" => "",
      "unknown3" => ""
    }
  end

  defp count_with_prefix(pat),
    do: Repo.aggregate(from(o in Object, where: like(o.name, ^pat)), :count, :name)

  defp names_with_prefix(pat) do
    Repo.all(from o in Object, where: like(o.name, ^pat), select: o.name, order_by: o.name)
  end

  describe "run/1 with :source injection" do
    test "writes the full 3B + 3L + MSPLSTAT object set and reports a summary" do
      members = [
        member("AAAA11A", "SMITH", "JANE", "TX", "AUSTIN"),
        member("BBBB22A", "JONES", "BOB", "TX", "HOUSTON"),
        member("CCCC33A", "DOE", "ALICE", "CA", "LOS ANGELES", title: "Mrs.")
      ]

      assert {:ok, %{members: 3, upserted: u, deleted: 0}} =
               Generator.run(source: fn -> members end, version: 1)

      # Every member-list object now lives in the table.
      assert u == count_with_prefix("3B%") + count_with_prefix("3L%") + count_with_prefix("MSPLSTAT%")

      # Specific objects we expect.
      assert "3B000000D  " in names_with_prefix("3B%")
      assert "3L000000D  " in names_with_prefix("3L%")
      assert "MSPLSTATD  " in names_with_prefix("MSPLSTAT%")

      # One Y-object per member.
      for i <- 1..3 do
        ref6 = binary_part(Schema.tdo_ref(i), 0, 6)
        assert "3L" <> ref6 <> "Y  " in names_with_prefix("3L%")
      end
    end

    test "second run with one fewer member drops that member's Y-object" do
      members_run1 = [
        member("AAAA11A", "SMITH", "JANE", "TX", "AUSTIN"),
        member("BBBB22A", "JONES", "BOB", "TX", "HOUSTON"),
        member("CCCC33A", "DOE", "ALICE", "CA", "LOS ANGELES")
      ]

      {:ok, %{upserted: u1}} = Generator.run(source: fn -> members_run1 end, version: 1)

      y_objects_run1 = names_with_prefix("3L%") |> Enum.filter(&String.ends_with?(&1, "Y  "))
      assert length(y_objects_run1) == 3

      # Member CCCC33A opts out.
      members_run2 = Enum.take(members_run1, 2)
      {:ok, %{upserted: u2, deleted: d2}} = Generator.run(source: fn -> members_run2 end, version: 1)

      # Less stuff written (2 Y-objects instead of 3, plus fewer entries
      # in some indexes), and more stuff deleted (everything from run 1).
      assert u2 < u1
      assert d2 == u1

      y_objects_run2 = names_with_prefix("3L%") |> Enum.filter(&String.ends_with?(&1, "Y  "))
      assert length(y_objects_run2) == 2

      # Departed member's Y-object is gone (was 3rd in run 1 -> "000003Y").
      refute "3L000003Y  " in y_objects_run2
    end

    test "empty member set: produces only the DADs + MSPLSTAT; doesn't crash" do
      assert {:ok, %{members: 0}} = Generator.run(source: fn -> [] end, version: 1)

      assert "3B000000D  " in names_with_prefix("3B%")
      assert "3L000000D  " in names_with_prefix("3L%")
      assert "MSPLSTATD  " in names_with_prefix("MSPLSTAT%")
      assert names_with_prefix("3L%") |> Enum.filter(&String.ends_with?(&1, "Y  ")) == []
    end
  end
end
