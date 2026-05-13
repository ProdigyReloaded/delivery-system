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

defmodule Prodigy.Portal.AdminLive.KeywordsTest do
  @moduledoc """
  LiveView interaction tests for the admin Keywords tab.
  """
  use Prodigy.Portal.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Keyword, as: ObjectKeyword
  alias Prodigy.Portal.Admin.Keywords

  setup %{conn: conn} do
    admin = Prodigy.Portal.AccountsFixtures.admin_user_fixture()
    {:ok, conn: log_in_user(conn, admin)}
  end

  defp seed!(keyword, object_name) do
    %ObjectKeyword{}
    |> ObjectKeyword.changeset(%{
      keyword: keyword,
      object_name: String.pad_trailing(object_name, 11, " "),
      object_sequence: 0,
      object_type: 0x04
    })
    |> Repo.insert!()
  end

  describe "mount + render" do
    test "empty state shows zero keywords", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/service/keywords")
      assert html =~ ">0 keywords"
      assert html =~ "No keywords match"
    end

    test "lists seeded keywords with object + type columns", %{conn: conn} do
      seed!("NEWS", "NH0")
      seed!("WEATHER", "WM0")

      {:ok, _view, html} = live(conn, ~p"/admin/service/keywords")
      assert html =~ "NEWS"
      assert html =~ "WEATHER"
      assert html =~ "NH0"
      assert html =~ "WM0"
      assert html =~ "Page Template"
      assert html =~ ">2 keywords"
    end
  end

  describe "filter + sort" do
    setup do
      seed!("NEWS", "NH0")
      seed!("WEATHER", "WM0")
      seed!("DIRECTORY", "ICG")
      :ok
    end

    test "filter by keyword substring narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/keywords")

      html =
        view
        |> form("form[phx-change='filter']", %{"filters" => %{"keyword" => "news"}})
        |> render_change()

      assert html =~ "NEWS"
      refute html =~ "WEATHER"
      refute html =~ "DIRECTORY"
    end

    test "filter by object_name narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/keywords")

      html =
        view
        |> form("form[phx-change='filter']", %{"filters" => %{"object_name" => "ICG"}})
        |> render_change()

      assert html =~ "DIRECTORY"
      refute html =~ "NEWS"
    end

    test "clicking a column header toggles sort direction", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/keywords")

      html = view |> element("a[phx-click='sort'][phx-value-by='keyword']") |> render_click()
      assert html =~ "▼"

      html = view |> element("a[phx-click='sort'][phx-value-by='keyword']") |> render_click()
      assert html =~ "▲"
    end
  end

  describe "rebuild index button" do
    test "empty keyword table -> error flash, no rebuild happens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/keywords")

      view
      |> element("button[phx-click='rebuild_index']")
      |> render_click()

      _ = :sys.get_state(view.pid)
      assert render(view) =~ "keyword table is empty"
    end

    test "successful rebuild flashes the counts and persists the index objects",
         %{conn: conn} do
      seed!("ADD MEMBER", "MSZA0000MAP")
      seed!("ZOOM", "ZMOBJ000000")

      {:ok, view, _html} = live(conn, ~p"/admin/service/keywords")

      view
      |> element("button[phx-click='rebuild_index']")
      |> render_click()

      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Rebuilt keyword index: 1 primary + 1 secondaries"
      assert html =~ "2 new"

      # The primary landed in the object table.
      assert Repo.get_by(Prodigy.Core.Data.Service.Object,
               name: "TAODCUSSPGM",
               sequence: 0,
               type: 0x0C,
               version: 1
             ) != nil
    end
  end

  describe "delete" do
    setup do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Keywords.topic())
      :ok
    end

    test "removes the row and broadcasts :keywords_deleted", %{conn: conn} do
      seed!("BYE", "OBJ")

      {:ok, view, _html} = live(conn, ~p"/admin/service/keywords")

      view
      |> element("button[phx-click='delete'][phx-value-keyword='BYE']")
      |> render_click()

      assert_receive :keywords_deleted, 500
      _ = :sys.get_state(view.pid)

      assert render(view) =~ ">0 keywords"
      assert Keywords.list() == []
    end
  end
end
