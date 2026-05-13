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

defmodule Prodigy.Portal.AdminLive.Users do
  @moduledoc """
  `/admin/service/users` - service-user list with edit, reset-password,
  delete, undelete, and force-disconnect row actions. Subscribes to
  SessionManager broadcasts so online-status columns update live.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :service_users, :view}}

  import Prodigy.Portal.AdminLive.TableHelpers

  alias Prodigy.Portal.Admin.Users, as: Admin
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.AdminLive.Users.EditModal
  alias Prodigy.Portal.AdminLive.Users.ResetPasswordModal
  alias Prodigy.Portal.Authz
  alias Prodigy.Server.SessionManager


  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, SessionManager.topic())
    end

    {:ok,
     assign(socket,
       users: Admin.list(),
       sort_by: :user_id,
       sort_dir: :asc,
       filters: %{},
       modal: nil,
       editing_user: nil,
       reset_user: nil,
       visible_count: page_size(),
       page_size: page_size()
     )}
  end

  @impl true
  def handle_info({:session_opened, _}, socket),
    do: {:noreply, assign(socket, :users, Admin.list())}

  def handle_info({:session_closed, _}, socket),
    do: {:noreply, assign(socket, :users, Admin.list())}

  def handle_info({:profile_updated, _}, socket),
    do: {:noreply, assign(socket, :users, Admin.list())}

  def handle_info({:service_user_authenticated, _}, socket), do: {:noreply, socket}

  # Messages sent from child modal LiveComponents.
  def handle_info({:edit_saved, _user}, socket),
    do: {:noreply, socket |> put_flash(:info, "User updated.") |> close_modal()}

  def handle_info({:reset_password_saved, user, pw}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "Password reset for #{user.id}. New password: #{String.upcase(pw)}"
     )
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

  def handle_event("edit", %{"id" => id}, socket) do
    with :ok <- require_scope(socket, :service_users, :edit_profile) do
      open_edit_modal(socket, id)
    end
  end

  def handle_event("reset_password", %{"id" => id}, socket) do
    with :ok <- require_scope(socket, :service_users, :edit_profile) do
      open_reset_modal(socket, id)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with :ok <- require_scope(socket, :service_users, :delete) do
      do_delete(socket, id)
    end
  end

  def handle_event("undelete", %{"id" => id}, socket) do
    with :ok <- require_scope(socket, :service_users, :delete) do
      do_undelete(socket, id)
    end
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    with :ok <- require_scope(socket, :service_users, :disconnect) do
      do_disconnect(socket, id)
    end
  end

  def handle_event("close_modal", _, socket), do: {:noreply, close_modal(socket)}

  defp open_edit_modal(socket, id) do
    case Admin.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User #{id} not found.")}

      user ->
        {:noreply, assign(socket, modal: :edit, editing_user: user)}
    end
  end

  defp open_reset_modal(socket, id) do
    case Admin.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User #{id} not found.")}

      user ->
        {:noreply, assign(socket, modal: :reset, reset_user: user)}
    end
  end

  defp do_delete(socket, id) do
    case Admin.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User #{id} not found.")}

      user ->
        case Admin.soft_delete(user) do
          # Success is silent - the row's icon swap is the signal, and the
          # admin already confirmed via the data-confirm dialog.
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't delete #{user.id}: #{inspect(reason)}")}
        end
    end
  end

  defp do_undelete(socket, id) do
    case Admin.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User #{id} not found.")}

      user ->
        case Admin.undelete(user) do
          {:ok, _} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't undelete #{user.id}: #{inspect(reason)}")}
        end
    end
  end

  defp do_disconnect(socket, id) do
    case Admin.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User #{id} not found.")}

      user ->
        case Admin.force_disconnect(user) do
          :ok ->
            # Row refresh happens via the :session_closed broadcast from
            # SessionManager, so no flash on success.
            {:noreply, socket}

          {:error, {:remote_node, n}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Session for #{user.id} is on node #{n}; multi-node disconnect is not wired."
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Couldn't disconnect #{user.id}: #{inspect(reason)}"
             )}
        end
    end
  end

  defp close_modal(socket),
    do: assign(socket, modal: nil, editing_user: nil, reset_user: nil)

  @impl true
  def render(assigns) do
    rows = sorted_rows(assigns.users, assigns.filters, assigns.sort_by, assigns.sort_dir)
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
      active={:users}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Service Users"
    >
      <div class="mb-2">
        <span class="text-muted small">{@total} users</span>
      </div>

      <form phx-change="filter" class="mb-0">
        <div class="admin-table-scroll" id="users-scroll">
        <table class="table table-sm table-hover align-middle admin-table-sticky">
          <thead>
            <tr>
              <.col_header by={:user_id} sort_by={@sort_by} sort_dir={@sort_dir}>
                ID
              </.col_header>
              <.col_header by={:name} sort_by={@sort_by} sort_dir={@sort_dir}>
                Name
              </.col_header>
              <.col_header by={:household} sort_by={@sort_by} sort_dir={@sort_dir}>
                Household
              </.col_header>
              <.col_header by={:email} sort_by={@sort_by} sort_dir={@sort_dir}>
                Portal email
              </.col_header>
              <.col_header by={:status} sort_by={@sort_by} sort_dir={@sort_dir}>
                Status
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
                  name="filters[household]"
                  value={Map.get(@filters, "household", "")}
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
                  name="filters[status]"
                  value={Map.get(@filters, "status", "")}
                  placeholder="filter"
                />
              </th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @visible_rows}>
              <td><code>{row.user.id}</code></td>
              <td>{full_name(row.user)}</td>
              <td><code class="text-muted">{row.user.household_id}</code></td>
              <td>{portal_email(row.user)}</td>
              <td>{status_badge(row)}</td>
              <td class="text-nowrap">
                <.action_icon_button
                  :if={Authz.can?(@current_scope, :service_users, :edit_profile)}
                  icon={:edit}
                  variant={:primary}
                  spacing="me-2"
                  phx-click="edit"
                 
                  phx-value-id={row.user.id}
                  title={"Edit #{row.user.id}"}
                  aria-label={"Edit #{row.user.id}"}
                />
                <.action_icon_button
                  :if={Authz.can?(@current_scope, :service_users, :edit_profile)}
                  icon={:reset_password}
                  variant={:secondary}
                  phx-click="reset_password"
                 
                  phx-value-id={row.user.id}
                  title={"Reset password for #{row.user.id}"}
                  aria-label={"Reset password for #{row.user.id}"}
                />
                <.action_icon_button
                  :if={row.user.date_deleted == nil and Authz.can?(@current_scope, :service_users, :delete)}
                  icon={:delete}
                  variant={:warning}
                  spacing="ms-2"
                  phx-click="delete"
                 
                  phx-value-id={row.user.id}
                  data-confirm={"Delete #{row.user.id}? They won't be able to log on, and any active session is disconnected."}
                  title={"Delete #{row.user.id}"}
                  aria-label={"Delete #{row.user.id}"}
                />
                <.action_icon_button
                  :if={row.user.date_deleted != nil and Authz.can?(@current_scope, :service_users, :delete)}
                  icon={:restore}
                  variant={:success}
                  spacing="ms-2"
                  phx-click="undelete"
                 
                  phx-value-id={row.user.id}
                  data-confirm={"Restore #{row.user.id}?"}
                  title={"Restore #{row.user.id}"}
                  aria-label={"Restore #{row.user.id}"}
                />
                <.action_icon_button
                  :if={row.online? and Authz.can?(@current_scope, :service_users, :disconnect)}
                  icon={:disconnect}
                  variant={:danger}
                  spacing="ms-2"
                  phx-click="disconnect"
                 
                  phx-value-id={row.user.id}
                  data-confirm={"Force-disconnect #{row.user.id}?"}
                  title={"Force-disconnect #{row.user.id}"}
                  aria-label={"Force-disconnect #{row.user.id}"}
                />
              </td>
            </tr>
            <tr :if={@visible_rows == []}>
              <td colspan="6" class="text-center text-muted py-3">
                No users match.
              </td>
            </tr>
          </tbody>
        </table>
        <.scroll_sentinel id="users-sentinel" done={@all_loaded} />
        </div>
      </form>

      <div :if={not @all_loaded} class="text-muted small mt-1">
        Showing {length(@visible_rows)} of {@total} - scroll to load more
      </div>

      <.live_component
        :if={@modal == :edit and @editing_user != nil}
        module={EditModal}
        id="edit-user"
        user={@editing_user}
        current_scope={@current_scope}
      />

      <.live_component
        :if={@modal == :reset and @reset_user != nil}
        module={ResetPasswordModal}
        id="reset-password"
        user={@reset_user}
        current_scope={@current_scope}
      />
    </Layouts.wrapper>
    """
  end

  # --- row pipeline ---------------------------------------------------

  defp sorted_rows(users, filters, sort_by, sort_dir) do
    users
    |> filtered_rows(filters)
    |> sort_rows(sort_by, sort_dir)
  end

  defp filtered_rows(users, filters) when map_size(filters) == 0, do: users

  defp filtered_rows(users, filters) do
    Enum.filter(users, fn row ->
      Enum.all?(filters, fn {key, value} ->
        haystack = extract_field(row, key) |> to_string() |> String.downcase()
        needle = String.downcase(value)
        String.contains?(haystack, needle)
      end)
    end)
  end

  defp sort_rows(users, sort_by, sort_dir) do
    Enum.sort_by(users, &extract_field(&1, sort_by), sort_dir)
  end

  # --- field extraction (shared by filter + sort) ---------------------

  defp extract_field(%{user: %{id: id}}, key) when key in ["user_id", :user_id],
    do: to_string(id)

  defp extract_field(%{user: %{household_id: h}}, key) when key in ["household", :household],
    do: to_string(h)

  defp extract_field(%{user: user}, key) when key in ["name", :name], do: full_name(user)
  defp extract_field(%{user: user}, key) when key in ["email", :email], do: portal_email(user)

  defp extract_field(row, key) when key in ["status", :status], do: status_label(row)

  defp extract_field(_, _), do: ""

  # --- status rendering ------------------------------------------------

  defp status_label(%{user: %{date_deleted: d}}) when not is_nil(d), do: "deleted"
  defp status_label(%{online?: true}), do: "online"
  defp status_label(_), do: "offline"

  defp status_badge(row) do
    case status_label(row) do
      "online" ->
        Phoenix.HTML.raw(~s(<span class="badge text-bg-success">online</span>))

      "deleted" ->
        Phoenix.HTML.raw(~s(<span class="badge text-bg-danger">deleted</span>))

      _ ->
        Phoenix.HTML.raw(~s(<span class="badge text-bg-secondary">offline</span>))
    end
  end

end
