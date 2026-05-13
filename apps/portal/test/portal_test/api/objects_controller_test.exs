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

defmodule Prodigy.Portal.Api.ObjectsControllerTest do
  use Prodigy.Portal.ConnCase, async: true

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Keyword, Object}
  alias Prodigy.Portal.ApiKeys

  # --- helpers -------------------------------------------------------

  defp name_bytes(s), do: s <> String.duplicate(" ", 11 - byte_size(s))

  defp build_blob(opts) do
    name = Elixir.Keyword.fetch!(opts, :name)
    version = Elixir.Keyword.get(opts, :version, 1)
    body = Elixir.Keyword.get(opts, :body, <<>>)
    <<cv_high, cv_low>> = <<0::3, version::13>>
    length = byte_size(body)

    <<name_bytes(name)::binary-size(11), 0, 0x04, length::16-little, cv_high, 0, cv_low>> <>
      body
  end

  defp keyword_segment(kw) do
    prev = :binary.copy(<<0>>, 13)
    guide = :binary.copy(<<0>>, 13)
    field = kw <> :binary.copy(<<0>>, 13 - byte_size(kw))
    payload = prev <> guide <> field
    <<0x71, 3 + byte_size(payload)::16-little>> <> payload
  end

  # Build a tar.gz of the given [{name, bytes}] entries. erl_tar's
  # in-memory writer is awkward - go through a tmp file, read it
  # back, gzip.
  defp make_tar_gz(entries) do
    path = Path.join(System.tmp_dir!(), "obj-upload-#{System.unique_integer([:positive])}.tar")

    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write])

    Enum.each(entries, fn {name, bin} ->
      :ok = :erl_tar.add(tar, bin, String.to_charlist(name), [])
    end)

    :ok = :erl_tar.close(tar)
    bytes = File.read!(path)
    File.rm!(path)
    :zlib.gzip(bytes)
  end

  defp admin_bearer do
    admin = admin_user_fixture()
    {:ok, key} = ApiKeys.create(admin.id, %{name: "test"})
    {admin, "Bearer " <> key.plaintext}
  end

  defp post_upload(conn, bearer, body) do
    conn
    |> put_req_header("authorization", bearer)
    |> put_req_header("content-type", "application/gzip")
    |> post(~p"/api/v1/objects/upload", body)
  end

  # --- tests ---------------------------------------------------------

  describe "POST /api/v1/objects/upload" do
    test "rejects a non-admin API key with 403", %{conn: conn} do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      conn =
        post_upload(
          conn,
          "Bearer " <> key.plaintext,
          make_tar_gz([{"a.bin", build_blob(name: "A")}])
        )

      assert conn.status == 403
    end

    test "a content-operator key with objects.upload uploads successfully", %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Prodigy.Portal.Authz.grant_role(nil, user.id, "content-operator")
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      conn =
        post_upload(
          conn,
          "Bearer " <> key.plaintext,
          make_tar_gz([{"a.bin", build_blob(name: "A")}])
        )

      assert conn.status == 200
    end

    test "revoking objects.upload from the owner degrades the key to 403",
         %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Prodigy.Portal.Authz.grant_role(nil, user.id, "content-operator")
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      # Before revocation: the key works.
      body = make_tar_gz([{"a.bin", build_blob(name: "A")}])
      conn1 = post_upload(conn, "Bearer " <> key.plaintext, body)
      assert conn1.status == 200

      # Revoke the role - owner no longer holds objects.upload, so the
      # next request's intersection excludes it and we get a 403.
      {:ok, :revoked} = Prodigy.Portal.Authz.revoke_role(nil, user.id, "content-operator")

      conn2 =
        post_upload(
          build_conn(),
          "Bearer " <> key.plaintext,
          make_tar_gz([{"b.bin", build_blob(name: "B")}])
        )

      assert conn2.status == 403
    end

    test "uploads a batch of two distinct objects", %{conn: conn} do
      {_admin, bearer} = admin_bearer()

      body =
        make_tar_gz([
          {"a.bin", build_blob(name: "A")},
          {"b.bin", build_blob(name: "B")}
        ])

      conn = post_upload(conn, bearer, body)
      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)

      assert resp["counts"]["inserted"] == 2
      assert resp["counts"]["bumped"] == 0
      assert resp["counts"]["unchanged"] == 0
      assert resp["keyword_index_rebuilt"] == false
      assert resp["keyword_index"] == nil

      # Rows really landed.
      assert Repo.get_by(Object, name: "A          ", sequence: 0, type: 0x04, version: 1)
      assert Repo.get_by(Object, name: "B          ", sequence: 0, type: 0x04, version: 1)
    end

    test "a second upload with identical content lands :unchanged and doesn't rebuild", %{
      conn: conn
    } do
      {_admin, bearer} = admin_bearer()
      body = make_tar_gz([{"a.bin", build_blob(name: "A", body: keyword_segment("NEWS"))}])

      conn1 = post_upload(conn, bearer, body)
      assert conn1.status == 200
      r1 = Jason.decode!(conn1.resp_body)
      assert r1["counts"]["inserted"] == 1
      assert r1["keyword_index_rebuilt"] == true

      # A second request needs a fresh conn - but we can reuse our
      # build_conn() pathway.
      conn2 = post_upload(build_conn(), bearer, body)
      assert conn2.status == 200
      r2 = Jason.decode!(conn2.resp_body)
      assert r2["counts"]["inserted"] == 0
      assert r2["counts"]["unchanged"] == 1
      assert r2["keyword_index_rebuilt"] == false
    end

    test "rebuilds the keyword index when a keyword-carrying object is added", %{conn: conn} do
      {_admin, bearer} = admin_bearer()

      body =
        make_tar_gz([
          {"a.bin", build_blob(name: "A", body: keyword_segment("FIRST"))}
        ])

      conn = post_upload(conn, bearer, body)
      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)

      assert resp["keyword_index_rebuilt"] == true
      assert resp["keyword_index"]["total_secondaries"] == 1
      # The keyword table got exactly one entry.
      assert [%Keyword{keyword: "FIRST"}] = Repo.all(Keyword)
    end

    test "rolls back on parse error - no object rows land", %{conn: conn} do
      {_admin, bearer} = admin_bearer()

      # Second entry's blob is too short for a valid header.
      body =
        make_tar_gz([
          {"good.bin", build_blob(name: "GOOD")},
          {"bad.bin", <<0, 1, 2, 3>>}
        ])

      conn = post_upload(conn, bearer, body)
      assert conn.status == 422
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"] == "parse_errors"
      assert [%{"name" => "bad.bin", "reason" => "too_short"}] = resp["errors"]

      # GOOD was in the batch but must NOT have landed.
      refute Repo.get_by(Object, name: "GOOD       ", sequence: 0, type: 0x04, version: 1)
    end

    test "rolls back on keyword collision with a friendly error", %{conn: conn} do
      {_admin, bearer} = admin_bearer()

      body =
        make_tar_gz([
          {"a.bin", build_blob(name: "A", body: keyword_segment("DUP"))},
          {"b.bin", build_blob(name: "B", body: keyword_segment("DUP"))}
        ])

      conn = post_upload(conn, bearer, body)
      assert conn.status == 422
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"] == "insert_failed"
      # Nothing landed.
      assert Repo.all(Object) == []
    end

    test "rejects a bad gzip body with 400", %{conn: conn} do
      {_admin, bearer} = admin_bearer()
      conn = post_upload(conn, bearer, "not actually gzip")
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "bad_request"
    end

    test "rejects a valid gzip whose content is not tar with 400", %{conn: conn} do
      {_admin, bearer} = admin_bearer()
      conn = post_upload(conn, bearer, :zlib.gzip("hello world"))
      assert conn.status == 400
    end
  end
end
