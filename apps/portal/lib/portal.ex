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

defmodule Prodigy.Portal do
  @moduledoc """
  Entry module providing `use Prodigy.Portal, :controller` / `:router` /
  `:html` / `:verified_routes` idioms for the web tier.
  """

  @doc """
  Returns the list of OAuth providers that have credentials configured at
  runtime. Used by the login page to hide buttons for providers we don't
  have keys for. The dev-only mock login has its own button path
  (`/dev/mock-login`) and is gated separately via `Application.get_env(:portal, :dev_routes)`.
  """
  def available_oauth_providers do
    [
      {:google, "Google",
       Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)[:client_id]},
      {:github, "GitHub",
       Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)[:client_id]}
    ]
    |> Enum.filter(fn {_id, _label, client_id} ->
      is_binary(client_id) and client_id != ""
    end)
    |> Enum.map(fn {id, label, _client_id} -> {id, label} end)
  end

  def controller do
    quote do
      # No inner `layouts:` - controllers render directly into root's
      # @inner_content via the Router's :put_root_layout plug. The `app`
      # template is a *component* (used explicitly via <Layouts.app> by LiveViews),
      # not a traditional inner layout.
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  def live_view do
    quote do
      # layout: false - LiveView renders wrap themselves in <Layouts.app> explicitly
      # per Phoenix 1.7 generator convention; the root layout is applied by
      # the Router's :put_root_layout pipeline plug.
      use Phoenix.LiveView, layout: false
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Prodigy.Portal.CoreComponents
      import Prodigy.Portal.Components.AuthCard
      use Gettext, backend: Prodigy.Portal.Gettext
      alias Prodigy.Portal.Layouts
      alias Phoenix.LiveView.JS
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Prodigy.Portal.Endpoint,
        router: Prodigy.Portal.Router
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
