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

defmodule Prodigy.Portal.AdminLive.Online do
  @moduledoc """
  `/admin/service/online` - live view of active service-user sessions
  with sort/filter and a force-disconnect row action. Subscribes to
  SessionManager broadcasts so connects/disconnects redraw the table
  immediately.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :service_users, :view}}

  import Prodigy.Portal.AdminLive.TableHelpers

  alias Prodigy.Portal.Admin.Sessions
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.Authz
  alias Prodigy.Server.SessionManager


  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, SessionManager.topic())
    end

    {:ok,
     assign(socket,
       sessions: Sessions.list_online(),
       sort_by: :logon_timestamp,
       sort_dir: :desc,
       filters: %{},
       visible_count: page_size(),
       page_size: page_size()
     )}
  end

  @impl true
  def handle_info({:session_opened, _}, socket),
    do: {:noreply, assign(socket, :sessions, Sessions.list_online())}

  def handle_info({:session_closed, _}, socket),
    do: {:noreply, assign(socket, :sessions, Sessions.list_online())}

  def handle_info({:profile_updated, _}, socket),
    do: {:noreply, assign(socket, :sessions, Sessions.list_online())}

  def handle_info({:service_user_authenticated, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("sort", %{"by" => field_str}, socket) do
    field = String.to_existing_atom(field_str)

    {new_by, new_dir} =
      if socket.assigns.sort_by == field do
        {field, toggle_dir(socket.assigns.sort_dir)}
      else
        {field, :asc}
      end

    {:noreply, assign(socket, sort_by: new_by, sort_dir: new_dir, visible_count: page_size())}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    cleaned =
      filters
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    {:noreply, assign(socket, filters: cleaned, visible_count: page_size())}
  end

  def handle_event("load_more", _, socket) do
    {:noreply, assign(socket, visible_count: socket.assigns.visible_count + socket.assigns.page_size)}
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    if Authz.can?(socket.assigns[:current_scope], :service_users, :disconnect) do
      do_disconnect(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Not authorized.")}
    end
  end

  defp do_disconnect(socket, id) do
    id_int = String.to_integer(id)

    case Enum.find(socket.assigns.sessions, &(&1.id == id_int)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Session not found.")}

      session ->
        case Sessions.disconnect(session) do
          :ok ->
            # No flash on success - the row disappears when
            # SessionManager.close_session broadcasts :session_closed.
            {:noreply, socket}

          {:error, :stale} ->
            {:noreply, socket}

          {:error, {:remote_node, n}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Session lives on node #{n} (not this one). Multi-node disconnect is not wired yet."
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't disconnect: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    rows = sorted_rows(assigns.sessions, assigns.filters, assigns.sort_by, assigns.sort_dir)
    total = length(rows)
    visible = Enum.take(rows, assigns.visible_count)
    all_loaded = length(visible) >= total

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:visible_rows, visible)
      |> assign(:all_loaded, all_loaded)

    ~H"""
    <Layouts.wrapper
      active={:online}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Who's online"
    >
      <div class="mb-2">
        <span class="text-muted small">{@total} online</span>
      </div>

      <form phx-change="filter" class="mb-0">
        <div class="admin-table-scroll" id="online-scroll">
        <table class="table table-sm table-hover align-middle admin-table-sticky">
          <thead>
            <tr>
              <.col_header by={:user_id} sort_by={@sort_by} sort_dir={@sort_dir}>
                User
              </.col_header>
              <.col_header by={:name} sort_by={@sort_by} sort_dir={@sort_dir}>
                Name
              </.col_header>
              <.col_header by={:email} sort_by={@sort_by} sort_dir={@sort_dir}>
                Portal email
              </.col_header>
              <.col_header by={:source_address} sort_by={@sort_by} sort_dir={@sort_dir}>
                Source
              </.col_header>
              <.col_header by={:duration} sort_by={@sort_by} sort_dir={@sort_dir}>
                Duration
              </.col_header>
              <th></th>
            </tr>
            <tr>
              <th>
                <input
                  type="text"
                  class="form-control form-control-sm"
                  name="filters[user_id]"
                  value={Map.get(@filters, "user_id", "")}
                  placeholder="filter"
                />
              </th>
              <th>
                <input
                  type="text"
                  class="form-control form-control-sm"
                  name="filters[name]"
                  value={Map.get(@filters, "name", "")}
                  placeholder="filter"
                />
              </th>
              <th>
                <input
                  type="text"
                  class="form-control form-control-sm"
                  name="filters[email]"
                  value={Map.get(@filters, "email", "")}
                  placeholder="filter"
                />
              </th>
              <th>
                <input
                  type="text"
                  class="form-control form-control-sm"
                  name="filters[source_address]"
                  value={Map.get(@filters, "source_address", "")}
                  placeholder="filter"
                />
              </th>
              <th></th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @visible_rows}>
              <td><code>{row.user.id}</code></td>
              <td>{full_name(row.user)}</td>
              <td>{portal_email(row.user)}</td>
              <td>
                <span class={"badge me-2 #{transport_badge_class(row.transport)}"}>
                  {transport_label(row.transport)}
                </span>
                <span class="text-muted small font-monospace">
                  {source_endpoint(row)}
                </span>
              </td>
              <td>
                <span
                  id={"duration-#{row.id}"}
                  phx-hook="Duration"
                  data-logon-at={format_time(row.logon_timestamp)}
                >
                  {format_duration(row.logon_timestamp)}
                </span>
              </td>
              <td class="text-nowrap">
                <.action_icon_link
                  icon={:events}
                  variant={:primary}
                  spacing="me-2"
                  href={"/admin/service/events?session_id=" <> Integer.to_string(row.id)}
                  title={"Jump to events for session #{row.id} (live)"}
                  aria-label={"Events for session #{row.id}"}
                />
                <.action_icon_button
                  :if={Authz.can?(@current_scope, :service_users, :disconnect)}
                  icon={:disconnect}
                  variant={:danger}
                  phx-click="disconnect"
                 
                  phx-value-id={row.id}
                  data-confirm={"Force-disconnect #{row.user.id}?"}
                  title="Force disconnect"
                  aria-label={"Force-disconnect #{row.user.id}"}
                />
              </td>
            </tr>
            <tr :if={@visible_rows == []}>
              <td colspan="6" class="text-center text-muted py-3">
                No sessions match.
              </td>
            </tr>
          </tbody>
        </table>
        <.scroll_sentinel id="online-sentinel" done={@all_loaded} />
        </div>
      </form>

      <div :if={not @all_loaded} class="text-muted small mt-1">
        Showing {length(@visible_rows)} of {@total} - scroll to load more
      </div>
    </Layouts.wrapper>
    """
  end

  # --- row pipeline ---------------------------------------------------

  defp sorted_rows(sessions, filters, sort_by, sort_dir) do
    sessions
    |> filtered_rows(filters)
    |> sort_rows(sort_by, sort_dir)
  end

  defp filtered_rows(sessions, filters) when map_size(filters) == 0, do: sessions

  defp filtered_rows(sessions, filters) do
    Enum.filter(sessions, fn s ->
      Enum.all?(filters, fn {key, value} ->
        haystack = extract_field(s, key) |> to_string() |> String.downcase()
        needle = String.downcase(value)
        String.contains?(haystack, needle)
      end)
    end)
  end

  defp sort_rows(sessions, sort_by, sort_dir) do
    sorter =
      case sort_by do
        :duration -> &extract_field(&1, :logon_timestamp)
        other -> &extract_field(&1, other)
      end

    Enum.sort_by(sessions, sorter, sorter_order(sort_dir, sort_by))
  end

  # DateTime fields need DateTime.compare/2 as the ordering module.
  defp sorter_order(:asc, field) when field in [:logon_timestamp, :last_activity_at, :duration],
    do: {:asc, DateTime}

  defp sorter_order(:desc, field) when field in [:logon_timestamp, :last_activity_at, :duration],
    do: {:desc, DateTime}

  defp sorter_order(:asc, _), do: :asc
  defp sorter_order(:desc, _), do: :desc

  # --- field extraction (shared by filter + sort) ---------------------

  defp extract_field(%{user: %{id: id}}, "user_id"), do: to_string(id)
  defp extract_field(%{user: %{id: id}}, :user_id), do: to_string(id)

  defp extract_field(%{user: user}, "name"), do: full_name(user)
  defp extract_field(%{user: user}, :name), do: full_name(user)

  defp extract_field(%{user: user}, "email"), do: portal_email(user)
  defp extract_field(%{user: user}, :email), do: portal_email(user)

  defp extract_field(%{source_address: s, transport: t, source_port: p}, key)
       when key in ["source_address", :source_address] do
    [transport_label(t), to_string(s), to_string(p)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp extract_field(%{logon_timestamp: t}, :logon_timestamp), do: t
  defp extract_field(%{last_activity_at: t}, :last_activity_at), do: t
  defp extract_field(_, _), do: ""

  # --- formatters -----------------------------------------------------

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_duration(nil), do: ""

  defp format_duration(%DateTime{} = logon_at) do
    seconds = DateTime.diff(DateTime.utc_now(), logon_at)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  defp transport_label("tcp"), do: "TCP"
  defp transport_label("websocket"), do: "WebSocket"
  defp transport_label(nil), do: "-"
  defp transport_label(other), do: to_string(other)

  defp transport_badge_class("tcp"), do: "text-bg-primary"
  defp transport_badge_class("websocket"), do: "text-bg-success"
  defp transport_badge_class(_), do: "text-bg-secondary"

  defp source_endpoint(%{source_address: addr, source_port: port})
       when is_binary(addr) and is_integer(port),
       do: "#{addr}:#{port}"

  defp source_endpoint(%{source_address: addr}) when is_binary(addr), do: addr
  defp source_endpoint(_), do: ""
end
