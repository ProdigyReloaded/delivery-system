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

defmodule Prodigy.Portal.AdminLive.UsersTest do
  @moduledoc """
  LiveView interaction tests for the admin Users tab. Exercises the
  edit-modal flow end-to-end: mount, render, tab switch, validation,
  save, reset password, delete/undelete/disconnect. The DB-level save
  assertions live in `Prodigy.Portal.Admin.UsersTest`; this file is
  specifically about the LiveView event pipeline.
  """
  use Prodigy.Portal.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Prodigy.Core.Data.Service.{Enroller, User}
  alias Prodigy.Core.Data.Repo

  setup %{conn: conn} do
    admin = Prodigy.Portal.AccountsFixtures.admin_user_fixture()
    {:ok, {_hh, service_user}} = Enroller.create_subscriber("AAAA11", "SECRET", enroll_name: {"Alice", "Smith"})

    conn = log_in_user(conn, admin)
    {:ok, conn: conn, admin: admin, user: service_user}
  end

  describe "mount + initial render" do
    test "renders the users table with seeded accounts", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/admin/service/users")

      assert html =~ "Alice Smith"
      assert has_element?(view, "code", user.id)
    end

    test "bounces non-admin users back to /", %{conn: conn} do
      # Fresh non-admin conn.
      non_admin = Prodigy.Portal.AccountsFixtures.user_fixture()
      conn = conn |> Phoenix.ConnTest.recycle() |> log_in_user(non_admin)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end
  end

  describe "filter + sort" do
    setup %{} do
      {:ok, {_h, _u}} =
        Enroller.create_subscriber("BBBB22", "SECRET", enroll_name: {"Bob", "Baker"})

      :ok
    end

    test "filtering by name narrows the visible rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")

      html =
        view
        |> form("form[phx-change='filter']", %{"filters" => %{"name" => "bob"}})
        |> render_change()

      assert html =~ "Bob Baker"
      refute html =~ "Alice Smith"
    end

    test "clicking a column header toggles sort direction", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")

      # Initial sort is (:user_id, :asc). Clicking the already-sorted
      # column toggles direction, so the first click produces :desc (▼).
      html = view |> element("a[phx-click='sort'][phx-value-by='user_id']") |> render_click()
      assert html =~ "▼"

      # A second click toggles back to :asc (▲).
      html = view |> element("a[phx-click='sort'][phx-value-by='user_id']") |> render_click()
      assert html =~ "▲"
    end
  end

  describe "edit modal" do
    test "opens with the user's JSONB-sourced values pre-filled", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")

      html = view |> element("button[phx-click='edit'][phx-value-id=#{user.id}]") |> render_click()
      assert html =~ "Edit #{user.id}"
      assert html =~ ~s(value="Alice")
      assert html =~ ~s(value="Smith")
    end

    test "tab-switching updates the active class without re-rendering data", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")
      view |> element("button[phx-click='edit'][phx-value-id=#{user.id}]") |> render_click()

      html = view |> element("a[phx-click='select_tab'][phx-value-tab='path']") |> render_click()
      # The Personal Path tab's header should now be marked active.
      assert html =~ ~r(class="nav-link active"[^>]*phx-value-tab="path")
    end

    test "saves name + gender and shows a success flash", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")
      view |> element("button[phx-click='edit'][phx-value-id=#{user.id}]") |> render_click()

      view
      |> form("#edit-user-form", %{
        "user" => %{
          "first_name" => "Alicia",
          "last_name" => "Smythe",
          "gender" => "F",
          "concurrency_limit" => "1"
        }
      })
      |> render_submit()

      reloaded = Repo.get(User, user.id)
      assert reloaded.profile["015F"] == "Alicia"
      assert reloaded.profile["015E"] == "Smythe"
      assert reloaded.profile["0157"] == "F"

      # The LiveView should have flashed an info message via its parent handler.
      assert render(view) =~ "User updated"
    end

    test "surfaces validation errors without saving on bad length", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")
      view |> element("button[phx-click='edit'][phx-value-id=#{user.id}]") |> render_click()

      # last_name TAC limit is 20.
      html =
        view
        |> form("#edit-user-form", %{
          "user" => %{
            "last_name" => String.duplicate("x", 21),
            "concurrency_limit" => "1"
          }
        })
        |> render_submit()

      assert html =~ "should be at most"
      # Original name preserved.
      assert Repo.get(User, user.id).profile["015E"] == "Smith"
    end

    test "closes when the close button is clicked", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")
      view |> element("button[phx-click='edit'][phx-value-id=#{user.id}]") |> render_click()
      assert has_element?(view, "#edit-user-form")

      view |> element("button[phx-click='close_modal']", "Cancel") |> render_click()
      refute has_element?(view, "#edit-user-form")
    end
  end

  describe "reset password modal" do
    test "opens, generates a password, and saves it", %{conn: conn, user: user} do
      original_hash = Repo.get(User, user.id).password

      {:ok, view, _html} = live(conn, ~p"/admin/service/users")
      html = view |> element("button[phx-click='reset_password'][phx-value-id=#{user.id}]") |> render_click()
      assert html =~ "Reset password for #{user.id}"

      view
      |> form("#reset-password-form", %{"password" => "newpass1"})
      |> render_submit()

      # The hash should have changed to the new password.
      refute Repo.get(User, user.id).password == original_hash
      # Success flash carries the uppercased form back.
      assert render(view) =~ "NEWPASS1"
    end

    test "rejects non-alphanumeric passwords with an error flash", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")
      view |> element("button[phx-click='reset_password'][phx-value-id=#{user.id}]") |> render_click()

      html =
        view
        |> form("#reset-password-form", %{"password" => "bad pass!"})
        |> render_submit()

      assert html =~ "letters and digits only"
    end
  end

  describe "delete + undelete row actions" do
    # The LiveView refreshes its rows via a SessionManager :profile_updated
    # broadcast after the DB write; PubSub delivery is async, so we
    # wait for the broadcast and then ask the LiveView to re-render.
    setup do
      Phoenix.PubSub.subscribe(
        Prodigy.Core.PubSub,
        Prodigy.Server.SessionManager.topic()
      )

      :ok
    end

    test "delete soft-deletes and flips the badge to deleted", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/users")

      view
      |> element("button[phx-click='delete'][phx-value-id=#{user.id}]")
      |> render_click()

      assert_receive {:profile_updated, _}, 500
      # Force the LiveView to drain its mailbox before we inspect the DOM.
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ ~r/badge text-bg-danger">deleted/
      assert Repo.get(User, user.id).date_deleted != nil
    end

    test "undelete restores a previously-deleted user", %{conn: conn, user: user} do
      {:ok, _updated} = Prodigy.Portal.Admin.Users.soft_delete(user)
      assert_receive {:profile_updated, _}, 500

      {:ok, view, _html} = live(conn, ~p"/admin/service/users")

      view
      |> element("button[phx-click='undelete'][phx-value-id=#{user.id}]")
      |> render_click()

      assert_receive {:profile_updated, _}, 500
      _ = :sys.get_state(view.pid)
      html = render(view)

      refute html =~ ~r/badge text-bg-danger">deleted/
      assert Repo.get(User, user.id).date_deleted == nil
    end
  end
end
