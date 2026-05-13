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

defmodule Prodigy.Portal.UserLive.Settings.ApiKeys do
  @moduledoc """
  `/users/settings/api-keys` - user-managed long-lived bearer tokens
  for the `/api/v1` HTTP surface. Route is gated in the router by a
  `:require_scope, :api_keys, :self` on_mount hook; reaching this
  module means the visitor holds that scope.

  State the module owns:

    * `api_keys` - the user's rows, active + revoked
    * `api_key_form` - the form for minting a new key
    * `api_key_selectable_scopes` - the subset of the owner's scopes
      that can attach to a new key (excludes `forbidden_for_api_keys`)
    * `current_owner_scopes` - owner's live scope set, used to render
      "degraded" badges on keys whose scopes the owner has since lost
    * `new_api_key` - transient plaintext banner shown once after mint
  """
  use Prodigy.Portal, :live_view

  on_mount {Prodigy.Portal.UserAuth, :require_sudo_mode}

  import Prodigy.Portal.UserLive.Settings.Shell

  alias Prodigy.Core.Data.Portal.ApiKey
  alias Prodigy.Portal.ApiKeys
  alias Prodigy.Portal.Authz

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:new_api_key, nil)
     |> assign_state()}
  end

  @impl true
  def handle_event("validate", %{"api_key" => params}, socket) do
    form =
      params
      |> changeset()
      |> Map.put(:action, :validate)
      |> to_form(as: :api_key)

    {:noreply, assign(socket, :api_key_form, form)}
  end

  def handle_event("create", %{"api_key" => params}, socket) do
    user = socket.assigns.current_scope.user
    # The checkbox list uses name="api_key[scopes][]" which the browser
    # omits entirely when nothing is checked. Force an empty list in
    # that case so the ApiKeys.create default-to-owner-scopes fallback
    # doesn't kick in - the UI has its own opinion about what the key
    # should carry.
    params = Map.put_new(params, "scopes", [])

    case ApiKeys.create(user.id, params) do
      {:ok, %ApiKey{plaintext: plaintext}} ->
        {:noreply,
         socket
         |> assign(:new_api_key, plaintext)
         |> assign_state()
         |> put_flash(:info, "Key created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :api_key_form, to_form(changeset, as: :api_key, action: :insert))}
    end
  end

  def handle_event("dismiss_new", _params, socket) do
    {:noreply, assign(socket, :new_api_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Integer.parse(id) do
      {id_int, ""} ->
        case ApiKeys.revoke(user.id, id_int) do
          {:ok, _} ->
            # data-confirm gated the action; silent success.
            {:noreply, assign_state(socket)}

          :not_found ->
            {:noreply, put_flash(socket, :error, "Key not found.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't revoke that key.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Bad key id.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={:api_keys} current_scope={@current_scope} flash={@flash}>
      <p class="text-muted small">
        Long-lived tokens used by <code>podbutil</code> and other CLI clients to authenticate against
        the <code>/api/v1</code> HTTP surface. A key carries a subset of your scopes; its
        capability on each request is the intersection of that subset with your current scopes,
        so any scope you lose instantly degrades every key you own.
      </p>

      <div :if={@new_api_key} class="alert alert-success mt-3" role="alert">
        <div class="d-flex justify-content-between align-items-start">
          <div>
            <strong>Key created.</strong> Copy it now - once you dismiss this banner it's gone
            (the server only stores a hash).
          </div>
          <button
            type="button"
            class="btn btn-sm btn-link"
            phx-click="dismiss_new"
            aria-label="Dismiss"
          >
            Dismiss
          </button>
        </div>
        <pre class="mt-2 mb-0 p-2 bg-body-tertiary border rounded user-select-all"><code id="new-api-key-plaintext">{@new_api_key}</code></pre>
      </div>

      <.form
        for={@api_key_form}
        id="api_key_form"
        phx-submit="create"
        phx-change="validate"
        class="mt-3"
      >
        <div class="row g-2 align-items-end">
          <div class="col">
            <.input
              field={@api_key_form[:name]}
              type="text"
              label="New key label"
              placeholder="e.g. laptop-podbutil"
              spellcheck="false"
              required
            />
          </div>
          <div class="col-auto">
            <.button phx-disable-with="Generating...">Generate key</.button>
          </div>
        </div>

        <fieldset :if={@api_key_selectable_scopes != []} class="mt-3">
          <legend class="form-label mb-2">Scopes on this key</legend>
          <p class="text-muted small mb-2">
            Pick the scopes this key should carry. Leave all boxes unchecked for a
            capability-less key (useful only for <code>/api/v1/ping</code>).
          </p>
          <div class="row row-cols-1 row-cols-md-2 g-1">
            <div :for={scope <- @api_key_selectable_scopes} class="col">
              <div class="form-check">
                <input
                  type="checkbox"
                  class="form-check-input"
                  id={"api-key-scope-#{scope}"}
                  name="api_key[scopes][]"
                  value={scope}
                />
                <label class="form-check-label font-monospace small" for={"api-key-scope-#{scope}"}>
                  {scope}
                </label>
              </div>
            </div>
          </div>
        </fieldset>
        <p :if={@api_key_selectable_scopes == []} class="text-muted small mt-3">
          You currently have no scopes that can attach to an API key. The key you mint will only
          be able to hit <code>/api/v1/ping</code>.
        </p>
      </.form>

      <table :if={@api_keys != []} class="table table-sm mt-3">
        <thead>
          <tr>
            <th>Label</th>
            <th>Prefix</th>
            <th>Scopes</th>
            <th>Created</th>
            <th>Last used</th>
            <th>Status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={key <- @api_keys}>
            <td>{key.name}</td>
            <td><code>{key.key_prefix}...</code></td>
            <td>
              <%= cond do %>
                <% key.scopes == [] -> %>
                  <span class="text-muted small">(none - ping only)</span>
                <% true -> %>
                  <span
                    :for={scope <- key.scopes}
                    class={"badge me-1 font-monospace fw-normal " <> scope_badge_class(scope, @current_owner_scopes)}
                    title={scope_title(scope, @current_owner_scopes)}
                  >
                    {scope}
                  </span>
              <% end %>
            </td>
            <td>{format_date(key.inserted_at)}</td>
            <td>{format_date(key.last_used_at) || "-"}</td>
            <td>
              <span :if={key.revoked_at} class="badge text-bg-secondary">Revoked</span>
              <span :if={is_nil(key.revoked_at)} class="badge text-bg-success">Active</span>
            </td>
            <td class="text-end">
              <button
                :if={is_nil(key.revoked_at)}
                type="button"
                class="btn btn-sm btn-outline-danger"
                phx-click="revoke"
                phx-value-id={key.id}
                data-confirm={"Revoke key '#{key.name}'? Any client using it will stop working immediately."}
              >
                Revoke
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@api_keys == []} class="text-muted small mt-3">No API keys yet.</p>
    </.shell>
    """
  end

  # -- state -----------------------------------------------------------

  defp assign_state(socket) do
    user = socket.assigns.current_scope.user
    owner_scopes = Authz.effective_scopes(user)
    forbidden = MapSet.new(Authz.forbidden_for_api_keys())

    selectable =
      owner_scopes
      |> MapSet.difference(forbidden)
      |> Enum.sort()

    socket
    |> assign(:api_keys, ApiKeys.list_for_user(user.id))
    |> assign(:api_key_form, to_form(changeset(%{}), as: :api_key))
    |> assign(:api_key_selectable_scopes, selectable)
    |> assign(:current_owner_scopes, owner_scopes)
  end

  # Shallow changeset just for form validation - the real insert goes
  # through ApiKeys.create/2 which builds its own changeset with the
  # generated secret.
  defp changeset(attrs) do
    types = %{name: :string}

    {%{}, types}
    |> Ecto.Changeset.cast(attrs, [:name])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 80)
  end

  # -- render helpers --------------------------------------------------

  # Badge colour for a scope on an existing key. Green when the owner
  # still holds it; warning/strikethrough when the owner has lost it
  # since the key was minted (the key will refuse to exercise that
  # scope on requests until the grant is restored).
  defp scope_badge_class(scope, current) do
    if MapSet.member?(current, scope) do
      "text-bg-light border"
    else
      "text-bg-warning text-decoration-line-through"
    end
  end

  defp scope_title(scope, current) do
    if MapSet.member?(current, scope) do
      scope
    else
      "#{scope} - degraded (you no longer hold this scope)"
    end
  end

  defp format_date(nil), do: nil

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
