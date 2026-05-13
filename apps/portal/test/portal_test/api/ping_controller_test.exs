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

defmodule Prodigy.Portal.Api.PingControllerTest do
  use Prodigy.Portal.ConnCase, async: true

  alias Prodigy.Portal.ApiKeys

  defp with_bearer(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "GET /api/v1/ping" do
    test "401 with no Authorization header", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/ping")
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_api_key"}
    end

    test "401 when the Authorization header is not a Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> get(~p"/api/v1/ping")

      assert conn.status == 401
    end

    test "401 on an unknown Bearer token", %{conn: conn} do
      conn =
        conn
        |> with_bearer("pk_" <> String.duplicate("a", 26))
        |> get(~p"/api/v1/ping")

      assert conn.status == 401
    end

    test "401 on a revoked key", %{conn: conn} do
      user = admin_user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})
      {:ok, _} = ApiKeys.revoke(user.id, key.id)

      conn = conn |> with_bearer(key.plaintext) |> get(~p"/api/v1/ping")
      assert conn.status == 401
    end

    test "200 for any authenticated key - ping is the smoke endpoint", %{conn: conn} do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      conn = conn |> with_bearer(key.plaintext) |> get(~p"/api/v1/ping")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["user_id"] == user.id
    end

    test "200 with user details on a valid admin key", %{conn: conn} do
      admin = admin_user_fixture()
      {:ok, key} = ApiKeys.create(admin.id, %{name: "laptop"})

      conn = conn |> with_bearer(key.plaintext) |> get(~p"/api/v1/ping")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["ok"] == true
      assert body["user_id"] == admin.id
      assert body["email"] == admin.email
    end

    test "successful auth schedules a touch of last_used_at", %{conn: conn} do
      admin = admin_user_fixture()
      {:ok, key} = ApiKeys.create(admin.id, %{name: "k"})
      assert [%{last_used_at: nil}] = ApiKeys.list_for_user(admin.id)

      conn |> with_bearer(key.plaintext) |> get(~p"/api/v1/ping")

      # touch_async fires a Task under the shared
      # Prodigy.Portal.TaskSupervisor. An earlier version of this test
      # tried to drain every Task in that supervisor, but in
      # async-parallel runs that supervisor holds tasks from OTHER
      # concurrent tests whose sandbox is a different owner - waiting
      # for their DOWN messages inside our test process's 500 ms
      # window turned into a race. Poll for the specific side-effect
      # we care about - the row's last_used_at landing - instead.
      assert wait_until(fn ->
               match?([%{last_used_at: %DateTime{}}], ApiKeys.list_for_user(admin.id))
             end)
    end

    # Poll `fun` until it returns truthy or `timeout_ms` elapses.
    # Sleep between attempts is tiny so the test finishes as soon as
    # the async work lands; overall wall time is capped so a hung
    # check fails fast with a clear error.
    defp wait_until(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_until(fun, deadline, step_ms)
    end

    defp do_wait_until(fun, deadline, step_ms) do
      cond do
        fun.() -> true
        System.monotonic_time(:millisecond) > deadline -> false
        true ->
          Process.sleep(step_ms)
          do_wait_until(fun, deadline, step_ms)
      end
    end
  end
end
