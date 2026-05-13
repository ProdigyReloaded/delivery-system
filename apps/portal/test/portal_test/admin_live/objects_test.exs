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

defmodule Prodigy.Portal.AdminLive.ObjectsTest do
  @moduledoc """
  LiveView interaction tests for the admin Objects tab: list render, filter,
  sort, upload modal, delete. Context-level assertions live in
  `Portal.Admin.ObjectsTest`; this file covers the event pipeline and
  flash surfacing.
  """
  use Prodigy.Portal.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Object
  alias Prodigy.Portal.Admin.Objects

  setup %{conn: conn} do
    admin = Prodigy.Portal.AccountsFixtures.admin_user_fixture()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  defp name_bytes(s), do: s <> String.duplicate(" ", 11 - byte_size(s))

  defp build_blob(opts) do
    name = Keyword.fetch!(opts, :name)
    sequence = Keyword.get(opts, :sequence, 0)
    type = Keyword.get(opts, :type, 0x0)
    version = Keyword.get(opts, :version, 1)
    # Default to an empty body so the codec's segment walker succeeds.
    # Tests that need a specific size pass their own :body.
    body = Keyword.get(opts, :body, <<>>)
    <<cv_high, cv_low>> = <<0::3, version::13>>
    length = byte_size(body)

    <<name_bytes(name)::binary-size(11), sequence, type, length::16-little, cv_high, 0,
      cv_low>> <> body
  end

  defp insert_object!(opts) do
    blob = build_blob(opts)
    {:ok, parsed} = Objects.parse_import_blob(blob)
    {:ok, %{inserted: [_]}} = Objects.insert_many([parsed])
    parsed
  end

  describe "mount + render" do
    test "empty state shows zero count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/service/objects")
      assert html =~ ">0 objects"
    end

    test "lists inserted objects by (name, seq, type, version)", %{conn: conn} do
      insert_object!(name: "PAGE1", version: 1)
      insert_object!(name: "PAGE2", version: 1)

      {:ok, _view, html} = live(conn, ~p"/admin/service/objects")
      assert html =~ "PAGE1"
      assert html =~ "PAGE2"
      assert html =~ ">2 objects"
    end
  end

  describe "filter + sort" do
    setup do
      insert_object!(name: "ALPHA", type: 0x0, version: 1)
      insert_object!(name: "BRAVO", type: 0x4, version: 1)
      insert_object!(name: "GAMMA", type: 0x8, version: 1)
      :ok
    end

    test "name filter narrows the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")

      html =
        view
        |> form("form[phx-change='filter']", %{"filters" => %{"name" => "bra"}})
        |> render_change()

      assert html =~ "BRAVO"
      refute html =~ "ALPHA"
      refute html =~ "GAMMA"
    end

    test "clearing the type-filter set empties the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")

      # Submit the filter event with no types ticked - the LC's
      # selected_types becomes empty, so every row is filtered out.
      # The browser semantics are "if no type boxes are checked, show
      # nothing matched", which is what the LiveView dispatches to here.
      view
      |> with_target("[data-phx-component]")
      |> render_change("filter", %{"filters" => %{}, "types" => %{}})

      html = render(view)
      refute html =~ "ALPHA"
      refute html =~ "BRAVO"
      refute html =~ "GAMMA"
      assert html =~ "No objects match"
    end

    test "newest-only checkbox hides older bumped versions", %{conn: conn} do
      # Outer setup already seeded ALPHA, BRAVO, GAMMA (3 rows). Add
      # two versions of DUP: seed v3, then re-upload with different
      # content so Store bumps to v4 -> 5 rows total.
      insert_object!(name: "DUP", version: 3, body: <<1>>)

      {:ok, v2} = Objects.parse_import_blob(build_blob(name: "DUP", version: 3, body: <<2>>))
      {:ok, %{bumped: [_]}} = Objects.insert_many([v2])

      {:ok, view, html_unchecked} = live(conn, ~p"/admin/service/objects")
      assert html_unchecked =~ ">5 objects"
      assert html_unchecked =~ "DUP"

      # Tick the checkbox.
      types =
        Objects.known_types()
        |> Enum.map(&{to_string(&1), "true"})
        |> Map.new()

      html =
        view
        |> form("form[phx-change='filter']", %{
          "filters" => %{},
          "types" => types,
          "newest_only" => "true"
        })
        |> render_change()

      # Newest-only: 3 ALPHA/BRAVO/GAMMA (each has one version) + one
      # DUP (the v4, dropping v3) = 4 rows.
      assert html =~ ">4 objects"
      assert html =~ "DUP"
    end

    test "clicking a header flips sort direction", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")

      html = view |> element("a[phx-click='sort'][phx-value-by='name']") |> render_click()
      assert html =~ "▼"

      html = view |> element("a[phx-click='sort'][phx-value-by='name']") |> render_click()
      assert html =~ "▲"
    end
  end

  describe "upload modal" do
    setup do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Objects.topic())
      :ok
    end

    test "opens the upload modal on button click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")

      assert view
             |> element("button[phx-click='open_upload']")
             |> render_click() =~ "Upload"

      assert has_element?(view, "#upload-objects-form")
    end

    test "closes the upload modal via close button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")
      view |> element("button[phx-click='open_upload']") |> render_click()
      assert has_element?(view, "#upload-objects-form")

      view |> element("button[phx-click='close_modal']") |> render_click()
      refute has_element?(view, "#upload-objects-form")
    end

    test "successful upload inserts rows and flashes success", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")
      view |> element("button[phx-click='open_upload']") |> render_click()

      blob = build_blob(name: "UPLOAD", version: 1)
      objects_input = file_input(view, "#upload-objects-form", :objects, [
        %{name: "UPLOAD.OBJ", content: blob, type: "application/octet-stream"}
      ])

      assert render_upload(objects_input, "UPLOAD.OBJ")

      view |> element("#upload-objects-form") |> render_submit()

      assert_receive :objects_upserted, 500
      # Force the LiveView to drain the broadcast before re-render.
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "1 new"
      assert Objects.list() |> Enum.any?(&(String.trim(&1.name) == "UPLOAD"))
    end

    test "parse errors on a too-short blob surface an error flash, no inserts", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")
      view |> element("button[phx-click='open_upload']") |> render_click()

      short = <<0, 1, 2>>
      input = file_input(view, "#upload-objects-form", :objects, [
        %{name: "BAD.OBJ", content: short, type: "application/octet-stream"}
      ])

      render_upload(input, "BAD.OBJ")
      view |> element("#upload-objects-form") |> render_submit()

      # flash_parent sends :put_flash to the parent LiveView; drain that message
      # before we inspect the DOM.
      _ = :sys.get_state(view.pid)
      assert render(view) =~ "Couldn&#39;t import"
      assert Objects.list() == []
    end
  end

  describe "delete" do
    setup do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Objects.topic())
      :ok
    end

    test "removes the row and triggers :objects_deleted", %{conn: conn} do
      p = insert_object!(name: "DEL", version: 1)
      # Drain the insert broadcast.
      assert_receive :objects_upserted, 500

      {:ok, view, _html} = live(conn, ~p"/admin/service/objects")

      # Only one row on this table, and phx-value-name carries trailing
      # spaces that break a naive CSS selector; a double-quoted attr
      # selector handles the spaces cleanly.
      view
      |> element(~s|button[phx-click="delete"][phx-value-name="#{p.name}"]|)
      |> render_click()

      assert_receive :objects_deleted, 500
      _ = :sys.get_state(view.pid)

      refute Repo.get_by(Object,
               name: p.name,
               sequence: p.sequence,
               type: p.type,
               version: p.version
             )
    end
  end
end
