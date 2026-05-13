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

defmodule Prodigy.Portal.AdminLive.Portal.Users do
  @moduledoc """
  `/admin/portal/users` - manage portal-user accounts. Grant and
  revoke roles, direct scopes, and force-logout. All mutations flow
  through `Prodigy.Portal.Authz` so the two RBAC invariants run and
  every change lands in the audit log.
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, {:require_scope, :portal_users, :view}}

  alias Prodigy.Core.Data.Portal.Invite
  alias Prodigy.Core.Data.Portal.Role
  alias Prodigy.Portal.Admin.PortalUsers
  alias Prodigy.Portal.AdminLive.Layouts
  alias Prodigy.Portal.Authz
  alias Prodigy.Portal.Invites
  alias Prodigy.Portal.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:rows, PortalUsers.list())
     |> assign(:filters, %{})
     |> assign(:roles, Authz.list_roles())
     |> assign(:all_scopes, Authz.all_scopes())
     |> assign(:editing_user, nil)
     |> assign(:edit_mode, nil)
     |> assign(:editing_invites, [])
     # Read once at mount. The Settings page is a separate LiveView; flipping
     # the toggle there + navigating back here re-mounts and re-reads.
     |> assign(:invitation_only?, Settings.invitation_only?())}
  end

  # Each filter input fires its own "filter" event with the column key
  # in phx-value-key and the new value in the input's name=value field.
  # Fired per-input rather than as one form so the per-row quota input
  # (which lives inside the same table) doesn't have to share a form.
  @impl true
  def handle_event("filter", %{"key" => key, "value" => value}, socket) do
    filters =
      if value == "" do
        Map.delete(socket.assigns.filters, key)
      else
        Map.put(socket.assigns.filters, key, value)
      end

    {:noreply, assign(socket, :filters, filters)}
  end

  def handle_event("open_edit", %{"id" => id}, socket) do
    row = find_row(socket, id)
    invites = if row, do: Invites.list_for_inviter(row.user.id), else: []
    {:noreply, assign(socket, editing_user: row, edit_mode: :roles, editing_invites: invites)}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, editing_user: nil, edit_mode: nil, editing_invites: [])}
  end

  def handle_event("switch_edit_mode", %{"mode" => mode}, socket) do
    mode_atom = String.to_existing_atom(mode)
    {:noreply, assign(socket, :edit_mode, mode_atom)}
  end

  def handle_event("toggle_role", %{"user_id" => user_id, "role" => role_name} = params, socket) do
    actor_id = actor_id(socket)
    uid = String.to_integer(user_id)
    checked? = params["_target"] == nil or params["value"] == "on"

    result =
      if currently_has_role?(socket, uid, role_name) do
        Authz.revoke_role(actor_id, uid, role_name)
      else
        Authz.grant_role(actor_id, uid, role_name)
      end

    _ = checked?
    {:noreply, handle_grant_result(socket, result, uid)}
  end

  def handle_event("toggle_scope", %{"user_id" => user_id, "scope" => scope}, socket) do
    actor_id = actor_id(socket)
    uid = String.to_integer(user_id)

    result =
      if currently_has_direct_scope?(socket, uid, scope) do
        Authz.revoke_scope(actor_id, uid, scope)
      else
        Authz.grant_scope(actor_id, uid, scope)
      end

    {:noreply, handle_grant_result(socket, result, uid)}
  end

  def handle_event("set_quota", %{"user_id" => user_id, "quota" => quota}, socket) do
    uid = String.to_integer(user_id)

    case Enum.find(socket.assigns.rows, &(&1.user.id == uid)) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      %{user: user} ->
        case PortalUsers.set_quota(actor_id(socket), user, parse_quota(quota)) do
          {:ok, _} ->
            {:noreply, assign(socket, :rows, PortalUsers.list())}

          {:error, :below_count} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Quota can't be less than the user's current account count."
             )}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "Quota must be between 1 and 10.")}
        end
    end
  end

  def handle_event("set_invite_quota", %{"user_id" => user_id, "quota" => quota}, socket) do
    uid = String.to_integer(user_id)

    case Enum.find(socket.assigns.rows, &(&1.user.id == uid)) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      %{user: user} ->
        case PortalUsers.set_invite_quota(actor_id(socket), user, parse_quota(quota)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:rows, PortalUsers.list())
             |> refresh_editing_user(uid)}

          {:error, :below_count} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Invite quota can't be lower than the user's outstanding non-revoked invites."
             )}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "Invite quota must be between 0 and 50.")}
        end
    end
  end

  def handle_event("revoke_invite", %{"id" => invite_id}, socket) do
    actor = socket.assigns.current_scope.user
    iid = String.to_integer(invite_id)
    invite = Enum.find(socket.assigns.editing_invites, &(&1.id == iid))

    if is_nil(invite) do
      {:noreply, put_flash(socket, :error, "Invite not found.")}
    else
      case Invites.revoke(invite, actor) do
        {:ok, _} ->
          uid = invite.inviter_id

          {:noreply,
           socket
           |> assign(:rows, PortalUsers.list())
           |> assign(:editing_invites, Invites.list_for_inviter(uid))
           |> refresh_editing_user(uid)
           |> put_flash(:info, "Invite revoked.")}

        {:error, :already_redeemed} ->
          {:noreply, put_flash(socket, :error, "That invite has already been redeemed.")}

        {:error, :already_revoked} ->
          {:noreply, put_flash(socket, :error, "That invite was already revoked.")}
      end
    end
  end

  def handle_event("force_logout", %{"id" => id}, socket) do
    uid = String.to_integer(id)

    case Enum.find(socket.assigns.rows, &(&1.user.id == uid)) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      %{user: user} ->
        :ok = PortalUsers.force_logout(user, actor_id(socket))

        {:noreply,
         socket
         |> put_flash(:info, "Sessions disconnected for #{user.email}.")
         |> assign(:rows, PortalUsers.list())}
    end
  end

  # --- helpers -------------------------------------------------------

  defp actor_id(socket), do: socket.assigns.current_scope.user.id

  defp find_row(socket, id) do
    id_int = String.to_integer(id)
    Enum.find(socket.assigns.rows, &(&1.user.id == id_int))
  end

  defp currently_has_role?(socket, uid, role_name) do
    Enum.any?(socket.assigns.rows, fn row ->
      row.user.id == uid and Enum.any?(row.roles, &(&1.name == role_name))
    end)
  end

  defp currently_has_direct_scope?(socket, uid, scope) do
    Enum.any?(socket.assigns.rows, fn row ->
      row.user.id == uid and scope in row.direct_scopes
    end)
  end

  defp handle_grant_result(socket, {:ok, _}, uid) do
    socket
    |> assign(:rows, PortalUsers.list())
    |> refresh_editing_user(uid)
  end

  defp handle_grant_result(socket, {:error, reason}, _uid) do
    put_flash(socket, :error, "Change refused: #{format_reason(reason)}.")
  end

  defp refresh_editing_user(socket, uid) do
    case socket.assigns.editing_user do
      %{user: %{id: ^uid}} ->
        new_row = Enum.find(socket.assigns.rows, &(&1.user.id == uid))
        assign(socket, :editing_user, new_row)

      _ ->
        socket
    end
  end

  defp format_reason(:last_admin), do: "would leave the system without a platform admin"
  defp format_reason(:self_demotion), do: "another admin must perform this"
  defp format_reason(:target_not_found), do: "target user not found"
  defp format_reason(:role_not_found), do: "role not found"
  defp format_reason(:not_granted), do: "no such grant exists"
  defp format_reason(other), do: inspect(other)

  defp parse_quota(quota) when is_binary(quota) do
    case Integer.parse(quota) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_quota(quota) when is_integer(quota), do: quota

  defp invite_status_badge(invite) do
    case Invite.status(invite) do
      :pending ->
        Phoenix.HTML.raw(~s(<span class="badge text-bg-secondary">pending</span>))

      :redeemed ->
        Phoenix.HTML.raw(~s(<span class="badge text-bg-success">redeemed</span>))

      :revoked ->
        Phoenix.HTML.raw(~s(<span class="badge text-bg-warning">revoked</span>))
    end
  end

  # --- row pipeline -------------------------------------------------

  defp visible_rows(rows, filters) when map_size(filters) == 0, do: rows

  defp visible_rows(rows, filters) do
    Enum.filter(rows, fn row ->
      Enum.all?(filters, fn {key, value} ->
        haystack = extract_field(row, key) |> String.downcase()
        needle = String.downcase(value)
        String.contains?(haystack, needle)
      end)
    end)
  end

  defp extract_field(%{user: %{email: email}}, "email"), do: to_string(email)

  defp extract_field(%{identities: identities}, "identities"),
    do: identities |> Enum.map_join(" ", &to_string(&1.provider))

  defp extract_field(%{roles: roles}, "roles"),
    do: roles |> Enum.map_join(" ", & &1.label)

  defp extract_field(%{direct_scopes: scopes}, "direct_scopes"),
    do: Enum.join(scopes, " ")

  defp extract_field(_, _), do: ""

  # --- rendering -----------------------------------------------------

  @impl true
  def render(assigns) do
    rows = visible_rows(assigns.rows, assigns.filters)
    assigns = assign(assigns, :visible_rows, rows)

    ~H"""
    <Layouts.wrapper
      active={:portal_users}
      current_scope={@current_scope}
      flash={@flash}
      page_title="Portal Users"
    >
      <p class="text-muted small">
        Portal accounts - the operators who sign in to this console. Each row's
        scopes are the union of their role memberships and any direct scope
        grants. Role and scope changes write to the audit log.
      </p>

      <div class="mb-2">
        <span class="text-muted small">{length(@visible_rows)} of {length(@rows)} users</span>
      </div>

      <table class="table table-sm table-hover align-middle">
        <thead>
          <tr>
            <th>Email</th>
            <th>Identities</th>
            <th>Roles</th>
            <th>Direct scopes</th>
            <th class="text-end">Service users</th>
            <th :if={@invitation_only?} class="text-end">Invites</th>
            <th></th>
          </tr>
          <tr>
            <th>
              <input
                type="text"
                class="form-control form-control-sm"
                name="value"
                value={Map.get(@filters, "email", "")}
                placeholder="filter"
                phx-change="filter"
                phx-value-key="email"
                phx-debounce="200"
              />
            </th>
            <th>
              <input
                type="text"
                class="form-control form-control-sm"
                name="value"
                value={Map.get(@filters, "identities", "")}
                placeholder="filter"
                phx-change="filter"
                phx-value-key="identities"
                phx-debounce="200"
              />
            </th>
            <th>
              <input
                type="text"
                class="form-control form-control-sm"
                name="value"
                value={Map.get(@filters, "roles", "")}
                placeholder="filter"
                phx-change="filter"
                phx-value-key="roles"
                phx-debounce="200"
              />
            </th>
            <th>
              <input
                type="text"
                class="form-control form-control-sm"
                name="value"
                value={Map.get(@filters, "direct_scopes", "")}
                placeholder="filter"
                phx-change="filter"
                phx-value-key="direct_scopes"
                phx-debounce="200"
              />
            </th>
            <th></th>
            <th :if={@invitation_only?}></th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @visible_rows}>
            <td>{row.user.email}</td>
            <td>
              <span
                :for={identity <- row.identities}
                class="badge text-bg-light border me-1 font-monospace fw-normal"
              >
                {identity.provider}
              </span>
            </td>
            <td>
              <span
                :for={role <- row.roles}
                class="badge text-bg-primary me-1 fw-normal"
                title={role.description}
              >
                {role.label}
              </span>
              <span :if={row.roles == []} class="text-muted small">-</span>
            </td>
            <td>
              <span
                :for={scope <- row.direct_scopes}
                class="badge text-bg-secondary me-1 font-monospace fw-normal"
              >
                {scope}
              </span>
              <span :if={row.direct_scopes == []} class="text-muted small">-</span>
            </td>
            <td class="text-end">
              <%= if Authz.can?(@current_scope, :grants, :assign) do %>
                <form
                  phx-change="set_quota"
                  class="d-inline-flex align-items-center gap-1 mb-0 justify-content-end"
                >
                  <input type="hidden" name="user_id" value={row.user.id} />
                  <span class="me-1">{row.service_user_count} of</span>
                  <input
                    id={"quota-input-" <> Integer.to_string(row.user.id)}
                    type="number"
                    name="quota"
                    value={row.user.service_user_quota}
                    min={max(row.service_user_count, 1)}
                    max="10"
                    class="form-control form-control-sm text-center"
                    style="width: 4.5rem"
                    phx-hook="QuotaInput"
                    phx-debounce="blur"
                    aria-label="service user quota"
                  />
                </form>
              <% else %>
                {row.service_user_count} of {row.user.service_user_quota}
              <% end %>
            </td>
            <td :if={@invitation_only?} class="text-end">
              <%= if Authz.can?(@current_scope, :grants, :assign) do %>
                <form
                  phx-change="set_invite_quota"
                  class="d-inline-flex align-items-center gap-1 mb-0 justify-content-end"
                >
                  <input type="hidden" name="user_id" value={row.user.id} />
                  <span class="me-1">{row.invite_count} of</span>
                  <input
                    id={"invite-quota-input-" <> Integer.to_string(row.user.id)}
                    type="number"
                    name="quota"
                    value={row.user.invite_quota}
                    min={row.invite_count}
                    max="50"
                    class="form-control form-control-sm text-center"
                    style="width: 4.5rem"
                    phx-hook="QuotaInput"
                    phx-debounce="blur"
                    aria-label="invite quota"
                  />
                </form>
              <% else %>
                {row.invite_count} of {row.user.invite_quota}
              <% end %>
            </td>
            <td class="text-end text-nowrap">
              <.action_icon_button
                :if={Authz.can?(@current_scope, :grants, :assign)}
                icon={:edit}
                variant={:primary}
                phx-click="open_edit"
                phx-value-id={row.user.id}
                title="Edit roles and scopes"
                aria-label={"Edit " <> row.user.email}
              />
              <.action_icon_button
                :if={Authz.can?(@current_scope, :portal_users, :disable)}
                icon={:disconnect}
                variant={:danger}
                spacing="ms-2"
                phx-click="force_logout"
                phx-value-id={row.user.id}
                data-confirm={"Force log out every session for #{row.user.email}?"}
                title="Force log out"
                aria-label={"Force-logout " <> row.user.email}
              />
            </td>
          </tr>
        </tbody>
      </table>

      <.modal
        :if={@editing_user}
        id="edit-portal-user-modal"
        show
        size="xl"
        title={"Edit " <> @editing_user.user.email}
        on_cancel={JS.push("close_modal")}
      >
        <ul class="nav nav-tabs mb-3">
          <li class="nav-item">
            <a
              href="#"
              class={"nav-link #{if @edit_mode == :roles, do: "active"}"}
              phx-click="switch_edit_mode"
              phx-value-mode="roles"
            >
              Roles
            </a>
          </li>
          <li class="nav-item">
            <a
              href="#"
              class={"nav-link #{if @edit_mode == :scopes, do: "active"}"}
              phx-click="switch_edit_mode"
              phx-value-mode="scopes"
            >
              Direct scopes
            </a>
          </li>
          <li :if={@invitation_only?} class="nav-item">
            <a
              href="#"
              class={"nav-link #{if @edit_mode == :invites, do: "active"}"}
              phx-click="switch_edit_mode"
              phx-value-mode="invites"
            >
              Invites
              <span class="badge text-bg-light border ms-1">
                {@editing_user.invite_count}/{@editing_user.user.invite_quota}
              </span>
            </a>
          </li>
        </ul>

        <div :if={@edit_mode == :roles}>
          <p class="text-muted small">
            Roles bundle scopes - check to grant, uncheck to revoke. Builtin roles are marked.
          </p>
          <div class="form-check mb-2" :for={role <- @roles}>
            <input
              type="checkbox"
              class="form-check-input"
              id={"role-#{role.name}"}
              checked={role_checked?(@editing_user, role)}
              phx-click="toggle_role"
              phx-value-user_id={@editing_user.user.id}
              phx-value-role={role.name}
            />
            <label class="form-check-label" for={"role-#{role.name}"}>
              <strong>{role.label}</strong>
              <span :if={role.builtin} class="badge text-bg-light border ms-1">builtin</span>
              <div class="text-muted small">{role.description}</div>
            </label>
          </div>
        </div>

        <div :if={@edit_mode == :scopes}>
          <p class="text-muted small">
            Direct scope grants on top of role memberships - use sparingly for
            one-off capabilities that don't fit an existing role.
          </p>
          <div class="row row-cols-1 row-cols-md-2 row-cols-lg-3 g-1">
            <div class="col" :for={scope <- @all_scopes}>
              <div class="form-check mb-1">
                <input
                  type="checkbox"
                  class="form-check-input"
                  id={"direct-#{scope}"}
                  checked={scope in @editing_user.direct_scopes}
                  phx-click="toggle_scope"
                  phx-value-user_id={@editing_user.user.id}
                  phx-value-scope={scope}
                />
                <label class="form-check-label font-monospace small" for={"direct-#{scope}"}>
                  {scope}
                  <span
                    :if={scope in MapSet.to_list(@editing_user.effective_scopes) and scope not in @editing_user.direct_scopes}
                    class="text-muted"
                    title="already granted through a role"
                  >
                    (via role)
                  </span>
                </label>
              </div>
            </div>
          </div>
        </div>

        <div :if={@invitation_only? and @edit_mode == :invites}>
          <p class="text-muted small">
            Invitations issued by this user. The quota above the table caps how
            many non-revoked invites they can hold at once. Pending invites
            still count against the quota - revoke them here if you need to
            free a slot. Redeemed invites stay as audit history and never
            expire.
          </p>

          <div class="d-flex align-items-center gap-2 mb-3">
            <span class="text-muted small">Invite quota:</span>
            <form
              phx-change="set_invite_quota"
              class="d-inline-flex align-items-center gap-1 mb-0"
            >
              <input type="hidden" name="user_id" value={@editing_user.user.id} />
              <input
                id={"invite-quota-modal-" <> Integer.to_string(@editing_user.user.id)}
                type="number"
                name="quota"
                value={@editing_user.user.invite_quota}
                min={@editing_user.invite_count}
                max="50"
                class="form-control form-control-sm text-center"
                style="width: 4.5rem"
                phx-hook="QuotaInput"
                phx-debounce="blur"
                aria-label="invite quota"
              />
            </form>
            <span class="text-muted small">
              ({@editing_user.invite_count} non-revoked outstanding)
            </span>
          </div>

          <% visible_invites = Enum.reject(@editing_invites, &(Invite.status(&1) == :revoked)) %>
          <% revoked_count = Enum.count(@editing_invites, &(Invite.status(&1) == :revoked)) %>

          <table class="table table-sm align-middle">
            <thead>
              <tr>
                <th>Code</th>
                <th>Status</th>
                <th>Created</th>
                <th>Redeemer</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={invite <- visible_invites}>
                <td><code class="font-monospace">{invite.code}</code></td>
                <td>{invite_status_badge(invite)}</td>
                <td class="text-muted small text-nowrap">
                  {Calendar.strftime(invite.inserted_at, "%Y-%m-%d %H:%M")}
                </td>
                <td class="font-monospace small">
                  <%= if invite.redeemer do %>
                    {invite.redeemer.email}
                  <% else %>
                    <span class="text-muted">-</span>
                  <% end %>
                </td>
                <td class="text-end">
                  <button
                    :if={Invite.status(invite) == :pending}
                    type="button"
                    class="btn btn-sm btn-outline-warning"
                    phx-click="revoke_invite"
                    phx-value-id={invite.id}
                    data-confirm="Revoke this invite? The URL will stop working."
                  >
                    Revoke
                  </button>
                </td>
              </tr>
              <tr :if={visible_invites == [] and revoked_count == 0}>
                <td colspan="5" class="text-center text-muted py-3">
                  No invitations issued.
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={revoked_count > 0} class="text-muted small mb-0">
            + {revoked_count} revoked invite{if revoked_count == 1, do: "", else: "s"} hidden.
          </p>
        </div>

        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_modal">Close</button>
        </:footer>
      </.modal>
    </Layouts.wrapper>
    """
  end

  defp role_checked?(row, %Role{id: role_id}) do
    Enum.any?(row.roles, &(&1.id == role_id))
  end
end
