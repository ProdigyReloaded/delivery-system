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

defmodule Prodigy.Portal.AdminLive.Users.EditModal do
  @moduledoc """
  Modal owning the admin "Edit service user" flow. The parent
  `AdminLive.Users` opens this LiveComponent by rendering it with a
  `user` assign; the LC manages its own form, tab selection, and
  in-memory data-collection policy toggles. On save:

    * if the user changeset + policy persist cleanly, the LC messages
      the parent `{:edit_saved, user}` so the parent flashes + closes;
    * if the changeset fails validation, the LC re-renders with errors.

  Layout of the form is declared by
  `Prodigy.Portal.Admin.UserForm` + `DataCollectionPolicy.fields/0`;
  this module is pure rendering / event handling and holds no
  domain-specific knowledge of the field set.
  """
  use Prodigy.Portal, :live_component

  alias Prodigy.Portal.Admin.DataCollectionPolicy, as: PolicyAdmin
  alias Prodigy.Portal.Admin.Users, as: Admin
  alias Prodigy.Portal.Admin.UserForm

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(%{user: user} = assigns, socket) do
    # First-time seed (or re-seed on re-opened modal for a different user).
    seed? = Map.get(socket.assigns, :user) != user

    socket =
      socket
      |> assign(assigns)

    socket =
      if seed? do
        assign(socket,
          form: to_form(Admin.edit_changeset(user), as: :user),
          tab: default_tab(),
          policy: PolicyAdmin.get(user.id)
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Admin.edit_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Admin.update(socket.assigns.user, params) do
      {:ok, user} ->
        # Commit the edited-in-memory policy alongside the user form so
        # all modal changes land atomically from the admin's perspective.
        case socket.assigns.policy do
          nil -> :ok
          policy -> {:ok, _} = PolicyAdmin.save(user.id, policy)
        end

        send(self(), {:edit_saved, user})
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}

      {:error, reason} ->
        send(self(), {:modal_flash, :error, "Couldn't save: #{inspect(reason)}"})
        {:noreply, socket}
    end
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("toggle_policy", %{"field" => field_str}, socket) do
    field = String.to_existing_atom(field_str)
    policy = socket.assigns.policy
    # In-memory toggle only; actual upsert happens on save.
    updated = Map.put(policy, field, not (Map.get(policy, field) == true))
    {:noreply, assign(socket, :policy, updated)}
  end

  def handle_event("toggle_all_policy", %{"value" => value_str}, socket) do
    value = value_str == "true"
    policy = socket.assigns.policy

    updated =
      Enum.reduce(PolicyAdmin.field_atoms(), policy, fn f, acc ->
        Map.put(acc, f, value)
      end)

    {:noreply, assign(socket, :policy, updated)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id={@id <> "-modal"}
        show
        size="lg"
        title={"Edit #{@user.id}"}
        on_cancel={JS.push("close_modal")}
      >
        <.form
          :let={f}
          for={@form}
          id={@id <> "-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
        >
          <ul class="nav nav-tabs mb-3">
            <li :for={tab <- all_tabs()} class="nav-item">
              <a
                href="#"
                class={"nav-link #{if @tab == tab.id, do: "active"}"}
                phx-click="select_tab"
                phx-value-tab={tab.id}
                phx-target={@myself}
              >
                {tab.tab}
              </a>
            </li>
          </ul>

          <div class="edit-tab-content">
            <div
              :for={tab <- form_layout()}
              class={"edit-tab-pane #{if @tab == tab.id, do: "is-active"}"}
            >
              <div :for={group <- tab.groups} class="mb-3">
                <h6 :if={group.title} class="border-bottom pb-1 mb-3">{group.title}</h6>
                <p :if={group[:description]} class="text-muted small mb-2">
                  {group.description}
                </p>
                <div :if={group[:columns] == 2} class="row">
                  <div :for={column <- split_columns(group.fields, 2)} class="col-md-6">
                    <.edit_field :for={spec <- column} f={f} spec={spec} user={@user} />
                  </div>
                </div>
                <div :if={!group[:columns]}>
                  <.edit_field :for={spec <- group.fields} f={f} spec={spec} user={@user} />
                </div>
              </div>
            </div>

            <div class={"edit-tab-pane #{if @tab == :data_collection, do: "is-active"}"}>
              <p class="text-muted small">
                Flags here toggle the RS client's data-collection bitmask
                sent at next logon.
              </p>
              <div class="d-flex justify-content-end mb-2 gap-2">
                <button
                  type="button"
                  class="btn btn-sm btn-outline-secondary"
                  phx-click="toggle_all_policy"
                  phx-value-value="true"
                  phx-target={@myself}
                >
                  All on
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-outline-secondary"
                  phx-click="toggle_all_policy"
                  phx-value-value="false"
                  phx-target={@myself}
                >
                  All off
                </button>
              </div>
              <div class="row row-cols-1 row-cols-md-2 g-1">
                <div :for={{field, label} <- PolicyAdmin.fields()} class="col">
                  <div class="form-check">
                    <input
                      type="checkbox"
                      class="form-check-input"
                      id={"policy-#{field}"}
                      checked={policy_checked?(@policy, field)}
                      phx-click="toggle_policy"
                      phx-value-field={Atom.to_string(field)}
                      phx-target={@myself}
                    />
                    <label class="form-check-label" for={"policy-#{field}"}>{label}</label>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </.form>
        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_modal">
            Cancel
          </button>
          <button type="submit" form={@id <> "-form"} class="btn btn-primary">
            Save
          </button>
        </:footer>
      </.modal>
    </div>
    """
  end

  # -- form-layout helpers ----------------------------------------------

  defp default_tab, do: UserForm.layout() |> List.first() |> Map.fetch!(:id)

  defp all_tabs do
    UserForm.layout() ++ [%{id: :data_collection, tab: "Data Collection"}]
  end

  defp form_layout, do: UserForm.layout()

  # Split a list of field specs into `n` contiguous chunks so a group
  # can render as multiple side-by-side columns. Chunk size is
  # ceil(len/n) so any remainder lands in earlier columns.
  defp split_columns(fields, n) when n > 1 do
    chunk = ceil(length(fields) / n)
    Enum.chunk_every(fields, chunk)
  end

  defp policy_checked?(nil, _field), do: false
  defp policy_checked?(policy, field), do: Map.get(policy, field) == true

  # Render one form row in Bootstrap's horizontal layout (label on the
  # left, input on the right). Dispatches on `spec.type` so the layout
  # data remains the single source of truth.
  attr :f, :any, required: true
  attr :spec, :map, required: true
  attr :user, :any, required: true

  defp edit_field(%{spec: %{type: :name_row}} = assigns) do
    errors =
      assigns.spec.subfields
      |> Enum.flat_map(fn sf -> Enum.map(assigns.f[sf.field].errors, &error_message/1) end)

    assigns = assign(assigns, :row_errors, errors)

    ~H"""
    <div class="row mb-2">
      <label class="col-sm-4 col-form-label col-form-label-sm text-sm-end">
        {@spec.label}
      </label>
      <div class="col-sm-8">
        <div class="d-flex gap-1">
          <input
            :for={sf <- @spec.subfields}
            type="text"
            id={@f[sf.field].id}
            name={@f[sf.field].name}
            value={Phoenix.HTML.Form.normalize_value("text", @f[sf.field].value)}
            placeholder={sf.placeholder}
            maxlength={Map.get(sf, :maxlength)}
            style={name_row_style(sf)}
            class={name_row_class(sf, @f[sf.field].errors != [])}
          />
        </div>
        <div :for={msg <- @row_errors} class="invalid-feedback d-block">{msg}</div>
      </div>
    </div>
    """
  end

  defp edit_field(%{spec: %{type: :readonly}} = assigns) do
    source =
      case assigns.spec.source do
        :user -> assigns.user
        :household -> assigns.user.household
      end

    assigns = assign(assigns, :display_value, assigns.spec.value_fn.(source))

    ~H"""
    <div class="row mb-2">
      <label class="col-sm-4 col-form-label col-form-label-sm text-sm-end text-muted">
        {@spec.label}
      </label>
      <div class="col-sm-8">
        <span class="form-control-plaintext form-control-sm">{@display_value}</span>
      </div>
    </div>
    """
  end

  defp edit_field(assigns) do
    field = assigns.f[assigns.spec.field]

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:errors, Enum.map(field.errors, &error_message/1))

    ~H"""
    <div class="row mb-2">
      <label class="col-sm-4 col-form-label col-form-label-sm text-sm-end" for={@field.id}>
        {@spec.label}
      </label>
      <div class="col-sm-8">
        <.horiz_control field={@field} spec={@spec} errors={@errors} />
        <div :for={msg <- @errors} class="invalid-feedback d-block">{msg}</div>
      </div>
    </div>
    """
  end

  # Input control variants. Each is responsible for the actual
  # <input>/<select> tag with correct classes; the edit_field/1 wrapper
  # handles the column layout and error rendering.
  attr :field, Phoenix.HTML.FormField, required: true
  attr :spec, :map, required: true
  attr :errors, :list, required: true

  defp horiz_control(%{spec: %{type: :text}} = assigns) do
    ~H"""
    <input
      type="text"
      id={@field.id}
      name={@field.name}
      value={Phoenix.HTML.Form.normalize_value("text", @field.value)}
      class={["form-control form-control-sm", @errors != [] && "is-invalid"]}
    />
    """
  end

  defp horiz_control(%{spec: %{type: :date}} = assigns) do
    ~H"""
    <input
      type="date"
      id={@field.id}
      name={@field.name}
      value={Phoenix.HTML.Form.normalize_value("date", @field.value)}
      class={["form-control form-control-sm", @errors != [] && "is-invalid"]}
    />
    """
  end

  defp horiz_control(%{spec: %{type: :number}} = assigns) do
    min = to_string(Map.get(assigns.spec, :min, 0))
    assigns = assign(assigns, :min, min)

    ~H"""
    <input
      type="number"
      id={@field.id}
      name={@field.name}
      value={Phoenix.HTML.Form.normalize_value("number", @field.value)}
      min={@min}
      class={["form-control form-control-sm", @errors != [] && "is-invalid"]}
    />
    """
  end

  defp horiz_control(%{spec: %{type: :checkbox}} = assigns) do
    # Hidden "false" sibling ensures the form always submits a value for
    # this name even when the checkbox is unchecked (no native checkbox
    # round-trip otherwise). Plug parses duplicate keys "last wins", so
    # a checked box overrides the hidden via its later position.
    checked? = Phoenix.HTML.Form.normalize_value("checkbox", assigns.field.value)
    assigns = assign(assigns, :checked?, checked?)

    ~H"""
    <div class="form-check form-switch">
      <input type="hidden" name={@field.name} value="false" />
      <input
        type="checkbox"
        id={@field.id}
        name={@field.name}
        value="true"
        checked={@checked?}
        class="form-check-input"
      />
    </div>
    """
  end

  defp horiz_control(%{spec: %{type: :select}} = assigns) do
    options = select_options(assigns.spec.options)
    assigns = assign(assigns, :options, options)

    ~H"""
    <select
      id={@field.id}
      name={@field.name}
      class={["form-select form-select-sm", @errors != [] && "is-invalid"]}
    >
      <option :if={Map.get(@spec, :prompt)} value="">{@spec.prompt}</option>
      {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
    </select>
    """
  end

  defp error_message({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  defp name_row_style(%{maxlength: 1}), do: "max-width: 3.5rem;"
  defp name_row_style(_), do: nil

  defp name_row_class(%{maxlength: 1}, invalid?) do
    ["form-control form-control-sm text-center", invalid? && "is-invalid"]
  end

  defp name_row_class(_, invalid?) do
    ["form-control form-control-sm", invalid? && "is-invalid"]
  end

  # Normalize the layout's select options into the {label, value}
  # tuples Phoenix.Component.input/1 wants. Accepts either a flat list
  # of strings (label == value) or pre-built tuple pairs.
  defp select_options(options) do
    Enum.map(options, fn
      s when is_binary(s) -> {s, s}
      {_label, _value} = pair -> pair
    end)
  end
end
