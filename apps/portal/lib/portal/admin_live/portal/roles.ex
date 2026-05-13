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

defmodule Prodigy.Portal.AdminLive.Portal.Roles do
  @moduledoc """
  `/admin/portal/roles` - view and manage role bundles. Builtin roles
  (viewer / content-operator / support-operator / platform-admin) are
  read-only through this UI; their scope set is fixed by migration.
  Custom roles support create / edit / delete, gated on roles.manage.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :roles, :view}}

  alias Prodigy.Core.Data.Portal.Role
  alias Prodigy.Portal.Admin.Roles, as: Admin
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.Authz

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("open_new", _, socket) do
    changeset = Role.create_changeset(%{name: "", label: ""})

    {:noreply,
     socket
     |> assign(:editing, :new)
     |> assign(:form, to_form(changeset, as: :role))
     |> assign(:selected_scopes, MapSet.new())}
  end

  def handle_event("open_edit", %{"id" => id}, socket) do
    role = Authz.get_role!(String.to_integer(id))
    changeset = Role.update_changeset(role, %{})
    scopes = MapSet.new(Authz.role_scopes(role))

    {:noreply,
     socket
     |> assign(:editing, role)
     |> assign(:form, to_form(changeset, as: :role))
     |> assign(:selected_scopes, scopes)}
  end

  def handle_event("close_modal", _, socket), do: {:noreply, close_modal(socket)}

  def handle_event("toggle_scope", %{"scope" => scope}, socket) do
    selected = socket.assigns.selected_scopes

    new_set =
      if MapSet.member?(selected, scope) do
        MapSet.delete(selected, scope)
      else
        MapSet.put(selected, scope)
      end

    {:noreply, assign(socket, :selected_scopes, new_set)}
  end

  def handle_event("save", %{"role" => params}, socket) do
    scopes = MapSet.to_list(socket.assigns.selected_scopes)
    actor_id = socket.assigns.current_scope.user.id

    result =
      case socket.assigns.editing do
        :new -> Admin.create_role(actor_id, params, scopes)
        %Role{} = role -> Admin.update_role(actor_id, role, params, scopes)
      end

    case result do
      {:ok, _role} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role saved.")
         |> close_modal()
         |> refresh()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs, as: :role))}

      {:error, :builtin} ->
        {:noreply, put_flash(socket, :error, "Builtin roles cannot be edited.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save role: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    role = Authz.get_role!(String.to_integer(id))
    actor_id = socket.assigns.current_scope.user.id

    case Admin.delete_role(actor_id, role) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Role deleted.") |> refresh()}

      {:error, :builtin} ->
        {:noreply, put_flash(socket, :error, "Builtin roles cannot be deleted.")}

      {:error, {:in_use, n}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Role is held by #{n} user(s); revoke those grants first."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete: #{inspect(reason)}")}
    end
  end

  # --- helpers -------------------------------------------------------

  defp refresh(socket) do
    roles = Authz.list_roles()

    socket
    |> assign(:roles, roles)
    |> assign(:scope_by_role, Map.new(roles, &{&1.id, Authz.role_scopes(&1)}))
    |> assign(:editing, nil)
    |> assign(:form, nil)
    |> assign(:selected_scopes, MapSet.new())
    |> assign(:all_scopes, Authz.all_scopes())
  end

  defp close_modal(socket) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, nil)
    |> assign(:selected_scopes, MapSet.new())
  end

  # --- rendering -----------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.wrapper
      active={:portal_roles}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Roles"
    >
      <p class="text-muted small">
        Roles bundle scopes. Builtin roles are fixed by migration - view
        only. Custom roles can be composed from the scope catalog.
      </p>

      <div :if={Authz.can?(@current_scope, :roles, :manage)} class="mb-2 d-flex justify-content-end">
        <button type="button" class="btn btn-sm btn-primary" phx-click="open_new">
          New role...
        </button>
      </div>

      <table class="table table-sm table-hover align-middle">
        <thead>
          <tr>
            <th>Name</th>
            <th>Description</th>
            <th>Scopes</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={role <- @roles}>
            <td>
              <strong>{role.label}</strong>
              <div class="text-muted small font-monospace">{role.name}</div>
            </td>
            <td class="small">{role.description}</td>
            <td>
              <span
                :for={scope <- Map.get(@scope_by_role, role.id, [])}
                class="badge text-bg-light border me-1 font-monospace fw-normal"
              >
                {scope}
              </span>
            </td>
            <td class="text-end text-nowrap">
              <span :if={role.builtin} class="badge text-bg-light border me-2">builtin</span>
              <.action_icon_button
                :if={Authz.can?(@current_scope, :roles, :manage) and not role.builtin}
                icon={:edit}
                variant={:primary}
                phx-click="open_edit"
                phx-value-id={role.id}
                title={"Edit " <> role.label}
                aria-label={"Edit " <> role.label}
              />
              <.action_icon_button
                :if={Authz.can?(@current_scope, :roles, :manage) and not role.builtin}
                icon={:delete}
                variant={:danger}
                spacing="ms-2"
                phx-click="delete"
                phx-value-id={role.id}
                data-confirm={"Delete role '#{role.label}'?"}
                title={"Delete " <> role.label}
                aria-label={"Delete " <> role.label}
              />
            </td>
          </tr>
        </tbody>
      </table>

      <.modal
        :if={@editing}
        id="edit-role-modal"
        show
        title={if @editing == :new, do: "New role", else: "Edit role: " <> @editing.label}
        on_cancel={JS.push("close_modal")}
      >
        <.form for={@form} id="role-form" phx-submit="save">
          <.input
            :if={@editing == :new}
            field={@form[:name]}
            type="text"
            label="Machine name"
            placeholder="e.g. keyword-curator"
          />
          <.input field={@form[:label]} type="text" label="Display label" />
          <.input field={@form[:description]} type="textarea" label="Description" />

          <fieldset class="mt-3">
            <legend class="form-label mb-2">Scopes</legend>
            <div class="row row-cols-1 row-cols-md-2 g-1">
              <div :for={scope <- @all_scopes} class="col">
                <div class="form-check">
                  <input
                    type="checkbox"
                    class="form-check-input"
                    id={"role-scope-#{scope}"}
                    checked={MapSet.member?(@selected_scopes, scope)}
                    phx-click="toggle_scope"
                    phx-value-scope={scope}
                  />
                  <label
                    class="form-check-label font-monospace small"
                    for={"role-scope-#{scope}"}
                  >
                    {scope}
                  </label>
                </div>
              </div>
            </div>
          </fieldset>
        </.form>
        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_modal">
            Cancel
          </button>
          <button type="submit" form="role-form" class="btn btn-primary">Save</button>
        </:footer>
      </.modal>
    </Layouts.wrapper>
    """
  end
end
