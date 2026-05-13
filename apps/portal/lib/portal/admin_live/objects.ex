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

defmodule Prodigy.Portal.AdminLive.Objects do
  @moduledoc """
  `/admin/service/objects` - object store browser + upload/delete
  actions. Two tabs:

    * **Database** (default, `:database` live_action) - lists every
      row in the object table with Name / Sequence / Type / Version /
      Size, filterable by name substring + type, sortable on all
      columns.
    * **Deficits** (`/admin/service/objects/deficits`,
      `:deficits` live_action) - roster of objects users requested
      that aren't in the DB, deduped by `(name, sequence, type)`,
      with hit_count and last_seen so the operator can see what
      content is most-missed.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :objects, :view}}

  import Prodigy.Portal.AdminLive.TableHelpers

  alias Prodigy.Portal.Admin.Keywords
  alias Prodigy.Portal.Admin.MissingObjects
  alias Prodigy.Portal.Admin.Objects, as: Admin
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.AdminLive.Objects.UploadModal
  alias Prodigy.Portal.Authz

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Admin.topic())
    end

    {:ok,
     assign(socket,
       objects: Admin.list(),
       sort_by: :name,
       sort_dir: :asc,
       filters: %{},
       selected_types: MapSet.new(Admin.known_types()),
       newest_only: false,
       visible_count: page_size(),
       page_size: page_size(),
       modal: nil,
       # Deficits tab state. Loaded eagerly because the table is
       # bounded by unique missing identities (small in practice);
       # the count drives the tab badge so it shows even before the
       # operator clicks over.
       deficits: MissingObjects.list(),
       deficits_count: MissingObjects.count(),
       deficits_filter: ""
     )}
  end

  # handle_params runs on every live_action transition. The default no-op
  # is enough - @live_action updates automatically - but defining it
  # explicitly keeps `<.link patch={...}>` between Database and Deficits
  # tabs from falling back to a full-page reload.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:objects_upserted, socket),
    do: {:noreply, assign(socket, :objects, Admin.list())}

  def handle_info(:objects_deleted, socket),
    do: {:noreply, assign(socket, :objects, Admin.list())}

  # Messages sent from the upload modal LC.
  def handle_info({:upload_saved, summary}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, summary)
     |> close_modal()}
  end

  def handle_info({:modal_flash, kind, msg}, socket),
    do: {:noreply, put_flash(socket, kind, msg)}

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

  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.get("filters", %{})
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    selected_types =
      params
      |> Map.get("types", %{})
      |> Enum.filter(fn {_k, v} -> v == "true" end)
      |> Enum.map(fn {k, _} -> String.to_integer(k) end)
      |> MapSet.new()

    newest_only = Map.get(params, "newest_only") == "true"

    {:noreply,
     assign(socket,
       filters: filters,
       selected_types: selected_types,
       newest_only: newest_only,
       visible_count: page_size()
     )}
  end

  def handle_event("load_more", _, socket) do
    {:noreply, assign(socket, visible_count: socket.assigns.visible_count + socket.assigns.page_size)}
  end

  def handle_event("delete", params, socket) do
    with :ok <- require_scope(socket, :objects, :delete),
         {:ok, name, sequence, type, version} <- extract_pk(params),
         {:ok, %{keywords_changed?: kw_changed?}} <-
           Admin.delete(name, sequence, type, version) do
      socket = if kw_changed?, do: maybe_rebuild_keyword_index(socket), else: socket
      # Broadcast handles the table refresh; success is silent per the
      # "confirmed action, no success flash" rule.
      {:noreply, socket}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Object already gone.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete: #{inspect(reason)}")}

      :bad_params ->
        {:noreply, put_flash(socket, :error, "Bad delete params.")}
    end
  end

  def handle_event("delete_matching", _, socket) do
    with :ok <- require_scope(socket, :objects, :delete),
         true <-
           filter_narrows?(socket.assigns.filters, socket.assigns.selected_types) do
      rows =
        sorted_rows(
          socket.assigns.objects,
          socket.assigns.filters,
          socket.assigns.selected_types,
          socket.assigns.newest_only,
          :name,
          :asc
        )

      pks = Enum.map(rows, &{&1.name, &1.sequence, &1.type, &1.version})

      case Admin.delete_many(pks) do
        {:ok, %{count: 0}} ->
          {:noreply, put_flash(socket, :info, "No rows matched - nothing deleted.")}

        {:ok, %{count: count, keywords_changed?: kw_changed?}} ->
          socket = if kw_changed?, do: maybe_rebuild_keyword_index(socket), else: socket
          {:noreply, put_flash(socket, :info, "Deleted #{count} object(s).")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Bulk delete failed: #{inspect(reason)}")}
      end
    else
      false ->
        {:noreply, put_flash(socket, :error, "Set a name or type filter first.")}
    end
  end

  def handle_event("open_upload", _, socket) do
    with :ok <- require_scope(socket, :objects, :upload) do
      {:noreply, assign(socket, modal: :upload)}
    end
  end

  def handle_event("close_modal", _, socket), do: {:noreply, close_modal(socket)}

  # --- Deficits tab events --------------------------------------------

  def handle_event("filter_deficits", %{"value" => value}, socket) do
    needle = to_string(value)

    {:noreply,
     socket
     |> assign(:deficits_filter, needle)
     |> assign(:deficits, MissingObjects.list(name_filter: needle))}
  end

  def handle_event(
        "dismiss_deficit",
        %{"name" => name, "sequence" => seq, "type" => type},
        socket
      ) do
    with :ok <- require_scope(socket, :objects, :delete),
         {seq_int, ""} <- Integer.parse(to_string(seq)),
         {type_int, ""} <- Integer.parse(to_string(type)) do
      :ok = MissingObjects.delete(name, seq_int, type_int)

      {:noreply,
       socket
       |> assign(:deficits, MissingObjects.list(name_filter: socket.assigns.deficits_filter))
       |> assign(:deficits_count, MissingObjects.count())
       |> put_flash(:info, "Removed deficit for #{String.trim(name)}.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't dismiss that row.")}
    end
  end

  defp close_modal(socket), do: assign(socket, modal: nil)

  # A "narrowing" filter is one the user has actively set to constrain
  # the listing - either a non-empty name substring or a type filter
  # that excludes at least one known type. Bulk delete is only offered
  # when at least one such filter is in place, so the operator can't
  # nuke the whole table with a stray click.
  defp filter_narrows?(filters, selected_types) do
    name_set? = Map.get(filters, "name", "") |> to_string() |> String.trim() != ""
    types_narrowed? = MapSet.size(selected_types) != length(Admin.known_types())
    name_set? or types_narrowed?
  end

  # Rebuild the keyword index after a delete that changed keywords. The
  # caller threads the socket through so a rebuild failure surfaces as a
  # flash on the list view. An empty keyword table is not an error - it
  # just means the delete emptied the index and there's nothing to emit.
  defp maybe_rebuild_keyword_index(socket) do
    case Keywords.rebuild_index() do
      {:ok, _idx} -> socket
      {:error, :no_keywords} -> socket
      {:error, reason} -> put_flash(socket, :error, "Keyword index rebuild failed: #{inspect(reason)}")
    end
  end


  defp extract_pk(%{"name" => name, "sequence" => seq, "type" => type, "version" => version}) do
    with {s, ""} <- Integer.parse(to_string(seq)),
         {t, ""} <- Integer.parse(to_string(type)),
         {v, ""} <- Integer.parse(to_string(version)) do
      {:ok, name, s, t, v}
    else
      _ -> :bad_params
    end
  end

  defp extract_pk(_), do: :bad_params

  @impl true
  def render(assigns) do
    rows =
      sorted_rows(
        assigns.objects,
        assigns.filters,
        assigns.selected_types,
        assigns.newest_only,
        assigns.sort_by,
        assigns.sort_dir
      )
    total = length(rows)
    visible = Enum.take(rows, assigns.visible_count)
    all_loaded = length(visible) >= total

    filter_narrows? = filter_narrows?(assigns.filters, assigns.selected_types)

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:visible_rows, visible)
      |> assign(:all_loaded, all_loaded)
      |> assign(:filter_narrows?, filter_narrows?)

    ~H"""
    <Layouts.wrapper
      active={:objects}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Objects"
    >
      <ul class="nav nav-tabs mb-3">
        <li class="nav-item">
          <.link
            patch={~p"/admin/service/objects"}
            class={"nav-link #{if @live_action == :database, do: "active"}"}
          >
            Database
          </.link>
        </li>
        <li class="nav-item">
          <.link
            patch={~p"/admin/service/objects/deficits"}
            class={"nav-link #{if @live_action == :deficits, do: "active"}"}
          >
            Deficits
            <span :if={@deficits_count > 0} class="badge text-bg-warning ms-1">{@deficits_count}</span>
          </.link>
        </li>
      </ul>

      <%= if @live_action == :deficits do %>
        {deficits_pane(assigns)}
      <% else %>
      <div class="mb-2 d-flex justify-content-end gap-2">
        <button
          :if={Authz.can?(@current_scope, :objects, :delete)}
          type="button"
          class="btn btn-sm btn-outline-danger"
          phx-click="delete_matching"
         
          disabled={@total == 0 or not @filter_narrows?}
          data-confirm={"Delete #{@total} object(s) matching the current filter? This can't be undone."}
          title={
            if @filter_narrows?,
              do: "Delete every object row matching the current name / type filter.",
              else: "Set a name or type filter first - bulk delete needs a narrowing filter."
          }
        >
          Delete {@total} matching
        </button>
        <button
          :if={Authz.can?(@current_scope, :objects, :upload)}
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="open_upload"
         
        >
          Upload objects...
        </button>
      </div>

      <form phx-change="filter" class="mb-0">
        <div class="mb-2 d-flex flex-wrap gap-3 align-items-center">
          <span class="text-muted small">{@total} objects</span>

          <div class="d-flex gap-2 align-items-center small">
            <span class="text-muted">Types:</span>
            <div :for={t <- Admin.known_types()} class="form-check form-check-inline mb-0">
              <input
                class="form-check-input"
                type="checkbox"
                id={"type-#{t}"}
                name={"types[#{t}]"}
                value="true"
                checked={MapSet.member?(@selected_types, t)}
              />
              <label class="form-check-label" for={"type-#{t}"}>
                {Admin.type_label(t)}
              </label>
            </div>
          </div>

          <div class="form-check form-check-inline mb-0 small">
            <input
              class="form-check-input"
              type="checkbox"
              id="newest-only"
              name="newest_only"
              value="true"
              checked={@newest_only}
            />
            <label
              class="form-check-label"
              for="newest-only"
              title="Show only the highest version of each (name, sequence, type) - hides bump history."
            >
              Newest only
            </label>
          </div>
        </div>

        <div class="admin-table-scroll" id="objects-scroll">
          <table class="table table-sm table-hover align-middle admin-table-sticky">
            <thead>
              <tr>
                <.col_header by={:name} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Name
                </.col_header>
                <.col_header by={:sequence} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Seq
                </.col_header>
                <.col_header by={:type} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Type
                </.col_header>
                <.col_header by={:version} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Ver
                </.col_header>
                <.col_header by={:size} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Size
                </.col_header>
                <.col_header by={:keyword} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Keyword
                </.col_header>
                <th></th>
              </tr>
              <tr>
                <th>
                  <input
                    type="text"
                    class="form-control form-control-sm"
                    name="filters[name]"
                    value={Map.get(@filters, "name", "")}
                    placeholder="filter"
                  />
                </th>
                <th></th>
                <th></th>
                <th></th>
                <th></th>
                <th>
                  <input
                    type="text"
                    class="form-control form-control-sm"
                    name="filters[keyword]"
                    value={Map.get(@filters, "keyword", "")}
                    placeholder="filter"
                  />
                </th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @visible_rows}>
                <td><code>{row.name}</code></td>
                <td><code class="text-muted">{format_hex_byte(row.sequence)}</code></td>
                <td>{Admin.type_label(row.type)}</td>
                <td>{row.version}</td>
                <td class="text-muted small">{format_size(row.size)}</td>
                <td class="font-monospace small">{row.keyword}</td>
                <td class="text-nowrap">
                  <.action_icon_link
                    icon={:download}
                    variant={:primary}
                    spacing="me-2"
                    href={~p"/admin/service/objects/#{row.name}/#{row.sequence}/#{row.type}/#{row.version}/download"}
                    title={"Download #{row.name}"}
                    aria-label={"Download #{row.name}"}
                  />
                  <.action_icon_button
                    :if={Authz.can?(@current_scope, :objects, :delete)}
                    icon={:delete}
                    variant={:danger}
                    phx-click="delete"
                   
                    phx-value-name={row.name}
                    phx-value-sequence={row.sequence}
                    phx-value-type={row.type}
                    phx-value-version={row.version}
                    data-confirm={"Delete #{row.name} v#{row.version}?"}
                    title={"Delete #{row.name}"}
                    aria-label={"Delete #{row.name}"}
                  />
                </td>
              </tr>
              <tr :if={@visible_rows == []}>
                <td colspan="7" class="text-center text-muted py-3">
                  No objects match.
                </td>
              </tr>
            </tbody>
          </table>
          <.scroll_sentinel id="objects-sentinel" done={@all_loaded} />
        </div>
      </form>

      <div :if={not @all_loaded} class="text-muted small mt-1">
        Showing {length(@visible_rows)} of {@total} - scroll to load more
      </div>

      <.live_component :if={@modal == :upload} module={UploadModal} id="upload-objects" />
      <% end %>
    </Layouts.wrapper>
    """
  end

  # --- Deficits tab body ----------------------------------------------

  defp deficits_pane(assigns) do
    ~H"""
    <div class="mb-2 d-flex flex-wrap gap-3 align-items-center">
      <span class="text-muted small">
        {length(@deficits)} of {@deficits_count} deficits
      </span>
      <input
        type="text"
        class="form-control form-control-sm"
        style="max-width: 22rem"
        placeholder="filter by name"
        name="value"
        value={@deficits_filter}
        phx-change="filter_deficits"
        phx-debounce="200"
      />
    </div>

    <div class="admin-table-scroll">
      <table class="table table-sm table-hover align-middle admin-table-sticky">
        <thead>
          <tr>
            <th>Name</th>
            <th class="text-end">Seq</th>
            <th class="text-end">Type</th>
            <th class="text-end">Hits</th>
            <th>First seen</th>
            <th>Last seen</th>
            <th>Last user</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @deficits}>
            <td><code>{row.name}</code></td>
            <td class="text-end font-monospace small">{row.sequence}</td>
            <td class="text-end font-monospace small">{Integer.to_string(row.type, 16)}</td>
            <td class="text-end fw-semibold">{row.hit_count}</td>
            <td class="text-muted small">{Calendar.strftime(row.first_seen, "%Y-%m-%d %H:%M")}</td>
            <td class="text-muted small">{Calendar.strftime(row.last_seen, "%Y-%m-%d %H:%M")}</td>
            <td class="font-monospace small">{row.last_user_id || "-"}</td>
            <td class="text-end">
              <button
                :if={Authz.can?(@current_scope, :objects, :delete)}
                type="button"
                class="btn btn-sm btn-outline-secondary"
                phx-click="dismiss_deficit"
                phx-value-name={row.name}
                phx-value-sequence={row.sequence}
                phx-value-type={row.type}
                title="Forget this deficit (will reappear if requested again)"
              >
                Dismiss
              </button>
            </td>
          </tr>
          <tr :if={@deficits == []}>
            <td colspan="8" class="text-center text-muted py-4">
              No deficits recorded.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # --- row pipeline ---------------------------------------------------

  defp sorted_rows(objects, filters, selected_types, newest_only, sort_by, sort_dir) do
    objects
    |> filtered_rows(filters, selected_types)
    |> maybe_newest_only(newest_only)
    |> sort_rows(sort_by, sort_dir)
  end

  defp filtered_rows(objects, filters, selected_types) do
    objects
    |> Enum.filter(fn row -> MapSet.member?(selected_types, row.type) end)
    |> apply_substring_filter(filters, "name", &(&1.name))
    |> apply_substring_filter(filters, "keyword", &(&1.keyword || ""))
  end

  # `Admin.Objects.list/0` orders by (name asc, sequence asc, type asc,
  # version desc), so within each (name, sequence, type) triple the
  # first encountered row is the newest. `uniq_by` on that triple keeps
  # that first row and drops the rest.
  defp maybe_newest_only(rows, false), do: rows

  defp maybe_newest_only(rows, true) do
    Enum.uniq_by(rows, &{&1.name, &1.sequence, &1.type})
  end

  defp apply_substring_filter(rows, filters, key, extractor) do
    case Map.get(filters, key) do
      nil -> rows
      "" -> rows
      needle ->
        down = String.downcase(needle)
        Enum.filter(rows, &String.contains?(String.downcase(extractor.(&1)), down))
    end
  end

  defp sort_rows(objects, sort_by, sort_dir) do
    # Treat nil keyword values as empty strings so sort is stable when
    # most rows have no keyword.
    Enum.sort_by(objects, fn row -> Map.get(row, sort_by) || "" end, sort_dir)
  end

  # --- formatters -----------------------------------------------------

  defp format_hex_byte(n) when is_integer(n) do
    n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()
  end

  defp format_size(n) when is_integer(n) and n < 1024, do: "#{n} B"
  defp format_size(n) when is_integer(n) and n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_size(n) when is_integer(n), do: "#{Float.round(n / (1024 * 1024), 2)} MB"
  defp format_size(_), do: ""
end
