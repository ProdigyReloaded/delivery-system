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

defmodule Prodigy.Portal.AdminLive.Portal.Audit do
  @moduledoc """
  `/admin/portal/audit` - read-only browse of `portal_audit_events`.
  Gated on `system.view_audit_log`. Filters on actor email, action,
  target_type/id, and a date range; preloads actor emails in memory
  to keep the query simple.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :system, :view_audit_log}}

  import Ecto.Query

  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.Authz

  @default_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:filters, %{})
     |> assign(:limit, @default_limit)
     |> load_events()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    cleaned = filters |> Enum.reject(fn {_k, v} -> v in [nil, ""] end) |> Map.new()

    {:noreply,
     socket
     |> assign(:filters, cleaned)
     |> load_events()}
  end

  def handle_event("clear_filters", _, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{})
     |> load_events()}
  end

  def handle_event("load_more", _, socket) do
    {:noreply,
     socket
     |> assign(:limit, socket.assigns.limit + @default_limit)
     |> load_events()}
  end

  # --- loading -------------------------------------------------------

  defp load_events(socket) do
    opts = build_opts(socket.assigns.filters, socket.assigns.limit)
    events = Authz.list_audit_events(opts)
    actors = preload_actor_emails(events)

    assign(socket, events: events, actor_emails: actors)
  end

  defp build_opts(filters, limit) do
    base = [limit: limit]

    base
    |> maybe_put(filters, "action", :action, & &1)
    |> maybe_put(filters, "target_type", :target_type, & &1)
    |> maybe_put(filters, "target_id", :target_id, & &1)
    |> maybe_put_actor(filters)
    |> maybe_put_date(filters, "since", :since)
    |> maybe_put_date(filters, "until", :until)
  end

  defp maybe_put(opts, filters, key, opt_key, fun) do
    case Map.fetch(filters, key) do
      {:ok, value} -> Keyword.put(opts, opt_key, fun.(value))
      :error -> opts
    end
  end

  defp maybe_put_actor(opts, filters) do
    case Map.fetch(filters, "actor_email") do
      {:ok, email} when is_binary(email) ->
        case Repo.get_by(User, email: email) do
          nil -> Keyword.put(opts, :actor_id, -1)
          %User{id: id} -> Keyword.put(opts, :actor_id, id)
        end

      _ ->
        opts
    end
  end

  defp maybe_put_date(opts, filters, key, opt_key) do
    case Map.fetch(filters, key) do
      {:ok, value} when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            {:ok, dt} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
            Keyword.put(opts, opt_key, dt)

          _ ->
            opts
        end

      _ ->
        opts
    end
  end

  defp preload_actor_emails(events) do
    actor_ids =
      events
      |> Enum.map(& &1.actor_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case actor_ids do
      [] ->
        %{}

      ids ->
        from(u in User, where: u.id in ^ids, select: {u.id, u.email})
        |> Repo.all()
        |> Map.new()
    end
  end

  # --- rendering -----------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.wrapper
      active={:portal_audit}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Audit Log"
    >
      <p class="text-muted small">
        Append-only record of every grant, revoke, role change, and
        force-logout, newest first. Each row is written inside the same
        transaction as the action it describes, so the log doesn't drift.
      </p>

      <form phx-change="filter" class="mb-3">
        <div class="row g-2">
          <div class="col-md-3">
            <label class="form-label small">Actor email</label>
            <input
              type="text"
              name="filters[actor_email]"
              class="form-control form-control-sm"
              value={Map.get(@filters, "actor_email", "")}
              placeholder="e.g. alice@example.com"
            />
          </div>
          <div class="col-md-2">
            <label class="form-label small">Action</label>
            <input
              type="text"
              name="filters[action]"
              class="form-control form-control-sm"
              value={Map.get(@filters, "action", "")}
              placeholder="e.g. grant.role"
            />
          </div>
          <div class="col-md-2">
            <label class="form-label small">Target type</label>
            <input
              type="text"
              name="filters[target_type]"
              class="form-control form-control-sm"
              value={Map.get(@filters, "target_type", "")}
            />
          </div>
          <div class="col-md-2">
            <label class="form-label small">Target id</label>
            <input
              type="text"
              name="filters[target_id]"
              class="form-control form-control-sm"
              value={Map.get(@filters, "target_id", "")}
            />
          </div>
          <div class="col-md-3">
            <label class="form-label small">Since / Until (UTC date)</label>
            <div class="input-group input-group-sm">
              <input
                type="date"
                name="filters[since]"
                class="form-control"
                value={Map.get(@filters, "since", "")}
              />
              <input
                type="date"
                name="filters[until]"
                class="form-control"
                value={Map.get(@filters, "until", "")}
              />
            </div>
          </div>
        </div>
        <div :if={@filters != %{}} class="mt-2">
          <button
            type="button"
            class="btn btn-sm btn-outline-secondary"
            phx-click="clear_filters"
          >
            Clear filters
          </button>
        </div>
      </form>

      <table class="table table-sm table-hover align-middle">
        <thead>
          <tr>
            <th>When (UTC)</th>
            <th>Actor</th>
            <th>Action</th>
            <th>Target</th>
            <th>Details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events}>
            <td class="text-nowrap small font-monospace">{format_ts(event.inserted_at)}</td>
            <td>{actor_label(event, @actor_emails)}</td>
            <td class="font-monospace small">{event.action}</td>
            <td class="font-monospace small">
              {event.target_type}
              <span :if={event.target_id} class="text-muted">#{event.target_id}</span>
            </td>
            <td class="font-monospace small text-muted">{format_details(event.details)}</td>
          </tr>
          <tr :if={@events == []}>
            <td colspan="5" class="text-center text-muted py-3">No events match.</td>
          </tr>
        </tbody>
      </table>

      <div :if={length(@events) >= @limit} class="mt-2">
        <button class="btn btn-sm btn-outline-secondary" phx-click="load_more">
          Load {@limit + 100}
        </button>
      </div>
    </Layouts.wrapper>
    """
  end

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp actor_label(%{actor_id: nil}, _), do: "system"

  defp actor_label(%{actor_id: id}, emails) do
    case Map.get(emails, id) do
      nil -> "user #{id} (deleted)"
      email -> email
    end
  end

  defp format_details(details) when map_size(details) == 0, do: "-"

  defp format_details(details) do
    details
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(", ")
  end
end
