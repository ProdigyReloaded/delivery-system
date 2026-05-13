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

defmodule Prodigy.Portal.AdminLive.TableHelpers do
  @moduledoc """
  Shared bits used by admin tab LiveViews:

    * the `col_header/1` function component for sortable table headers
    * tiny formatting helpers for fields that appear on more than one tab
    * `require_scope/3`, the per-event authorization guard

  The sort/filter pipeline itself lives per-tab because each table has
  different extractable fields and type-specific sort ordering.
  """

  use Phoenix.Component

  alias Phoenix.LiveView
  alias Prodigy.Core.Data.Service.User
  alias Prodigy.Portal.Authz

  @doc """
  Initial page size + load-more increment for every paginated admin
  table. Centralised so a change to "how many rows per scroll" is a
  one-line edit instead of a grep-and-replace.
  """
  @spec page_size() :: pos_integer()
  def page_size, do: 50

  attr :by, :atom, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :target, :any, default: nil
  slot :inner_block, required: true

  @doc """
  Sortable column header. `target` is the LiveComponent's `@myself` so the
  "sort" event is routed back to the component instead of the parent.
  """
  def col_header(assigns) do
    ~H"""
    <th>
      <a
        href="#"
        phx-click="sort"
        phx-value-by={@by}
        phx-target={@target}
        class="text-decoration-none text-body"
      >
        {render_slot(@inner_block)}
        <span :if={@sort_by == @by} class="small text-muted">
          {if @sort_dir == :asc, do: "▲", else: "▼"}
        </span>
      </a>
    </th>
    """
  end

  @doc "Canonical \"First Last\" display string, JSONB-sourced."
  def full_name(%User{} = user), do: User.full_name(user)
  def full_name(_), do: ""

  @doc "Portal email of a service user, or an em-dash when unlinked."
  def portal_email(%{portal_user: %{email: email}}) when is_binary(email), do: email
  def portal_email(_), do: "-"

  def toggle_dir(:asc), do: :desc
  def toggle_dir(:desc), do: :asc

  @doc """
  Per-event authorization guard for admin LVs. Returns `:ok` when the
  caller should proceed, or a fully-formed `{:noreply, socket}` reply
  (with a "Not authorized." flash) when they should not. Designed to
  be used at the head of a `with` chain inside a handle_event:

      def handle_event("delete", %{"id" => id}, socket) do
        with :ok <- require_scope(socket, :service_users, :delete) do
          do_delete(socket, id)
        end
      end
  """
  @spec require_scope(LiveView.Socket.t(), atom(), atom()) ::
          :ok | {:noreply, LiveView.Socket.t()}
  def require_scope(%LiveView.Socket{} = socket, resource, action)
      when is_atom(resource) and is_atom(action) do
    if Authz.can?(socket.assigns[:current_scope], resource, action) do
      :ok
    else
      {:noreply, LiveView.put_flash(socket, :error, "Not authorized.")}
    end
  end

  @doc """
  Slice a list into one page. Returns `{page_rows, total_pages, normalized_page}`
  where `normalized_page` is the actual page displayed - clamped into
  `1..total_pages` so switching from a filter that shows 10 pages to one
  that shows 2 doesn't leave the user on page 10.
  """
  def paginate(rows, page, page_size) when is_integer(page) and page_size > 0 do
    total = length(rows)
    total_pages = max(1, div(total + page_size - 1, page_size))
    current = page |> max(1) |> min(total_pages)
    offset = (current - 1) * page_size
    {Enum.slice(rows, offset, page_size), total_pages, current}
  end

  attr :id, :string, required: true
  attr :target, :any, default: nil
  attr :done, :boolean, default: false, doc: "render a terminal marker instead of a live sentinel"

  @doc """
  Marker element for the InfiniteScroll JS hook. Place this immediately
  after the table inside the `.admin-table-scroll` container. When the
  element enters the scroll viewport, the hook pushes a "load_more"
  event to the element's `phx-target`. Renders nothing visible (a thin
  div with no content) so it doesn't disturb the table footer.

  Pass `done={true}` once all rows are visible to freeze scroll-driven
  loads; useful to avoid a flicker loop when visible_count >= total.
  """
  def scroll_sentinel(%{done: true} = assigns) do
    ~H"""
    <div id={@id} class="admin-table-sentinel" aria-hidden="true"></div>
    """
  end

  def scroll_sentinel(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="InfiniteScroll"
      phx-target={@target}
      class="admin-table-sentinel"
      aria-hidden="true"
    >
    </div>
    """
  end

  attr :current, :integer, required: true
  attr :total, :integer, required: true
  attr :target, :any, default: nil

  @doc """
  Bootstrap-styled pagination footer. Shows Prev / page-N-of-M / Next.
  Event name is "page", value is the integer page number. Renders
  nothing if there's only one page (avoids footer chrome when the full
  dataset fits on a single page).
  """
  def pagination(assigns) do
    ~H"""
    <nav :if={@total > 1} aria-label="Table pagination" class="d-flex justify-content-between align-items-center mt-2">
      <span class="text-muted small">
        Page {@current} of {@total}
      </span>
      <ul class="pagination pagination-sm mb-0">
        <li class={["page-item", @current == 1 && "disabled"]}>
          <a
            class="page-link"
            href="#"
            phx-click="page"
            phx-value-page={@current - 1}
            phx-target={@target}
          >
            Previous
          </a>
        </li>
        <li class={["page-item", @current == @total && "disabled"]}>
          <a
            class="page-link"
            href="#"
            phx-click="page"
            phx-value-page={@current + 1}
            phx-target={@target}
          >
            Next
          </a>
        </li>
      </ul>
    </nav>
    """
  end
end
