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

defmodule Mix.Tasks.Prodigy.Seed do
  @shortdoc "Seed dev DB with objects + AAAA11A + DEMO99A"

  @moduledoc """
  Seeds a fresh dev database: clones the ProdigyReloaded/objects catalog,
  imports every .pgm under it, and creates the two service-side users
  the /start page advertises (AAAA11A with single-session concurrency,
  DEMO99A with unlimited concurrency + pre-enrollment).

  This is the method-a / method-b equivalent of compose's `db-seed`
  service (which runs `apps/server/seed.sh` inside a container against
  the prod release binaries). Same outcome; different runtime.

  ## Usage

      mix prodigy.seed [--objects PATH] [--skip-objects]

  ## Options

      --objects PATH    Path to a checkout of ProdigyReloaded/objects.
                        Defaults to ~/.cache/prodigy/objects (cloned
                        on first run, reused on subsequent runs).

      --skip-objects    Skip the object import (portal-only setup).

  ## Idempotency

  Object imports use content-hash deduplication, so re-running is safe
  (already-imported objects are reported as "unchanged"). User creation
  reports "household exists" on a re-run and skips, so this task can be
  re-invoked without resetting the database.
  """

  use Mix.Task

  # Only require `compile`, not `app.start` - Mix in an umbrella otherwise
  # boots every app (including `:server` which binds TCS port 25234), and
  # that collides with a developer's already-running `mix phx.server`.
  @requirements ["compile"]

  alias Prodigy.Core.Data.Service.Enroller

  @default_objects_path Path.join([System.user_home!(), ".cache", "prodigy", "objects"])
  @objects_repo_url "https://github.com/ProdigyReloaded/objects.git"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [objects: :string, skip_objects: :boolean]
      )

    # Start only what we need - the core app brings up the Repo. We
    # don't want `mix app.start` here because it would also start the
    # `:server` app, which binds the TCS port (25234) and would
    # conflict with a developer's already-running `mix phx.server`.
    {:ok, _} = Application.ensure_all_started(:core)

    unless opts[:skip_objects] do
      objects_path = opts[:objects] || ensure_objects_clone()
      import_objects(objects_path)
    end

    create_init_user()
    create_demo_user()

    Mix.shell().info("Seed completed.")
  end

  defp ensure_objects_clone do
    path = @default_objects_path

    if File.dir?(Path.join(path, ".git")) do
      Mix.shell().info("Using existing objects checkout at #{path}")
      path
    else
      File.mkdir_p!(Path.dirname(path))
      Mix.shell().info("Cloning #{@objects_repo_url} to #{path}")
      {_out, 0} = System.cmd("git", ["clone", @objects_repo_url, path], into: IO.stream(:stdio, :line))
      path
    end
  end

  defp import_objects(path) do
    Mix.shell().info("Importing objects from #{path}")
    Import.exec([path])
  end

  defp create_init_user do
    init_user = System.get_env("INIT_USER") || "AAAA11"
    init_pass = System.get_env("INIT_PASS") || "SECRET"

    case Enroller.create_subscriber(init_user, init_pass, concurrency_limit: 1) do
      {:ok, {_household, user}} ->
        Mix.shell().info("- Created household #{init_user}")
        Mix.shell().info("- Created user #{user.id} with password #{init_pass}")
        Mix.shell().info("   * Concurrency limit: 1 concurrent session")

      {:error, :household_exists} ->
        Mix.shell().info("- Household #{init_user} already exists; skipping.")

      {:error, reason} ->
        Mix.shell().error("Failed to create init user: #{inspect(reason)}")
    end
  end

  defp create_demo_user do
    case Enroller.create_subscriber("DEMO99", "SECRET",
           concurrency_limit: 0,
           enroll_name: {"Demo", "Subscriber"}
         ) do
      {:ok, {_household, user}} ->
        Mix.shell().info("- Created household DEMO99")
        Mix.shell().info("- Created user #{user.id} with password SECRET")
        Mix.shell().info("   * Concurrency limit: unlimited concurrent sessions")
        Mix.shell().info("   * Pre-enrolled as Demo Subscriber")

      {:error, :household_exists} ->
        Mix.shell().info("- Household DEMO99 already exists; skipping.")

      {:error, reason} ->
        Mix.shell().error("Failed to create demo user: #{inspect(reason)}")
    end
  end
end
