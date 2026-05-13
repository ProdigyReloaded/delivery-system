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

defmodule Prodigy.Portal.CoreComponents do
  @moduledoc """
  Bootstrap-styled minimal UI primitives used by phx.gen.auth-generated
  LiveViews and controllers. Phoenix 1.7's default CoreComponents is
  Tailwind-first; this shim lets the generated markup render against the
  existing Bootstrap 5 CDN that the rest of the site uses.

  Components provided: `button`, `input`, `label`, `error`, `flash`,
  `flash_group`, `modal`, `action_icon_button`, `action_icon_link`.
  """
  use Phoenix.Component
  use Gettext, backend: Prodigy.Portal.Gettext

  alias Phoenix.LiveView.JS

  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={["btn btn-primary", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-3 form-check">
      <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        class="form-check-input"
        {@rest}
      />
      <label for={@id} class="form-check-label">{@label}</label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <.label for={@id}>{@label}</.label>
      <select id={@id} name={@name} class={["form-select", @errors != [] && "is-invalid"]} multiple={@multiple} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <.label for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={["form-control", @errors != [] && "is-invalid"]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <.label for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["form-control", @errors != [] && "is-invalid"]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="form-label">{render_slot(@inner_block)}</label>
    """
  end

  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="invalid-feedback d-block">
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :id, :string, default: "flash", doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      class={[
        "alert alert-dismissible fade show",
        @kind == :info && "alert-info",
        @kind == :error && "alert-danger"
      ]}
      {@rest}
    >
      <strong :if={@title}>{@title}:</strong>
      {msg}
      <button
        type="button"
        class="btn-close"
        data-bs-dismiss="alert"
        aria-label="Close"
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind})}
      ></button>
    </div>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title={gettext("Success!")} flash={@flash} />
      <.flash kind={:error} title={gettext("Error!")} flash={@flash} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :show, :boolean, default: false, doc: "whether the modal is visible"
  attr :on_cancel, :any,
    default: %JS{},
    doc: "JS command or event name fired when the backdrop / X button is clicked"

  attr :title, :string, default: nil
  attr :size, :string, default: nil, values: [nil, "sm", "lg", "xl"], doc: "Bootstrap modal-dialog size modifier"
  slot :inner_block, required: true
  slot :footer

  @doc """
  Bootstrap 5 modal. Visibility is server-driven - set `show={true}` and the
  dialog is rendered with the `.show` class and a solid backdrop div. The
  X button and backdrop click fire `@on_cancel`, which the parent typically
  hands in as `JS.push("close_modal")` or a similar server event.

  Unlike Bootstrap's JS Modal plugin, this doesn't touch `document.body` or
  manage focus-trapping. Good enough for an admin form; swap in the real
  Bootstrap API if a user-facing modal ever needs it.
  """
  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="modal fade show d-block"
      id={@id}
      tabindex="-1"
      role="dialog"
      aria-modal="true"
      style="background-color: rgba(0,0,0,0.5);"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class={["modal-dialog modal-dialog-centered", @size && "modal-#{@size}"]}>
        <div class="modal-content">
          <div class="modal-header">
            <h5 class="modal-title">{@title}</h5>
            <button
              type="button"
              class="btn-close"
              aria-label="Close"
              phx-click={@on_cancel}
            />
          </div>
          <div class="modal-body">
            {render_slot(@inner_block)}
          </div>
          <div :if={@footer != []} class="modal-footer">
            {render_slot(@footer)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc ~S"""
  Row-level action buttons rendered as an 18x18 SVG in a bare
  wrapper. Every admin table uses these instead of text buttons for
  repeated per-row actions.

      <.action_icon_button icon={:edit} variant={:primary}
        phx-click="edit" phx-value-id={row.id} title="Edit" />

      <.action_icon_link icon={:events} variant={:primary}
        href={"/admin/service/events?session_id=" <> to_string(row.id)} title="Events" />

  `icon` picks the glyph; `variant` maps to a Bootstrap text colour.
  """
  attr :icon, :atom,
    required: true,
    values: [:edit, :delete, :restore, :disconnect, :events, :reset_password, :download, :detail]

  attr :variant, :atom,
    default: :secondary,
    values: [:primary, :secondary, :danger, :warning, :success]

  attr :spacing, :string,
    default: nil,
    doc: "optional margin class (e.g. \"me-2\") for between adjacent action icons"

  attr :rest, :global,
    include:
      ~w(phx-click phx-target phx-value-id phx-value-keyword phx-value-name phx-value-sequence phx-value-type phx-value-version phx-value-index phx-value-role phx-value-scope data-confirm title aria-label disabled)

  def action_icon_button(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "border-0 bg-transparent p-0 shadow-none align-middle",
        action_icon_variant_class(@variant),
        @spacing
      ]}
      {@rest}
    >
      <.action_icon_svg icon={@icon} />
    </button>
    """
  end

  attr :icon, :atom,
    required: true,
    values: [:edit, :delete, :restore, :disconnect, :events, :reset_password, :download, :detail]

  attr :variant, :atom,
    default: :secondary,
    values: [:primary, :secondary, :danger, :warning, :success]

  attr :href, :string, required: true
  attr :spacing, :string, default: nil
  attr :rest, :global, include: ~w(title aria-label target)

  def action_icon_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={["align-middle", action_icon_variant_class(@variant), @spacing]}
      {@rest}
    >
      <.action_icon_svg icon={@icon} />
    </a>
    """
  end

  attr :icon, :atom, required: true

  defp action_icon_svg(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width="18"
      height="18"
      fill="currentColor"
      viewBox="0 0 16 16"
      aria-hidden="true"
      class="align-middle"
    >
      <.action_icon_paths icon={@icon} />
    </svg>
    """
  end

  attr :icon, :atom, required: true

  defp action_icon_paths(%{icon: :edit} = assigns) do
    ~H"""
    <path d="M12.146.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1 0 .708l-10 10a.5.5 0 0 1-.168.11l-5 2a.5.5 0 0 1-.65-.65l2-5a.5.5 0 0 1 .11-.168zM11.207 2.5 13.5 4.793 14.793 3.5 12.5 1.207zm1.586 3L10.5 3.207 4 9.707V10h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.293zm-9.761 5.175-.106.106-1.528 3.821 3.821-1.528.106-.106A.5.5 0 0 1 5 12.5V12h-.5a.5.5 0 0 1-.5-.5V11h-.5a.5.5 0 0 1-.468-.325" />
    """
  end

  defp action_icon_paths(%{icon: :delete} = assigns) do
    ~H"""
    <path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5m2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5m3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0z" />
    <path d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1H6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1h3.5a1 1 0 0 1 1 1zM4.118 4 4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4zM2.5 3h11V2h-11z" />
    """
  end

  defp action_icon_paths(%{icon: :restore} = assigns) do
    ~H"""
    <path d="M8 3a5 5 0 1 1-4.546 2.914.5.5 0 0 0-.908-.417A6 6 0 1 0 8 2z" />
    <path d="M8 4.466V.534a.25.25 0 0 0-.41-.192L5.23 2.308a.25.25 0 0 0 0 .384l2.36 1.966A.25.25 0 0 0 8 4.466" />
    """
  end

  defp action_icon_paths(%{icon: :disconnect} = assigns) do
    ~H"""
    <path d="M16 8A8 8 0 1 1 0 8a8 8 0 0 1 16 0zM5.354 4.646a.5.5 0 1 0-.708.708L7.293 8l-2.647 2.646a.5.5 0 0 0 .708.708L8 8.707l2.646 2.647a.5.5 0 0 0 .708-.708L8.707 8l2.647-2.646a.5.5 0 0 0-.708-.708L8 7.293 5.354 4.646z" />
    """
  end

  defp action_icon_paths(%{icon: :events} = assigns) do
    ~H"""
    <path d="M14 14V4.5L9.5 0H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2M9.5 3A1.5 1.5 0 0 0 11 4.5h2V14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1h5.5zM4.5 7a.5.5 0 0 0 0 1h7a.5.5 0 0 0 0-1zM5 10a.5.5 0 0 0 .5.5h6a.5.5 0 0 0 0-1h-6A.5.5 0 0 0 5 10" />
    """
  end

  defp action_icon_paths(%{icon: :reset_password} = assigns) do
    ~H"""
    <path d="M0 8a4 4 0 0 1 7.465-2H14a.5.5 0 0 1 .354.146l1.5 1.5a.5.5 0 0 1 0 .708l-1.5 1.5a.5.5 0 0 1-.708 0L13 9.207l-.646.647a.5.5 0 0 1-.708 0L11 9.207l-.646.647a.5.5 0 0 1-.708 0L9 9.207l-.646.647A.5.5 0 0 1 8 10h-.535A4 4 0 0 1 0 8m4-3a3 3 0 1 0 2.712 4.285A.5.5 0 0 1 7.163 9h.63l.853-.854a.5.5 0 0 1 .708 0l.646.647.646-.647a.5.5 0 0 1 .708 0l.646.647.646-.647a.5.5 0 0 1 .708 0l.646.647.793-.793-1-1h-6.63a.5.5 0 0 1-.451-.285A3 3 0 0 0 4 5" />
    <path d="M4 8a1 1 0 1 1-2 0 1 1 0 0 1 2 0" />
    """
  end

  defp action_icon_paths(%{icon: :download} = assigns) do
    ~H"""
    <path d="M.5 9.9a.5.5 0 0 1 .5.5v2.5a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-2.5a.5.5 0 0 1 1 0v2.5a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2v-2.5a.5.5 0 0 1 .5-.5" />
    <path d="M7.646 11.854a.5.5 0 0 0 .708 0l3-3a.5.5 0 0 0-.708-.708L8.5 10.293V1.5a.5.5 0 0 0-1 0v8.793L5.354 8.146a.5.5 0 1 0-.708.708z" />
    """
  end

  defp action_icon_paths(%{icon: :detail} = assigns) do
    ~H"""
    <path d="M16 8s-3-5.5-8-5.5S0 8 0 8s3 5.5 8 5.5S16 8 16 8M1.173 8a13 13 0 0 1 1.66-2.043C4.12 4.668 5.88 3.5 8 3.5s3.879 1.168 5.168 2.457A13 13 0 0 1 14.828 8q-.086.13-.195.288c-.335.48-.83 1.12-1.465 1.755C11.879 11.332 10.119 12.5 8 12.5s-3.879-1.168-5.168-2.457A13 13 0 0 1 1.172 8z" />
    <path d="M8 5.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5M4.5 8a3.5 3.5 0 1 1 7 0 3.5 3.5 0 0 1-7 0" />
    """
  end

  defp action_icon_variant_class(:primary), do: "text-primary"
  defp action_icon_variant_class(:secondary), do: "text-secondary"
  defp action_icon_variant_class(:danger), do: "text-danger"
  defp action_icon_variant_class(:warning), do: "text-warning"
  defp action_icon_variant_class(:success), do: "text-success"

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(Prodigy.Portal.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(Prodigy.Portal.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
