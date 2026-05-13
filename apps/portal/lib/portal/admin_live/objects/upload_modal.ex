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

defmodule Prodigy.Portal.AdminLive.Objects.UploadModal do
  @moduledoc """
  Modal owning the admin "Upload objects" flow. The parent
  `AdminLive.Objects` renders this LiveComponent when it sees
  `@modal == :upload`; the LC owns the `:objects` upload,
  consumes the entries on submit, calls
  `Prodigy.Portal.Admin.Objects.insert_many/1`, and notifies the
  parent with `{:upload_saved, summary}` on success.

  Parse / persist errors are surfaced as `{:modal_flash, :error, msg}`
  messages back to the parent so they appear in the list view's flash
  region rather than inside the modal (the modal closes on success; on
  error it stays open so the admin can retry).
  """
  use Prodigy.Portal, :live_component

  alias Prodigy.Portal.Admin.Keywords
  alias Prodigy.Portal.Admin.Objects, as: Admin

  @max_upload_entries 200
  @max_upload_bytes 2_000_000

  @impl true
  def mount(socket) do
    {:ok,
     allow_upload(socket, :objects,
       accept: :any,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_bytes
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :objects, ref)}
  end

  def handle_event("save", _params, socket) do
    results =
      consume_uploaded_entries(socket, :objects, fn %{path: path}, entry ->
        case File.read(path) do
          {:ok, blob} ->
            case Admin.parse_import_blob(blob) do
              {:ok, parsed} -> {:ok, {:ok, {entry.client_name, parsed}}}
              {:error, reason} -> {:ok, {:error, {entry.client_name, reason}}}
            end

          {:error, reason} ->
            {:ok, {:error, {entry.client_name, reason}}}
        end
      end)

    {parsed, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    cond do
      errors != [] ->
        send(self(), {:modal_flash, :error, "Couldn't import: " <> format_parse_errors(errors)})
        {:noreply, socket}

      parsed == [] ->
        {:noreply, socket}

      true ->
        parsed_attrs = Enum.map(parsed, fn {:ok, {_name, attrs}} -> attrs end)

        case Admin.insert_many(parsed_attrs) do
          {:ok, %{inserted: ins, bumped: bump, unchanged: un}} ->
            if bump != [] or ins != [] do
              # New/bumped objects may reshuffle the keyword index;
              # best-effort rebuild, matching the delete path.
              Keywords.rebuild_index()
            end

            send(self(), {:upload_saved, format_summary(ins, bump, un)})
            {:noreply, socket}

          {:error, {:keyword_collision, kw, owner, new_id}} ->
            send(
              self(),
              {:modal_flash, :error,
               "Keyword collision: \"#{kw}\" already belongs to #{owner}; " <>
                 "#{new_id} wanted it too. No objects were inserted."}
            )

            {:noreply, socket}

          {:error, {:object_insert_failed, name, _errors}} ->
            send(
              self(),
              {:modal_flash, :error,
               "Couldn't insert #{String.trim(name)}. No objects were inserted."}
            )

            {:noreply, socket}

          {:error, reason} ->
            send(self(), {:modal_flash, :error, "Couldn't import: #{inspect(reason)}"})
            {:noreply, socket}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id={@id <> "-modal"}
        show
        title="Upload objects"
        size="lg"
        on_cancel={JS.push("close_modal")}
      >
        <form
          id={@id <> "-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
        >
          <div
            class="border border-2 border-dashed rounded p-4 text-center"
            phx-drop-target={@uploads.objects.ref}
          >
            <.live_file_input upload={@uploads.objects} class="form-control mb-2" />
            <p class="text-muted small mb-0">
              Drop object files here or use the picker above. Max {@uploads.objects.max_entries}
              files, {format_size(@uploads.objects.max_file_size)} each.
            </p>
          </div>

          <div :if={@uploads.objects.entries != []} class="mt-3">
            <div
              :for={entry <- @uploads.objects.entries}
              class="d-flex justify-content-between align-items-center border-bottom py-1"
            >
              <div class="me-2" style="min-width: 0;">
                <div class="font-monospace small text-truncate">{entry.client_name}</div>
                <div class="text-muted small">{format_size(entry.client_size)}</div>
                <div :for={err <- upload_errors(@uploads.objects, entry)} class="text-danger small">
                  {format_upload_error(err)}
                </div>
              </div>
              <button
                type="button"
                class="btn btn-sm btn-link text-muted p-0"
                phx-click="cancel_entry"
                phx-target={@myself}
                phx-value-ref={entry.ref}
                title="Remove"
                aria-label={"Remove #{entry.client_name}"}
              >
                ×
              </button>
            </div>
          </div>

          <div :for={err <- upload_errors(@uploads.objects)} class="mt-2 text-danger small">
            {format_upload_error(err)}
          </div>
        </form>
        <:footer>
          <button type="button" class="btn btn-secondary" phx-click="close_modal">
            Cancel
          </button>
          <button
            type="submit"
            form={@id <> "-form"}
            class="btn btn-primary"
            disabled={@uploads.objects.entries == [] or has_errors?(@uploads.objects)}
          >
            Upload {length(@uploads.objects.entries)}
          </button>
        </:footer>
      </.modal>
    </div>
    """
  end

  # -- summary + error helpers -----------------------------------------

  # Build the three-category upload flash:
  #   "3 new, 2 bumped (PAGE1A v3->4, ...), 1 unchanged"
  # Each category is elided when empty; all-unchanged surfaces its
  # own message so the admin sees that nothing landed.
  defp format_summary([], [], unchanged) do
    "No changes - #{length(unchanged)} file(s) matched existing content."
  end

  defp format_summary(inserted, bumped, unchanged) do
    parts = [
      inserted != [] && "#{length(inserted)} new",
      bumped != [] && "#{length(bumped)} bumped#{format_bump_list(bumped)}",
      unchanged != [] && "#{length(unchanged)} unchanged"
    ]

    Enum.filter(parts, & &1) |> Enum.join(", ")
  end

  defp format_bump_list(bumped) do
    preview =
      bumped
      |> Enum.take(3)
      |> Enum.map(&"#{String.trim(&1.name)} v#{&1.previous_version}->#{&1.version}")
      |> Enum.join(", ")

    suffix = if length(bumped) > 3, do: " + #{length(bumped) - 3} more", else: ""
    " (" <> preview <> suffix <> ")"
  end

  defp format_parse_errors(errors) do
    errors
    |> Enum.take(3)
    |> Enum.map(fn {:error, {name, reason}} -> "#{name} (#{reason})" end)
    |> Enum.join(", ")
    |> Kernel.<>(if length(errors) > 3, do: " + #{length(errors) - 3} more", else: "")
  end

  defp has_errors?(upload) do
    Enum.any?(upload.entries, fn entry ->
      upload_errors(upload, entry) != []
    end) or upload_errors(upload) != []
  end

  defp format_upload_error(:too_large), do: "file exceeds max size"
  defp format_upload_error(:too_many_files), do: "too many files queued"
  defp format_upload_error(:not_accepted), do: "file type not accepted"
  defp format_upload_error(other), do: to_string(other)

  defp format_size(n) when is_integer(n) and n < 1024, do: "#{n} B"
  defp format_size(n) when is_integer(n) and n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_size(n) when is_integer(n), do: "#{Float.round(n / (1024 * 1024), 2)} MB"
  defp format_size(_), do: ""
end
