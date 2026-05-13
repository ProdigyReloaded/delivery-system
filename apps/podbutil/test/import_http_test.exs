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

defmodule ImportHttpTest do
  @moduledoc """
  Coverage for the `--url` HTTP-mode of `podbutil import`. The tarball
  shape is verified by unit-testing `build_tar_gz/1` directly. The
  full POST round-trip is exercised against a tiny Plug listener so
  the assertions cover what actually goes out on the wire (method,
  path, auth header, content-type, gzipped body) rather than what we
  hope goes out.

  The unhappy paths (4xx / 5xx, network errors) call `System.halt/1`
  inside `report_http_result/2` and `post_upload/4` respectively,
  which would kill the test BEAM; covering those would require
  refactoring `exec_http/2` to return tagged tuples instead of
  halting. Out of scope here.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup_all do
    Application.ensure_all_started(:plug_cowboy)
    :ok
  end

  describe "build_tar_gz/1" do
    test "produces a gzipped tar containing the input files at top level" do
      dir = make_tmp_dir()

      path_a = Path.join(dir, "a.pgm")
      path_b = Path.join(dir, "b.pgm")
      File.write!(path_a, "AAAA")
      File.write!(path_b, "BBBB")

      assert {:ok, body} = Import.build_tar_gz([path_a, path_b])

      # Gzip magic bytes (0x1F 0x8B).
      assert <<0x1F, 0x8B, _rest::binary>> = body

      # Round-trip: ungzip and untar, confirm both files land at the
      # archive root keyed by their basename (not their full path).
      tar = :zlib.gunzip(body)
      assert {:ok, entries} = :erl_tar.extract({:binary, tar}, [:memory])

      by_name = Map.new(entries, fn {n, c} -> {to_string(n), c} end)
      assert by_name["a.pgm"] == "AAAA"
      assert by_name["b.pgm"] == "BBBB"
    end

    test "skips a missing file gracefully via {:error, _}" do
      assert {:error, msg} = Import.build_tar_gz(["/no/such/path.pgm"])
      assert msg =~ "could not build tar.gz"
    end
  end

  describe "exec_http/2 happy path against a real local HTTP listener" do
    test "POSTs to /api/v1/objects/upload with bearer auth + gzip body, parses success JSON" do
      # Set up a one-shot listener that captures the inbound request
      # for assertion, then returns the same JSON shape the real
      # /api/v1/objects/upload endpoint emits on a clean import.
      ref = make_ref()
      parent = self()

      port = start_capture_listener(ref, parent)

      dir = make_tmp_dir()
      file = Path.join(dir, "test.pgm")
      File.write!(file, String.duplicate("X", 32))

      key_path = Path.join(dir, "podbutil.key")
      File.write!(key_path, "pk_under_test\n")

      output =
        capture_io(fn ->
          Import.exec_http(
            [file],
            %{url: "http://localhost:#{port}", api_key_file: key_path}
          )
        end)

      # The success-output line is what an operator sees when --url
      # works. If this assertion fails, the wire format is wrong or
      # the response decoder broke.
      assert output =~ "Uploaded: 1 new"

      # Inspect the captured request.
      assert_receive {^ref, captured}, 5_000
      assert captured.method == "POST"
      assert captured.path == "/api/v1/objects/upload"
      assert captured.auth == "Bearer pk_under_test"
      assert captured.content_type =~ "application/gzip"
      assert <<0x1F, 0x8B, _::binary>> = captured.body

      # The body the server received should round-trip back to the
      # one file we put in.
      tar = :zlib.gunzip(captured.body)
      assert {:ok, entries} = :erl_tar.extract({:binary, tar}, [:memory])
      assert {~c"test.pgm", _} = List.keyfind(entries, ~c"test.pgm", 0)
    end
  end

  # --- helpers ----------------------------------------------------------

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "podbutil-http-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Starts a Plug.Cowboy listener on an OS-assigned port that records the
  # inbound request and replies 200 with a hardcoded success-shape JSON.
  defp start_capture_listener(ref, parent) do
    listener_ref = {:capture, System.unique_integer([:positive])}

    {:ok, _pid} =
      Plug.Cowboy.http(ImportHttpTest.CapturePlug, %{ref: ref, parent: parent},
        port: 0,
        ref: listener_ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(listener_ref) end)

    :ranch.get_port(listener_ref)
  end
end

defmodule ImportHttpTest.CapturePlug do
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, %{ref: ref, parent: parent}) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)

    captured = %{
      method: conn.method,
      path: conn.request_path,
      auth: List.first(Plug.Conn.get_req_header(conn, "authorization")),
      content_type: List.first(Plug.Conn.get_req_header(conn, "content-type")),
      body: body
    }

    send(parent, {ref, captured})

    body =
      Jason.encode!(%{
        counts: %{inserted: 1, bumped: 0, unchanged: 0, errors: 0},
        keyword_index_rebuilt: false
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end
end
