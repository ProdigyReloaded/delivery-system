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

defmodule Prodigy.Portal.AdminLive.Service.Events do
  @moduledoc """
  `/admin/service/events` - unified chronological feed of per-session
  events (session logon/logoff, CMC errors, future telemetry). Built
  on `Prodigy.Portal.Admin.ServiceEvents` which unions each source
  and normalizes to a common row shape. Each row offers a detail
  button that opens a kind-specific modal body.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :service_users, :view}}

  alias Prodigy.Portal.Admin.ServiceEvents
  alias Prodigy.Portal.AdminLive.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:filters, %{})
     |> assign(:limit, 200)
     |> assign(:detail, nil)
     |> assign(:detail_tab, :fields)
     |> assign(:subscribed?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Initial filter state can come from URL params - used by the
    # Online tab's "jump to events for this session" link. Any of
    # user_id / session_id / kind / since / until picked up here.
    filters =
      ~w(user_id session_id kind since until)
      |> Enum.flat_map(fn key ->
        case Map.get(params, key) do
          v when is_binary(v) and v != "" -> [{key, v}]
          _ -> []
        end
      end)
      |> Map.new()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> sync_subscription()
     |> load_events()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    cleaned = filters |> Enum.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new()

    {:noreply,
     socket
     |> assign(:filters, cleaned)
     |> assign(:detail, nil)
     |> sync_subscription()
     |> load_events()}
  end

  def handle_event("clear_filters", _, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{})
     |> assign(:detail, nil)
     |> sync_subscription()
     |> load_events()}
  end

  def handle_event("load_more", _, socket) do
    {:noreply,
     socket
     |> assign(:limit, socket.assigns.limit + 200)
     |> load_events()}
  end

  def handle_event("show_detail", %{"index" => idx}, socket) do
    case Integer.parse(idx) do
      {n, ""} ->
        {:noreply,
         socket
         |> assign(:detail, Enum.at(socket.assigns.events, n))
         |> assign(:detail_tab, :fields)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, :detail, nil)}
  end

  def handle_event("switch_detail_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :detail_tab, String.to_existing_atom(tab))}
  end

  # Live-event stream - we subscribe only when at least one filter is
  # set so idle admins don't get bombarded with every logon/data-
  # collection record across the server. When subscribed, each
  # incoming broadcast is filtered locally against the current
  # filters and either prepended to the list or ignored.
  @impl true
  def handle_info({:service_event, payload}, socket) do
    case ServiceEvents.from_broadcast(payload) do
      nil ->
        {:noreply, socket}

      event ->
        if connected?(socket) and ServiceEvents.matches_filter?(event, socket.assigns.filters) do
          {:noreply, assign(socket, :events, [event | socket.assigns.events])}
        else
          {:noreply, socket}
        end
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp sync_subscription(socket) do
    wants? = socket.assigns.filters != %{} and connected?(socket)

    case {wants?, socket.assigns.subscribed?} do
      {true, false} ->
        ServiceEvents.subscribe()
        assign(socket, :subscribed?, true)

      {false, true} ->
        ServiceEvents.unsubscribe()
        assign(socket, :subscribed?, false)

      _ ->
        socket
    end
  end

  defp load_events(socket) do
    # The form posts string keys ("user_id", "kind", ...); ServiceEvents.list
    # expects an atom-keyed keyword list. Whitelist the translation so a
    # crafted form field can't reach String.to_existing_atom at random.
    filters_kw =
      socket.assigns.filters
      |> Enum.flat_map(fn {k, v} ->
        case filter_key_to_atom(k) do
          nil -> []
          a -> [{a, v}]
        end
      end)

    opts = [{:limit, socket.assigns.limit} | filters_kw]
    events = ServiceEvents.list(opts)
    assign(socket, :events, events)
  end

  defp filter_key_to_atom("user_id"), do: :user_id
  defp filter_key_to_atom("session_id"), do: :session_id
  defp filter_key_to_atom("kind"), do: :kind
  defp filter_key_to_atom("since"), do: :since
  defp filter_key_to_atom("until"), do: :until
  defp filter_key_to_atom(_), do: nil

  # --- rendering -----------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.wrapper
      active={:events}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Service Events"
    >
      <p class="text-muted small">
        Chronological feed of per-session events. Filter by service-user
        id or session to investigate a report; click the detail icon on
        a row for the full payload. <strong>Live updates</strong> kick
        in only when a filter is applied.
      </p>
      <div class="mb-2 small">
        <span :if={@subscribed?} class="badge text-bg-success">● live</span>
        <span :if={not @subscribed?} class="badge text-bg-light border">snapshot</span>
      </div>

      <form phx-change="filter" class="mb-3">
        <div class="row g-2 align-items-end">
          <div class="col-md-3">
            <label class="form-label small">Service user id</label>
            <input
              type="text"
              name="filters[user_id]"
              class="form-control form-control-sm"
              value={Map.get(@filters, "user_id", "")}
              placeholder="e.g. AAAA11A"
            />
          </div>
          <div class="col-md-2">
            <label class="form-label small">Session id</label>
            <input
              type="text"
              name="filters[session_id]"
              class="form-control form-control-sm"
              value={Map.get(@filters, "session_id", "")}
            />
          </div>
          <div class="col-md-2">
            <label class="form-label small">Kind</label>
            <select name="filters[kind]" class="form-select form-select-sm">
              <option value="">all</option>
              <option :for={k <- ServiceEvents.kinds()} selected={Map.get(@filters, "kind") == Atom.to_string(k)} value={Atom.to_string(k)}>
                {Atom.to_string(k)}
              </option>
            </select>
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
          <div class="col-md-auto">
            <button
              :if={@filters != %{}}
              type="button"
              class="btn btn-sm btn-outline-secondary"
              phx-click="clear_filters"
            >
              Clear
            </button>
          </div>
        </div>
      </form>

      <table class="table table-sm table-hover align-middle">
        <thead>
          <tr>
            <th>When (UTC)</th>
            <th>User</th>
            <th>Session</th>
            <th>Kind</th>
            <th>Summary</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{event, idx} <- Enum.with_index(@events)}>
            <td class="text-nowrap small font-monospace">{format_ts(event.at)}</td>
            <td class="font-monospace small">{event.user_id || "-"}</td>
            <td class="font-monospace small">{event.session_id || "-"}</td>
            <td><span class={"badge " <> kind_badge_class(event.kind)}>{event.kind}</span></td>
            <td class="small">{event.summary}</td>
            <td class="text-end">
              <.action_icon_button
                icon={:detail}
                variant={:secondary}
                phx-click="show_detail"
                phx-value-index={idx}
                title="Show full detail"
                aria-label="Show full detail"
              />
            </td>
          </tr>
          <tr :if={@events == []}>
            <td colspan="6" class="text-center text-muted py-3">No events match.</td>
          </tr>
        </tbody>
      </table>

      <div :if={length(@events) >= @limit} class="mt-2">
        <button class="btn btn-sm btn-outline-secondary" phx-click="load_more">
          Load {@limit + 200}
        </button>
      </div>

      <.modal
        :if={@detail}
        id="event-detail-modal"
        show
        title={modal_title(@detail)}
        on_cancel={JS.push("close_detail")}
      >
        <.event_detail event={@detail} tab={@detail_tab} />
        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_detail">
            Close
          </button>
        </:footer>
      </.modal>
    </Layouts.wrapper>
    """
  end

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_ts(_), do: "-"

  defp kind_badge_class(:session_logon), do: "text-bg-success"
  defp kind_badge_class(:session_logoff), do: "text-bg-secondary"
  defp kind_badge_class(:cmc_error), do: "text-bg-danger"
  defp kind_badge_class(:data_collection_object), do: "text-bg-info"
  defp kind_badge_class(:data_collection_function), do: "text-bg-primary"
  defp kind_badge_class(_), do: "text-bg-light"

  defp modal_title(%{kind: :session_logon, user_id: uid}), do: "Session logon - #{uid}"
  defp modal_title(%{kind: :session_logoff, user_id: uid}), do: "Session logoff - #{uid}"
  defp modal_title(%{kind: :cmc_error, user_id: uid}), do: "CMC error - #{uid}"
  defp modal_title(%{kind: :data_collection_object, user_id: uid}), do: "Data collection (object) - #{uid}"

  defp modal_title(%{kind: :data_collection_function, user_id: uid}),
    do: "Data collection (function) - #{uid}"

  defp modal_title(_), do: "Event detail"

  # --- per-kind detail bodies ----------------------------------------

  attr :event, :map, required: true
  attr :tab, :atom, default: :fields

  defp event_detail(%{event: %{kind: :session_logon, source: s}} = assigns) do
    assigns = assign(assigns, :s, s)

    ~H"""
    <.kv_row label="User id" value={@s.user_id} mono />
    <.kv_row label="Session id" value={@s.id} mono />
    <.kv_row label="Logon timestamp" value={format_ts(@s.logon_timestamp)} mono />
    <.kv_row label="Logon status" value={@s.logon_status} mono />
    <.kv_row label="Transport" value={@s.transport} />
    <.kv_row label="Source" value={"#{@s.source_address}:#{@s.source_port}"} mono />
    <.kv_row label="RS version" value={@s.rs_version} mono />
    <.kv_row label="Node" value={@s.node} mono />
    <.kv_row label="PID" value={@s.pid} mono />
    """
  end

  defp event_detail(%{event: %{kind: :session_logoff, source: s}} = assigns) do
    assigns = assign(assigns, :s, s)

    ~H"""
    <.kv_row label="User id" value={@s.user_id} mono />
    <.kv_row label="Session id" value={@s.id} mono />
    <.kv_row label="Logon timestamp" value={format_ts(@s.logon_timestamp)} mono />
    <.kv_row label="Logoff timestamp" value={format_ts(@s.logoff_timestamp)} mono />
    <.kv_row label="Logoff status" value={ServiceEvents.logoff_status_label(@s.logoff_status)} />
    <.kv_row label="RS version" value={@s.rs_version} mono />
    <.kv_row label="Transport" value={@s.transport} />
    <.kv_row label="Source" value={"#{@s.source_address}:#{@s.source_port}"} mono />
    """
  end

  defp event_detail(%{event: %{kind: :cmc_error, source: c}} = assigns) do
    assigns = assign(assigns, :c, c)

    ~H"""
    <ul class="nav nav-tabs mb-2">
      <li class="nav-item">
        <a
          href="#"
          class={"nav-link py-1 px-2 small #{if @tab == :fields, do: "active"}"}
          phx-click="switch_detail_tab"
          phx-value-tab="fields"
        >
          Fields
        </a>
      </li>
      <li class="nav-item">
        <a
          href="#"
          class={"nav-link py-1 px-2 small #{if @tab == :raw, do: "active"}"}
          phx-click="switch_detail_tab"
          phx-value-tab="raw"
        >
          Raw
        </a>
      </li>
    </ul>

    <div :if={@tab == :fields}>
      <.kv_row label="When" value={format_ts(@c.inserted_at)} mono />
      <.kv_row label="Session id" value={@c.session_id} mono />
      <.kv_row label="User id (raw)" value={@c.user_id} mono />
      <.kv_row label="Error code" value={String.trim(@c.error_code || "")} mono />
      <.kv_row label="Severity" value={String.trim(@c.severity_level || "")} mono />
      <.kv_row label="Threshold" value={@c.error_threshold} mono />
      <.kv_row label="System origin" value={@c.system_origin} mono />
      <.kv_row label="Message origin" value={@c.msg_origin} mono />
      <.kv_row label="Unit id" value={@c.unit_id} mono />
      <.kv_row label="Error date / time" value={"#{@c.error_date} #{@c.error_time}"} mono />
      <.kv_row label="API event" value={@c.api_event} mono />
      <.kv_row label="Memory at start" value={@c.mem_to_start} mono />
      <.kv_row label="DOS version" value={@c.dos_version} mono />
      <.kv_row label="RS version" value={@c.rs_version} mono />
      <.kv_row label="Window" value={"#{@c.window_id}  last #{@c.window_last}"} mono />
      <.kv_row label="Selected" value={"#{@c.selected_id}  last #{@c.selected_last}"} mono />
      <.kv_row label="Base" value={"#{@c.base_id}  last #{@c.base_last}"} mono />
      <.kv_row label="Keyword" value={@c.keyword} mono />
    </div>

    <div :if={@tab == :raw}>
      <pre class="small font-monospace bg-body-tertiary border rounded p-2 mb-0" style="white-space: pre; overflow-x: auto;">{hex_dump(@c.raw_payload)}</pre>
    </div>
    """
  end

  defp event_detail(%{event: %{kind: :data_collection_object, source: d}} = assigns) do
    assigns = assign(assigns, :d, d)

    ~H"""
    <.kv_row label="When" value={format_ts(@d.inserted_at)} mono />
    <.kv_row label="Session id" value={@d.session_id} mono />
    <.kv_row label="User id" value={@d.user_id} mono />
    <.kv_row label="Object name" value={String.trim(@d.object_name || "")} mono />
    <.kv_row label="Sequence" value={@d.object_sequence} mono />
    <.kv_row label="Type" value={@d.object_type} mono />
    <.kv_row label="Record type" value={@d.record_type} mono />
    <.kv_row label="Duration" value={ServiceEvents.format_duration(@d.duration_seconds)} mono />
    """
  end

  defp event_detail(%{event: %{kind: :data_collection_function, source: d}} = assigns) do
    assigns = assign(assigns, :d, d)

    ~H"""
    <.kv_row label="When" value={format_ts(@d.inserted_at)} mono />
    <.kv_row label="Session id" value={@d.session_id} mono />
    <.kv_row label="User id" value={@d.user_id} mono />
    <.kv_row label="Function class" value={@d.function_class} mono />
    <.kv_row label="Duration" value={ServiceEvents.format_duration(@d.duration_seconds)} mono />
    """
  end

  defp event_detail(assigns) do
    ~H"""
    <p class="text-muted">No detail renderer for this event kind.</p>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :mono, :boolean, default: false

  # Compact horizontal row: fixed-width label on the left, value next
  # to it, no extra form-control padding. Keeps the modal short even
  # for the CMC payload's 18 fields.
  defp kv_row(assigns) do
    ~H"""
    <div class="d-flex small mb-0 py-0">
      <div class="text-muted text-end pe-2" style="min-width: 9.5rem; flex-shrink: 0;">
        {@label}
      </div>
      <div class={if @mono, do: "font-monospace", else: ""}>
        {to_string(@value || "-")}
      </div>
    </div>
    """
  end

  defp hex_dump(nil), do: "-"

  defp hex_dump(bin) when is_binary(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_every(16)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {chunk, i} ->
      offset = i * 16

      hex =
        chunk
        |> Enum.map(&Integer.to_string(&1, 16))
        |> Enum.map(&String.pad_leading(&1, 2, "0"))
        |> Enum.chunk_every(8)
        |> Enum.map_join("  ", &Enum.join(&1, " "))

      ascii =
        chunk
        |> Enum.map(fn b -> if b in 0x20..0x7E, do: <<b>>, else: "." end)
        |> Enum.join("")

      [
        String.pad_leading(Integer.to_string(offset, 16), 4, "0"),
        "  ",
        String.pad_trailing(hex, 49),
        "  ",
        ascii
      ]
      |> IO.iodata_to_binary()
    end)
  end
end
