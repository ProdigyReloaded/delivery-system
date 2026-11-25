# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Mix.Tasks.Prodigy.Gcu do
  use Mix.Task
  @shortdoc "List or replace text runs in a GCU recipe without starting the database"
  @moduledoc """
  See docs/gcu-templates.md for the supported format and examples.
  """
  def run(args) do
    Mix.Task.run("compile")

    case Prodigy.OdbUtil.GcuCLI.run(args) do
      0 -> :ok
      _ -> Mix.raise("GCU command failed")
    end
  end
end
