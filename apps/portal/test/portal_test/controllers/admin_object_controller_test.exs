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

defmodule Prodigy.Portal.AdminObjectControllerTest do
  @moduledoc """
  Controller tests for the service-object download endpoint. Exercises
  auth gating (admin-only), happy path (matches the blob bytes + the
  attachment filename), integer-parse errors, and missing rows.
  """
  use Prodigy.Portal.ConnCase, async: false

  alias Prodigy.Portal.Admin.Objects

  defp name_bytes(s), do: s <> String.duplicate(" ", 11 - byte_size(s))

  defp build_blob(name, version \\ 1) do
    # Wrap the 4-byte DEADBEEF filler in a valid segment frame so the
    # codec's segment walker succeeds - an empty body would also work,
    # but keeping the "download returns these exact bytes" shape is
    # nice for the controller assertion.
    payload = <<0xDE, 0xAD, 0xBE, 0xEF>>
    segment = <<0x01, 3 + byte_size(payload)::16-little>> <> payload
    <<cv_high, cv_low>> = <<0::3, version::13>>

    <<name_bytes(name)::binary-size(11), 0, 0, byte_size(segment)::16-little, cv_high, 0,
      cv_low>> <> segment
  end

  defp insert_object!(name, version \\ 1) do
    blob = build_blob(name, version)
    {:ok, parsed} = Objects.parse_import_blob(blob)
    {:ok, %{inserted: [_]}} = Objects.insert_many([parsed])
    {parsed, blob}
  end

  describe "auth gate" do
    test "redirects anonymous visitors to the login page", %{conn: conn} do
      conn = get(conn, ~p"/admin/service/objects/PAGE/0/0/1/download")
      assert redirected_to(conn) =~ "/users/login"
    end

    test "redirects non-admin users to /", %{conn: conn} do
      conn = log_in_user(conn, Prodigy.Portal.AccountsFixtures.user_fixture())
      conn = get(conn, ~p"/admin/service/objects/PAGE/0/0/1/download")
      assert redirected_to(conn) == "/"
    end
  end

  describe "download/2 (as admin)" do
    setup %{conn: conn} do
      admin = Prodigy.Portal.AccountsFixtures.admin_user_fixture()
      {:ok, conn: log_in_user(conn, admin)}
    end

    test "streams the raw blob as application/octet-stream with an attachment header",
         %{conn: conn} do
      {parsed, blob} = insert_object!("DOWN", 7)

      conn =
        get(
          conn,
          ~p"/admin/service/objects/#{parsed.name}/#{parsed.sequence}/#{parsed.type}/#{parsed.version}/download"
        )

      assert response(conn, 200) == blob
      [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "application/octet-stream"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(filename="DOWN)
      assert disposition =~ "_7"
    end

    test "404s on a non-existent composite PK", %{conn: conn} do
      conn = get(conn, ~p"/admin/service/objects/NOPE/0/0/1/download")
      assert response(conn, 404) =~ "not found"
    end

    test "404s when integer segments don't parse cleanly", %{conn: conn} do
      # Route pattern allows any string in :sequence, so it reaches the
      # controller with "abc" and the integer-parse clause falls through.
      conn = get(conn, ~p"/admin/service/objects/PAGE/abc/0/1/download")
      assert response(conn, 404)
    end
  end
end
