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

defmodule Mix.Tasks.Prodigy.Portal.ApiKey do
  @shortdoc "Provision a portal account + scoped API key (idempotent)"

  @moduledoc """
  Provisions a non-interactive portal account and mints an API key for it -
  the reproducible replacement for hand-running `ApiKeys.create/2` in IEx.
  Built for automation identities like the `content-batch` weather uploader.

  Wraps `Prodigy.Portal.Provisioning.ensure_api_key/1`: get-or-create the
  account by email, grant each scope, then mint the key (unless a live key of
  the same name already exists).

  ## Usage

      mix prodigy.portal.api_key EMAIL --name NAME [--scope SCOPE]... [--force]

  ## Options

      --name NAME    Display name for the key; also the idempotency key -
                     a second run with the same name will NOT re-mint.
      --scope SCOPE  Scope to grant the account and attach to the key.
                     Repeatable. e.g. --scope objects.upload
      --force        Mint a new key even if one named NAME already exists
                     (use to rotate; revoke the old one afterward).

  ## Example - the content-batch uploader

      mix prodigy.portal.api_key content-batch@example.com \\
        --name content-batch --scope objects.upload

  ## Production

  A release has no Mix. Run the same logic against the live prod node:

      bin/server rpc 'Prodigy.Portal.Provisioning.ensure_api_key(%{
        email: "content-batch@example.com", name: "content-batch",
        scopes: ["objects.upload"]}) |> IO.inspect()'

  ## Idempotency

  Account + scope grants are get-or-create / upsert. The key is minted only
  when no live key of that name exists (the plaintext is show-once and cannot
  be reproduced), so re-running reports "already exists" instead of piling up
  duplicate keys.
  """

  use Mix.Task

  # `compile` only, not `app.start`: like prodigy.seed, avoid booting `:server`
  # (it binds the TCS port and collides with a running `mix phx.server`). We
  # start just `:core` below for the Repo.
  @requirements ["compile"]

  alias Prodigy.Portal.Provisioning

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [name: :string, scope: :keep, force: :boolean]
      )

    email = List.first(args) || usage("EMAIL is required")
    name = opts[:name] || usage("--name is required")
    scopes = for {:scope, s} <- opts, do: s
    if scopes == [], do: usage("at least one --scope is required (e.g. --scope objects.upload)")

    {:ok, _} = Application.ensure_all_started(:core)

    case Provisioning.ensure_api_key(%{
           email: email,
           name: name,
           scopes: scopes,
           force: !!opts[:force]
         }) do
      {:minted, plaintext} ->
        Mix.shell().info(
          "Minted key '#{name}' for #{email} (scopes: #{Enum.join(scopes, ", ")})."
        )

        Mix.shell().info("Show-once plaintext - store it now:\n\n    #{plaintext}\n")

      {:exists, _key} ->
        Mix.shell().info(
          "A live key named '#{name}' already exists for #{email}; not re-minting."
        )

        Mix.shell().info("To rotate: revoke it in the portal, or re-run with --force.")

      {:error, {:unknown_scopes, unknown}} ->
        Mix.raise("unknown scope(s): #{Enum.join(unknown, ", ")}")

      {:error, reason} ->
        Mix.raise("could not provision key: #{inspect(reason)}")
    end
  end

  defp usage(msg) do
    Mix.raise(
      "#{msg}\n\n  mix prodigy.portal.api_key EMAIL --name NAME [--scope SCOPE]... [--force]"
    )
  end
end
