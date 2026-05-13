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

defmodule ImportTest do
  use ExUnit.Case, async: true

  describe "resolve_api_key/1" do
    test "reads from --api-key-file, trimming trailing whitespace" do
      path = Path.join(System.tmp_dir!(), "podbutil-key-#{System.unique_integer([:positive])}")
      File.write!(path, "  pk_abcdef\n")

      try do
        assert {:ok, "pk_abcdef"} = Import.resolve_api_key(%{api_key_file: path})
      after
        File.rm(path)
      end
    end

    test "returns an error when --api-key-file points nowhere" do
      assert {:error, msg} = Import.resolve_api_key(%{api_key_file: "/nonexistent/podbutil-key"})
      assert msg =~ "cannot read"
    end

    test "reads from --api-key-env when set" do
      var = "PODBUTIL_TEST_KEY_#{System.unique_integer([:positive])}"
      System.put_env(var, "pk_fromenv")

      try do
        assert {:ok, "pk_fromenv"} = Import.resolve_api_key(%{api_key_env: var})
      after
        System.delete_env(var)
      end
    end

    test "errors when --api-key-env is set but the variable isn't" do
      var = "PODBUTIL_MISSING_#{System.unique_integer([:positive])}"
      assert {:error, msg} = Import.resolve_api_key(%{api_key_env: var})
      assert msg =~ var
    end

    test "falls back to PRODIGY_API_KEY when no flags are given" do
      # Save/restore so this test doesn't step on other tests.
      prior = System.get_env("PRODIGY_API_KEY")
      System.put_env("PRODIGY_API_KEY", "pk_default")

      try do
        assert {:ok, "pk_default"} = Import.resolve_api_key(%{})
      after
        if prior, do: System.put_env("PRODIGY_API_KEY", prior), else: System.delete_env("PRODIGY_API_KEY")
      end
    end

    test "errors with helpful message when no key source is configured" do
      prior = System.get_env("PRODIGY_API_KEY")
      System.delete_env("PRODIGY_API_KEY")

      try do
        assert {:error, msg} = Import.resolve_api_key(%{})
        assert msg =~ "--api-key-file"
        assert msg =~ "PRODIGY_API_KEY"
      after
        if prior, do: System.put_env("PRODIGY_API_KEY", prior)
      end
    end
  end

  describe "build_tar_gz/1" do
    test "produces a tar.gz whose entries match the input files" do
      dir = Path.join(System.tmp_dir!(), "podbutil-src-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      p1 = Path.join(dir, "a.bin")
      p2 = Path.join(dir, "b.bin")
      File.write!(p1, "alpha")
      File.write!(p2, "beta-contents")

      try do
        assert {:ok, gzipped} = Import.build_tar_gz([p1, p2])
        assert byte_size(gzipped) > 0
        tar_bytes = :zlib.gunzip(gzipped)

        assert {:ok, entries} = :erl_tar.extract({:binary, tar_bytes}, [:memory])
        entries = Enum.map(entries, fn {n, b} -> {List.to_string(n), b} end)

        assert {"a.bin", "alpha"} in entries
        assert {"b.bin", "beta-contents"} in entries
      after
        File.rm_rf!(dir)
      end
    end

    test "uses basenames, not full paths, as tar entry names" do
      dir = Path.join(System.tmp_dir!(), "podbutil-src-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "deep/nested"))
      p = Path.join([dir, "deep", "nested", "thing.bin"])
      File.write!(p, "payload")

      try do
        {:ok, gzipped} = Import.build_tar_gz([p])
        tar_bytes = :zlib.gunzip(gzipped)
        {:ok, [{name, _}]} = :erl_tar.extract({:binary, tar_bytes}, [:memory])
        assert List.to_string(name) == "thing.bin"
      after
        File.rm_rf!(dir)
      end
    end
  end
end
