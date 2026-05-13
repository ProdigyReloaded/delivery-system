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

defmodule Prodigy.Portal.AdminLive.OnlineTest do
  @moduledoc """
  LiveView interaction tests for the admin "Who's online" tab: row rendering,
  filter, disconnect flow with its three error paths. Context-level
  assertions live in `Portal.Admin.SessionsTest`; this file exercises
  the LC's event handling + flash-on-parent plumbing.
  """
  use Prodigy.Portal.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Enroller, Session}

  setup %{conn: conn} do
    admin = Prodigy.Portal.AccountsFixtures.admin_user_fixture()
    {:ok, {_hh, service_user}} = Enroller.create_subscriber("AAAA11", "SECRET", enroll_name: {"Alice", "Smith"})
    {:ok, conn: log_in_user(conn, admin), user: service_user}
  end

  defp insert_session!(service_user, attrs) do
    defaults = %{
      user_id: service_user.id,
      logon_timestamp: DateTime.utc_now() |> DateTime.truncate(:second),
      logon_status: 0,
      rs_version: "06.03.17",
      node: to_string(node()),
      pid: self() |> :erlang.pid_to_list() |> to_string(),
      source_address: "127.0.0.1",
      source_port: 1234,
      transport: "tcp"
    }

    %Session{}
    |> Session.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  describe "render" do
    test "shows the 0-online empty state with no sessions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/service/online")
      assert html =~ "0 online"
      assert html =~ "No sessions match"
    end

    test "renders a row per open session with user name", %{conn: conn, user: user} do
      insert_session!(user, %{})
      {:ok, _view, html} = live(conn, ~p"/admin/service/online")

      assert html =~ "1 online"
      assert html =~ "Alice Smith"
      assert html =~ user.id
    end

    test "hides sessions that have logged off", %{conn: conn, user: user} do
      insert_session!(user, %{
        logoff_timestamp: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, _view, html} = live(conn, ~p"/admin/service/online")
      assert html =~ "0 online"
    end
  end

  describe "filter" do
    setup %{user: user} do
      {:ok, {_h, other}} =
        Enroller.create_subscriber("BBBB22", "SECRET", enroll_name: {"Bob", "Baker"})

      insert_session!(user, %{source_address: "10.0.0.1"})
      # Distinct pid per row so the unique-by-pid constraint (none, but
      # still a good hygiene) doesn't bite us.
      p = spawn(fn -> receive do: (_ -> :ok) end)
      insert_session!(other, %{pid: p |> :erlang.pid_to_list() |> to_string()})

      :ok
    end

    test "filtering by user_id narrows the visible rows", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/service/online")

      html =
        view
        |> form("form[phx-change='filter']", %{"filters" => %{"user_id" => user.id}})
        |> render_change()

      assert html =~ user.id
      refute html =~ "BBBB22A"
    end
  end

  describe "disconnect" do
    test "signals :shutdown to a live pid", %{conn: conn, user: user} do
      target = spawn(fn -> receive do: (_ -> :ok) end)
      session = insert_session!(user, %{pid: target |> :erlang.pid_to_list() |> to_string()})

      {:ok, view, _html} = live(conn, ~p"/admin/service/online")

      ref = Process.monitor(target)
      view
      |> element("button[phx-click='disconnect'][phx-value-id='#{session.id}']")
      |> render_click()

      assert_receive {:DOWN, ^ref, :process, ^target, :shutdown}, 500
    end

    test "stamps :forced logoff on a stale pid (no error flash)", %{conn: conn, user: user} do
      stale = spawn(fn -> :ok end)
      :timer.sleep(10)
      refute Process.alive?(stale)

      session =
        insert_session!(user, %{pid: stale |> :erlang.pid_to_list() |> to_string()})

      {:ok, view, _html} = live(conn, ~p"/admin/service/online")

      view
      |> element("button[phx-click='disconnect'][phx-value-id='#{session.id}']")
      |> render_click()

      reloaded = Repo.get!(Session, session.id)
      assert reloaded.logoff_timestamp != nil
      assert reloaded.logoff_status == 3
    end

    test "flashes an error when the session lives on another node", %{
      conn: conn,
      user: user
    } do
      session = insert_session!(user, %{node: "nobody@elsewhere"})
      {:ok, view, _html} = live(conn, ~p"/admin/service/online")

      view
      |> element("button[phx-click='disconnect'][phx-value-id='#{session.id}']")
      |> render_click()

      _ = :sys.get_state(view.pid)
      assert render(view) =~ "Multi-node disconnect"
    end
  end
end
