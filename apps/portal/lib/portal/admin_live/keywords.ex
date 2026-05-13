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

defmodule Prodigy.Portal.AdminLive.Keywords do
  @moduledoc """
  `/admin/service/keywords` - navigation keyword index. Read-only
  table of every keyword indexed, alongside the object it points at,
  plus row actions to detach / add / edit + an "Rebuild index"
  button that regenerates TAODCUSSPGM + TAODCUKJD from the table.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :keywords, :view}}

  import Prodigy.Portal.AdminLive.TableHelpers

  alias Prodigy.Portal.Admin.Keywords, as: Admin
  alias Prodigy.Portal.Admin.Objects
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.Authz


  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Admin.topic())
    end

    {:ok,
     assign(socket,
       keywords: Admin.list(),
       sort_by: :keyword,
       sort_dir: :asc,
       filters: %{},
       visible_count: page_size(),
       page_size: page_size(),
       modal: nil,
       editing: nil,
       form: nil
     )}
  end

  @impl true
  def handle_info(:keywords_deleted, socket),
    do: {:noreply, assign(socket, :keywords, Admin.list())}

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
    {:noreply,
     assign(socket, visible_count: socket.assigns.visible_count + socket.assigns.page_size)}
  end

  def handle_event("delete", %{"keyword" => keyword}, socket) do
    with :ok <- require_scope(socket, :keywords, :manage) do
      do_delete(socket, keyword)
    end
  end

  def handle_event("rebuild_index", _params, socket) do
    with :ok <- require_scope(socket, :keywords, :rebuild_index) do
      do_rebuild(socket)
    end
  end

  def handle_event("open_add", _, socket) do
    with :ok <- require_scope(socket, :keywords, :manage) do
      changeset = keyword_changeset(%{})
      {:noreply, assign(socket, modal: :add, editing: nil, form: to_form(changeset, as: :keyword))}
    end
  end

  def handle_event("open_edit", %{"keyword" => keyword}, socket) do
    with :ok <- require_scope(socket, :keywords, :manage) do
      case Admin.get(keyword) do
        nil ->
          {:noreply, put_flash(socket, :error, "Keyword \"#{keyword}\" is already gone.")}

        row ->
          attrs = %{
            keyword: row.keyword,
            object_name: row.object_name,
            object_sequence: row.object_sequence,
            object_type: row.object_type
          }

          {:noreply,
           assign(socket,
             modal: :edit,
             editing: row,
             form: to_form(keyword_changeset(attrs), as: :keyword)
           )}
      end
    end
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, modal: nil, editing: nil, form: nil)}
  end

  def handle_event("validate_keyword", %{"keyword" => params}, socket) do
    form = to_form(keyword_changeset(params) |> Map.put(:action, :validate), as: :keyword)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save_keyword", %{"keyword" => params}, socket) do
    with :ok <- require_scope(socket, :keywords, :manage) do
      case socket.assigns.modal do
        :add -> do_save_add(socket, params)
        :edit -> do_save_edit(socket, params)
      end
    end
  end

  defp do_delete(socket, keyword) do
    case Admin.delete(keyword) do
      {:ok, _} ->
        # Silent success - the broadcast-driven reload will redraw.
        {:noreply, socket}

      :not_found ->
        {:noreply, put_flash(socket, :error, "Keyword \"#{keyword}\" is already gone.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete keyword: #{inspect(reason)}")}
    end
  end

  defp do_save_add(socket, params) do
    case Admin.create(params) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Keyword added.")
         |> assign(modal: nil, editing: nil, form: nil)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs, as: :keyword, action: :insert))}
    end
  end

  defp do_save_edit(socket, params) do
    old_keyword = socket.assigns.editing.keyword

    case Admin.update(old_keyword, params) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Keyword updated.")
         |> assign(modal: nil, editing: nil, form: nil)}

      :not_found ->
        {:noreply,
         socket
         |> put_flash(:error, "Keyword vanished before save.")
         |> assign(modal: nil, editing: nil, form: nil)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs, as: :keyword, action: :update))}
    end
  end

  defp keyword_changeset(attrs) do
    types = %{
      keyword: :string,
      object_name: :string,
      object_sequence: :integer,
      object_type: :integer
    }

    {%{}, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> Ecto.Changeset.validate_required([:keyword, :object_name, :object_sequence, :object_type])
    |> Ecto.Changeset.validate_length(:keyword, min: 1, max: 13)
  end

  defp do_rebuild(socket) do
    case Admin.rebuild_index() do
      {:ok, result} ->
        {:noreply, put_flash(socket, :info, format_rebuild_result(result))}

      {:error, :no_keywords} ->
        {:noreply,
         put_flash(socket, :error, "Nothing to rebuild - the keyword table is empty.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't rebuild index: #{inspect(reason)}")}
    end
  end

  # "Rebuilt: 1 primary, 3 secondaries - 2 new, 1 bumped, 1 unchanged"
  defp format_rebuild_result(%{counts: counts, total_secondaries: n}) do
    changed = [
      counts.inserted > 0 && "#{counts.inserted} new",
      counts.bumped > 0 && "#{counts.bumped} bumped",
      counts.unchanged > 0 && "#{counts.unchanged} unchanged"
    ]

    breakdown =
      changed
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    "Rebuilt keyword index: 1 primary + #{n} secondaries (#{breakdown})."
  end

  @impl true
  def render(assigns) do
    rows = sorted_rows(assigns.keywords, assigns.filters, assigns.sort_by, assigns.sort_dir)
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
      active={:keywords}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Keywords"
    >
      <div class="mb-2 d-flex justify-content-between align-items-center">
        <span class="text-muted small">{@total} keywords</span>
        <div class="d-flex gap-2">
          <button
            :if={Authz.can?(@current_scope, :keywords, :manage)}
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="open_add"
                      >
            Add keyword...
          </button>
          <button
            :if={Authz.can?(@current_scope, :keywords, :rebuild_index)}
            type="button"
            class="btn btn-sm btn-outline-primary"
            phx-click="rebuild_index"
                        data-confirm="Regenerate the keyword index objects from the current keyword table? This rebuilds TAODCUSSPGM + all TAODCUKJD secondaries."
            title="Regenerate the navigation-index objects from the current keyword table"
          >
            Rebuild index
          </button>
        </div>
      </div>

      <form phx-change="filter" class="mb-0">
        <div class="admin-table-scroll" id="keywords-scroll">
          <table class="table table-sm table-hover align-middle admin-table-sticky">
            <thead>
              <tr>
                <.col_header by={:keyword} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Keyword
                </.col_header>
                <.col_header by={:object_name} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Object
                </.col_header>
                <.col_header by={:object_type} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Type
                </.col_header>
                <.col_header by={:updated_at} sort_by={@sort_by} sort_dir={@sort_dir}>
                  Updated
                </.col_header>
                <th></th>
              </tr>
              <tr>
                <th>
                  <input
                    type="text"
                    class="form-control form-control-sm"
                    name="filters[keyword]"
                    value={Map.get(@filters, "keyword", "")}
                    placeholder="filter"
                  />
                </th>
                <th>
                  <input
                    type="text"
                    class="form-control form-control-sm"
                    name="filters[object_name]"
                    value={Map.get(@filters, "object_name", "")}
                    placeholder="filter"
                  />
                </th>
                <th></th>
                <th></th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @visible_rows}>
                <td><code>{row.keyword}</code></td>
                <td>
                  <code>{row.object_name}</code>
                  <span class="text-muted small font-monospace ms-1">#{row.object_sequence}</span>
                </td>
                <td>{Objects.type_label(row.object_type)}</td>
                <td class="text-muted small">{format_timestamp(row.updated_at)}</td>
                <td class="text-nowrap">
                  <.action_icon_button
                    :if={Authz.can?(@current_scope, :keywords, :manage)}
                    icon={:edit}
                    variant={:primary}
                    spacing="me-2"
                    phx-click="open_edit"
                                        phx-value-keyword={row.keyword}
                    title={"Edit keyword #{row.keyword}"}
                    aria-label={"Edit keyword #{row.keyword}"}
                  />
                  <.action_icon_button
                    :if={Authz.can?(@current_scope, :keywords, :manage)}
                    icon={:delete}
                    variant={:danger}
                    phx-click="delete"
                                        phx-value-keyword={row.keyword}
                    data-confirm={"Remove keyword \"#{row.keyword}\"? The object stays; only the navigation index entry is deleted."}
                    title={"Delete keyword #{row.keyword}"}
                    aria-label={"Delete keyword #{row.keyword}"}
                  />
                </td>
              </tr>
              <tr :if={@visible_rows == []}>
                <td colspan="5" class="text-center text-muted py-3">
                  No keywords match.
                </td>
              </tr>
            </tbody>
          </table>
          <.scroll_sentinel id="keywords-sentinel" done={@all_loaded} />
        </div>
      </form>

      <div :if={not @all_loaded} class="text-muted small mt-1">
        Showing {length(@visible_rows)} of {@total} - scroll to load more
      </div>

      <.modal
        :if={@modal in [:add, :edit]}
        id="keyword-modal"
        show
        title={if @modal == :add, do: "Add keyword", else: "Edit keyword: " <> @editing.keyword}
        on_cancel={JS.push("close_modal")}
      >
        <.form
          for={@form}
          id="keyword-form"
          phx-change="validate_keyword"
          phx-submit="save_keyword"
                  >
          <.input field={@form[:keyword]} type="text" label="Keyword" maxlength="13" />
          <.input field={@form[:object_name]} type="text" label="Object name" placeholder="e.g. PAGE0000   " />
          <div class="row">
            <div class="col-sm-6">
              <.input field={@form[:object_sequence]} type="number" label="Sequence" min="0" />
            </div>
            <div class="col-sm-6">
              <.input field={@form[:object_type]} type="number" label="Type (hex-ish)" />
            </div>
          </div>
          <p class="small text-muted mt-2 mb-0">
            Type codes: 0=Page Format, 4=Page Template, 8=Page Element, 12=Program, 14=Window.
          </p>
        </.form>
        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_modal">
            Cancel
          </button>
          <button type="submit" form="keyword-form" class="btn btn-primary">Save</button>
        </:footer>
      </.modal>
    </Layouts.wrapper>
    """
  end

  # --- row pipeline ---------------------------------------------------

  defp sorted_rows(keywords, filters, sort_by, sort_dir) do
    keywords
    |> filtered_rows(filters)
    |> sort_rows(sort_by, sort_dir)
  end

  defp filtered_rows(keywords, filters) when map_size(filters) == 0, do: keywords

  defp filtered_rows(keywords, filters) do
    Enum.filter(keywords, fn row ->
      Enum.all?(filters, fn {key, value} ->
        haystack = extract_field(row, key) |> to_string() |> String.downcase()
        needle = String.downcase(value)
        String.contains?(haystack, needle)
      end)
    end)
  end

  defp sort_rows(keywords, sort_by, sort_dir) do
    Enum.sort_by(keywords, &Map.get(&1, sort_by), sort_dir)
  end

  defp extract_field(%{keyword: kw}, key) when key in ["keyword", :keyword], do: kw
  defp extract_field(%{object_name: n}, key) when key in ["object_name", :object_name], do: n
  defp extract_field(_, _), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_timestamp(_), do: ""
end
