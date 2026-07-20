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

defmodule Mix.Tasks.Prodigy.MemberList do
  @shortdoc "Regenerate the Member List CCDAM data set from the live opted-in user table"

  @moduledoc """
  Runs `Prodigy.Server.MemberList.Generator.run/1` against the
  configured Repo. Same code path the nightly Quantum job takes; this
  task just lets you fire it on demand from the shell.

  ## Usage

      mix prodigy.member_list [--version N]

  ## Options

      --version N   Object version byte to stamp into every generated
                    object. Default 1. Doesn't really matter since
                    candidacy is `:none` (the client never version-checks
                    these), but exposed in case you want to track runs.

  ## On a release

  This task is for dev/manual use against a `mix`-run server. On a
  packaged release the equivalent is

      bin/server rpc 'Prodigy.Server.MemberList.Generator.run()'

  ## Idempotency

  `Generator` uses `Store.reconcile_prefix` which atomically replaces
  the prior run's `3B`/`3L`/`MSPLSTAT` objects with the new set, so this
  is safe to invoke any number of times.
  """

  use Mix.Task

  # Only require `compile` (not `app.start`) so the umbrella doesn't
  # boot `:server` and bind TCS port 25234 - matches the convention
  # established by `prodigy.seed`. We start `:core` ourselves below;
  # `:server` doesn't need to be running to call the Generator (it just
  # uses the Repo plus its own pure modules).
  @requirements ["compile"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [version: :integer])

    {:ok, _} = Application.ensure_all_started(:core)

    case Prodigy.Server.MemberList.Generator.run(version: opts[:version] || 1) do
      {:ok, %{members: m, upserted: u, deleted: d}} ->
        Mix.shell().info("Member List regenerated: #{m} member(s), #{u} object(s) upserted, #{d} stale dropped.")

      {:error, reason} ->
        Mix.shell().error("Member List regeneration failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
