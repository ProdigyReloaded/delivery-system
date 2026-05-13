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

defmodule Prodigy.Portal.AdminLive.Layouts do
  @moduledoc """
  Shared chrome for admin-console pages - the left sidebar with
  Portal / Service sections, and helpers for building it.

  The admin area uses one route per page (e.g. `/admin/service/users`,
  `/admin/portal/roles`). Each page LiveView wraps its content in
  `<.wrapper>` so every page gets the same sidebar + title bar. The
  sidebar items are filtered by `Prodigy.Portal.Authz.can?/3` against
  the caller's scope, so operators see a nav tailored to their scope
  set.
  """

  use Prodigy.Portal, :html

  alias Prodigy.Portal.Authz

  # Sidebar nav data. Each item carries the URL + the scope needed to
  # see it. An item whose scope is missing hides; a section whose
  # items all hide collapses to nothing.
  @nav_sections [
    %{
      id: :portal,
      label: "Portal",
      items: [
        %{id: :portal_users, label: "Users", path: "/admin/portal/users",
          scope: {:portal_users, :view}},
        %{id: :portal_roles, label: "Roles", path: "/admin/portal/roles",
          scope: {:roles, :view}},
        %{id: :portal_audit, label: "Audit Log", path: "/admin/portal/audit",
          scope: {:system, :view_audit_log}},
        %{id: :portal_settings, label: "Settings", path: "/admin/portal/settings",
          scope: {:system, :settings}}
      ]
    },
    %{
      id: :service,
      label: "Service",
      items: [
        %{id: :online, label: "Online", path: "/admin/service/online",
          scope: {:service_users, :view}},
        %{id: :users, label: "Users", path: "/admin/service/users",
          scope: {:service_users, :view}},
        %{id: :events, label: "Events", path: "/admin/service/events",
          scope: {:service_users, :view}},
        %{id: :objects, label: "Objects", path: "/admin/service/objects",
          scope: {:objects, :view}},
        %{id: :keywords, label: "Keywords", path: "/admin/service/keywords",
          scope: {:keywords, :view}}
      ]
    }
  ]

  @doc "Full nav data structure; useful for tests."
  def nav_sections, do: @nav_sections

  @doc """
  Returns the path of the first nav item the given scope can see, or
  `nil` if none. Used by `/admin` to redirect into whichever landing
  page the caller has access to.
  """
  def default_path_for(nil), do: nil

  def default_path_for(scope) do
    @nav_sections
    |> Enum.flat_map(& &1.items)
    |> Enum.find(fn %{scope: {r, a}} -> Authz.can?(scope, r, a) end)
    |> case do
      nil -> nil
      item -> item.path
    end
  end

  # --------------------------------------------------------------
  # Render helpers
  # --------------------------------------------------------------

  attr :active, :atom,
    required: true,
    doc: "id of the currently-active nav item (e.g. :users)"

  attr :current_scope, :any, required: true
  attr :flash, :map, required: true

  attr :page_title, :string,
    default: nil,
    doc: "display title for the page header (falls back to the active item's label)"

  slot :inner_block, required: true

  def wrapper(assigns) do
    visible_sections = visible_sections(assigns.current_scope)
    active_label = active_label(assigns.active, visible_sections)

    assigns =
      assigns
      |> assign(:visible_sections, visible_sections)
      |> assign(:active_label, active_label)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="admin-shell d-flex">
        <aside class="admin-sidebar border-end pe-3 me-3" style="width: 180px; min-width: 180px; max-width: 180px; flex-shrink: 0;">
          <div :for={section <- @visible_sections} class="mb-4">
            <h6 class="text-uppercase text-muted small mb-2">{section.label}</h6>
            <ul class="nav flex-column">
              <li :for={item <- section.items} class="nav-item">
                <.link
                  navigate={item.path}
                  class={nav_link_class(item.id == @active)}
                >
                  {item.label}
                </.link>
              </li>
            </ul>
          </div>
        </aside>

        <section class="admin-content flex-grow-1">
          <header class="mb-3 pb-2 border-bottom">
            <h1 class="h3 mb-0">{@page_title || @active_label}</h1>
          </header>
          {render_slot(@inner_block)}
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp visible_sections(scope) do
    @nav_sections
    |> Enum.map(fn section ->
      %{section | items: visible_items(section.items, scope)}
    end)
    |> Enum.reject(fn section -> section.items == [] end)
  end

  defp visible_items(items, scope) do
    Enum.filter(items, fn %{scope: {r, a}} -> Authz.can?(scope, r, a) end)
  end

  defp active_label(active_id, sections) do
    sections
    |> Enum.flat_map(& &1.items)
    |> Enum.find_value(fn item ->
      if item.id == active_id, do: item.label
    end)
  end

  defp nav_link_class(true), do: "nav-link active fw-semibold"
  defp nav_link_class(false), do: "nav-link text-body-secondary"
end
