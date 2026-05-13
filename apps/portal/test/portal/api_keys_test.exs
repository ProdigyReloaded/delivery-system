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

defmodule Prodigy.Portal.ApiKeysTest do
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Core.Data.Portal.ApiKey
  alias Prodigy.Portal.ApiKeys

  import Prodigy.Portal.AccountsFixtures

  describe "generate/0" do
    test "produces a well-formed pk_... token, 8-char prefix, and SHA-256 hash" do
      {plaintext, prefix, hash} = ApiKey.generate()

      assert String.starts_with?(plaintext, "pk_")
      # "pk_" + 26 base32 chars = 29 total.
      assert String.length(plaintext) == 29
      assert prefix == String.slice(plaintext, 0, 8)
      assert byte_size(hash) == 32
      assert hash == :crypto.hash(:sha256, plaintext)
    end

    test "distinct calls produce distinct plaintexts" do
      {p1, _, _} = ApiKey.generate()
      {p2, _, _} = ApiKey.generate()
      refute p1 == p2
    end
  end

  describe "create/2" do
    test "inserts a key, returns the plaintext once, and stores only the hash" do
      user = user_fixture()

      assert {:ok, %ApiKey{} = key} = ApiKeys.create(user.id, %{name: "laptop"})

      assert key.name == "laptop"
      assert key.user_id == user.id
      assert is_binary(key.plaintext)
      assert String.starts_with?(key.plaintext, "pk_")
      assert key.key_prefix == String.slice(key.plaintext, 0, 8)
      assert key.key_hash == :crypto.hash(:sha256, key.plaintext)
      assert is_nil(key.revoked_at)
      assert is_nil(key.last_used_at)

      # Reloading from the DB does not leak the plaintext.
      reloaded = Repo.get!(ApiKey, key.id)
      assert is_nil(reloaded.plaintext)
      assert reloaded.key_hash == key.key_hash
    end

    test "requires a name" do
      user = user_fixture()
      assert {:error, changeset} = ApiKeys.create(user.id, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an unknown user_id" do
      assert {:error, changeset} = ApiKeys.create(0, %{name: "ghost"})
      assert %{user: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "list_for_user/1" do
    test "returns that user's keys newest-first, with plaintext nil" do
      user = user_fixture()
      {:ok, older} = ApiKeys.create(user.id, %{name: "older"})
      # Force a guaranteed later inserted_at.
      :timer.sleep(2)
      {:ok, newer} = ApiKeys.create(user.id, %{name: "newer"})

      listed = ApiKeys.list_for_user(user.id)

      assert Enum.map(listed, & &1.id) == [newer.id, older.id]
      assert Enum.all?(listed, &is_nil(&1.plaintext))
    end

    test "does not leak other users' keys" do
      alice = user_fixture()
      bob = user_fixture()

      {:ok, _} = ApiKeys.create(alice.id, %{name: "alice-key"})
      {:ok, _} = ApiKeys.create(bob.id, %{name: "bob-key"})

      assert [key] = ApiKeys.list_for_user(alice.id)
      assert key.name == "alice-key"
    end
  end

  describe "revoke/2" do
    test "stamps revoked_at on a live key" do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      assert {:ok, revoked} = ApiKeys.revoke(user.id, key.id)
      assert %DateTime{} = revoked.revoked_at
    end

    test "returns :not_found when the key belongs to another user" do
      alice = user_fixture()
      bob = user_fixture()
      {:ok, key} = ApiKeys.create(alice.id, %{name: "alice-k"})

      assert :not_found = ApiKeys.revoke(bob.id, key.id)
    end

    test "returns :not_found when the id doesn't exist" do
      user = user_fixture()
      assert :not_found = ApiKeys.revoke(user.id, 999_999_999)
    end

    test "is idempotent on an already-revoked key" do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})
      {:ok, once} = ApiKeys.revoke(user.id, key.id)
      {:ok, twice} = ApiKeys.revoke(user.id, key.id)

      assert once.revoked_at == twice.revoked_at
    end
  end

  describe "verify/1" do
    test "returns {:ok, user, key_id, scopes} for a live key" do
      user = user_fixture()
      {:ok, _} = Prodigy.Portal.Authz.grant_scope(nil, user.id, "objects.upload")
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      assert {:ok, verified, id, effective} = ApiKeys.verify(key.plaintext)
      assert verified.id == user.id
      assert id == key.id
      assert MapSet.member?(effective, "objects.upload")
    end

    test "returns :invalid for an unknown key" do
      assert :invalid = ApiKeys.verify("pk_" <> String.duplicate("a", 26))
    end

    test "returns :invalid for a revoked key" do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})
      {:ok, _} = ApiKeys.revoke(user.id, key.id)

      assert :invalid = ApiKeys.verify(key.plaintext)
    end

    test "returns :invalid for a malformed or short token" do
      assert :invalid = ApiKeys.verify("")
      assert :invalid = ApiKeys.verify("pk_xx")
      assert :invalid = ApiKeys.verify(123)
    end

    test "a key with the same prefix but different hash does not match" do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})

      # Flip one character in the suffix - prefix stays, hash differs.
      <<prefix::binary-size(10), c::binary-size(1), rest::binary>> = key.plaintext
      swapped = if c == "a", do: "b", else: "a"
      tampered = prefix <> swapped <> rest

      assert :invalid = ApiKeys.verify(tampered)
    end
  end

  describe "scope attachment" do
    alias Prodigy.Portal.Authz

    test "a key without explicit scopes inherits the owner's non-forbidden scopes" do
      admin = admin_user_fixture()
      {:ok, key} = ApiKeys.create(admin.id, %{name: "k"})

      # Every admin-non-forbidden scope should be on the key; forbidden ones never are.
      for s <- Authz.all_scopes(), s not in Authz.forbidden_for_api_keys() do
        assert s in key.scopes, "expected #{s} on inherited key"
      end

      for s <- Authz.forbidden_for_api_keys() do
        refute s in key.scopes, "forbidden scope #{s} should never attach"
      end
    end

    test "explicit empty scopes list mints a capability-less key" do
      admin = admin_user_fixture()
      {:ok, key} = ApiKeys.create(admin.id, %{name: "tight", scopes: []})
      assert key.scopes == []
    end

    test "scope not held by the owner is refused" do
      user = user_fixture()
      # user has no scopes; asking for objects.upload is an escalation attempt
      assert {:error, changeset} =
               ApiKeys.create(user.id, %{name: "k", scopes: ["objects.upload"]})

      assert %{scopes: [msg]} = errors_on(changeset)
      assert msg =~ "not held by the owner"
    end

    test "forbidden-for-keys scope is refused even if the owner holds it" do
      admin = admin_user_fixture()
      assert {:error, changeset} =
               ApiKeys.create(admin.id, %{name: "k", scopes: ["grants.assign"]})

      assert %{scopes: [msg]} = errors_on(changeset)
      assert msg =~ "cannot attach to an API key"
    end

    test "unknown scope string is refused" do
      admin = admin_user_fixture()
      assert {:error, changeset} =
               ApiKeys.create(admin.id, %{name: "k", scopes: ["does.not.exist"]})

      assert %{scopes: [msg]} = errors_on(changeset)
      assert msg =~ "unknown scope"
    end

    test "effective_scopes_for/2 intersects key scopes with owner scopes" do
      user = user_fixture()
      {:ok, _} = Authz.grant_scope(nil, user.id, "objects.upload")
      {:ok, _} = Authz.grant_scope(nil, user.id, "objects.view")

      {:ok, key} =
        ApiKeys.create(user.id, %{name: "k", scopes: ["objects.upload", "objects.view"]})

      # Revoke one scope from the owner - the key's effective set drops
      # that scope even though key.scopes still lists it.
      {:ok, _} = Authz.revoke_scope(nil, user.id, "objects.upload")

      user = Prodigy.Core.Data.Repo.get!(Prodigy.Core.Data.Portal.User, user.id)
      effective = ApiKeys.effective_scopes_for(user, key.scopes)

      assert "objects.view" in effective
      refute "objects.upload" in effective
    end

    test "verify/1 returns the intersection as the fourth tuple element" do
      admin = admin_user_fixture()
      {:ok, key} = ApiKeys.create(admin.id, %{name: "k", scopes: ["objects.upload"]})

      assert {:ok, _user, _id, effective} = ApiKeys.verify(key.plaintext)
      assert MapSet.member?(effective, "objects.upload")
      refute MapSet.member?(effective, "objects.delete")
    end
  end

  describe "touch/1" do
    test "updates last_used_at for a live key" do
      user = user_fixture()
      {:ok, key} = ApiKeys.create(user.id, %{name: "k"})
      assert is_nil(key.last_used_at)

      assert 1 = ApiKeys.touch(key.id)
      reloaded = Repo.get!(ApiKey, key.id)
      assert %DateTime{} = reloaded.last_used_at
    end

    test "returns 0 for an unknown id" do
      assert 0 = ApiKeys.touch(999_999_999)
    end
  end
end
