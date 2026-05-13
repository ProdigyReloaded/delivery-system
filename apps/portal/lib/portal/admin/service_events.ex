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

defmodule Prodigy.Portal.Admin.ServiceEvents do
  @moduledoc """
  Unified chronological feed of per-session events for the admin
  Service > Events log. Each surfaced row carries:

    * `at` - `DateTime.t()` (UTC), used as the sort key.
    * `session_id` - id of the `service.session` row (may be nil for
      future log types that aren't session-scoped).
    * `user_id` - service-user id string (e.g. `"AAAA11A"`). CMC
      payloads right-pad to 7 chars with `?`; we trim that here so
      the same user filter matches both sources.
    * `kind` - atom naming the log type. Today: `:session_logon`,
      `:session_logoff`, `:cmc_error`.
    * `summary` - one-line description for the table.
    * `source` - the DB row backing this event, attached for the
      detail modal. Callers shouldn't traverse it structurally -
      render dispatches on `kind`.

  New log types (data-collection telemetry, mail events, ...) plug
  in by adding a source function + `*_event/1` mapper here and a
  detail clause in the LiveView's `event_detail/1` component.
  """
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.CmcError
  alias Prodigy.Core.Data.Service.DataCollectionEvent
  alias Prodigy.Core.Data.Service.Session
  alias Prodigy.Core.ServiceEvents, as: Bus

  @default_limit 200

  @doc "PubSub topic every service-event writer publishes to."
  defdelegate topic, to: Bus

  @doc "Subscribe the current process to live service events."
  defdelegate subscribe, to: Bus

  @doc "Unsubscribe the current process from live service events."
  defdelegate unsubscribe, to: Bus

  @doc """
  Map a raw broadcast payload (the second element of the
  `{:service_event, payload}` message) to the common event map this
  module's LiveView consumer uses.
  """
  def from_broadcast({:logon, %Session{} = s}), do: session_logon_event(s)
  def from_broadcast({:logoff, %Session{} = s}), do: session_logoff_event(s)
  def from_broadcast({:cmc, %CmcError{} = c}), do: cmc_event(c)
  def from_broadcast({:data_collection, %DataCollectionEvent{} = d}), do: data_collection_event(d)
  def from_broadcast(_), do: nil

  @doc """
  True if `event` passes the given filter map. Filters use the same
  string keys the LiveView form posts (`"user_id"`, `"session_id"`,
  `"kind"`, `"since"`, `"until"`); unknown or empty values are
  ignored. Exposed so the LiveView can filter live events locally against
  the same rules the initial query uses.
  """
  def matches_filter?(event, filters) when is_map(filters) do
    Enum.all?(filters, fn {key, raw} ->
      case key do
        "user_id" -> user_matches?(event, raw)
        "session_id" -> session_matches?(event, raw)
        "kind" -> kind_matches?(event, raw)
        "since" -> since_matches?(event, raw)
        "until" -> until_matches?(event, raw)
        _ -> true
      end
    end)
  end

  defp user_matches?(%{user_id: uid}, filter) when is_binary(filter) do
    uid != nil and String.contains?(uid, String.trim(filter))
  end

  defp user_matches?(_, _), do: true

  defp session_matches?(%{session_id: sid}, filter) do
    case Integer.parse(to_string(filter)) do
      {n, ""} -> sid == n
      _ -> true
    end
  end

  defp kind_matches?(%{kind: k}, filter) when is_binary(filter) and filter != "" do
    Atom.to_string(k) == filter
  end

  defp kind_matches?(_, _), do: true

  defp since_matches?(%{at: at}, filter) when is_binary(filter) and filter != "" do
    case Date.from_iso8601(filter) do
      {:ok, d} ->
        {:ok, boundary} = DateTime.new(d, ~T[00:00:00], "Etc/UTC")
        DateTime.compare(at, boundary) != :lt

      _ ->
        true
    end
  end

  defp since_matches?(_, _), do: true

  defp until_matches?(%{at: at}, filter) when is_binary(filter) and filter != "" do
    case Date.from_iso8601(filter) do
      {:ok, d} ->
        {:ok, boundary} = DateTime.new(d, ~T[23:59:59], "Etc/UTC")
        DateTime.compare(at, boundary) != :gt

      _ ->
        true
    end
  end

  defp until_matches?(_, _), do: true

  @logoff_status_labels %{
    0 => "normal",
    1 => "abnormal",
    2 => "timeout",
    3 => "forced",
    4 => "node shutdown"
  }

  @kinds [
    :session_logon,
    :session_logoff,
    :cmc_error,
    :data_collection_object,
    :data_collection_function
  ]

  @doc "The full set of event-kind atoms this module can emit."
  def kinds, do: @kinds

  @doc "Human-readable label for a session logoff status code."
  def logoff_status_label(nil), do: "-"
  def logoff_status_label(code), do: Map.get(@logoff_status_labels, code, "code #{inspect(code)}")

  @doc """
  List events newest-first, applying optional filters.

  Accepted opts (all optional):

    * `:user_id`     - service-user id string (e.g. `"AAAA11A"`)
    * `:session_id`  - session row id (integer or string)
    * `:kind`        - atom or string matching one of `kinds/0`
    * `:since`       - `DateTime.t()` or ISO-8601 date string
    * `:until`       - same
    * `:limit`       - cap on returned rows (default 200)
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    filters = %{
      user_id: opt_string(opts, :user_id),
      session_id: opt_int(opts, :session_id),
      kind: opt_kind(opts, :kind),
      since: opt_datetime(opts, :since),
      until: opt_datetime(opts, :until)
    }

    (session_events(filters) ++ cmc_events(filters) ++ data_collection_events(filters))
    |> filter_by_kind(filters.kind)
    |> filter_by_date(filters.since, filters.until)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # --- sources -------------------------------------------------------

  defp session_events(filters) do
    query =
      from(s in Session)
      |> maybe_session_user_filter(filters.user_id)
      |> maybe_session_id_filter(filters.session_id)

    query
    |> Repo.all()
    |> Enum.flat_map(fn s ->
      [logon_event(s), logoff_event(s)] |> Enum.reject(&is_nil/1)
    end)
  end

  defp cmc_events(filters) do
    query =
      from(c in CmcError, order_by: [desc: c.inserted_at])
      |> maybe_cmc_user_filter(filters.user_id)
      |> maybe_cmc_session_filter(filters.session_id)

    query
    |> Repo.all()
    |> Enum.map(&cmc_event/1)
  end

  defp data_collection_events(filters) do
    query =
      from(d in DataCollectionEvent, order_by: [desc: d.inserted_at])
      |> maybe_dc_user_filter(filters.user_id)
      |> maybe_dc_session_filter(filters.session_id)

    query
    |> Repo.all()
    |> Enum.map(&data_collection_event/1)
  end

  defp logon_event(%Session{logon_timestamp: nil}), do: nil

  defp logon_event(%Session{} = s) do
    transport = s.transport || "tcs"
    source_addr = s.source_address || "unknown"

    %{
      at: to_datetime(s.logon_timestamp),
      session_id: s.id,
      user_id: s.user_id,
      kind: :session_logon,
      summary: "#{transport} logon from #{source_addr}",
      source: s
    }
  end

  defp logoff_event(%Session{logoff_timestamp: nil}), do: nil

  defp logoff_event(%Session{} = s) do
    %{
      at: to_datetime(s.logoff_timestamp),
      session_id: s.id,
      user_id: s.user_id,
      kind: :session_logoff,
      summary: "logoff (#{logoff_status_label(s.logoff_status)})",
      source: s
    }
  end

  @doc """
  Map a persisted `%CmcError{}` to the common event map. Exposed so
  `Prodigy.Server.Service.Cmc` can broadcast freshly-inserted rows
  without duplicating the shape.
  """
  def cmc_event(%CmcError{} = c) do
    %{
      at: to_datetime(c.inserted_at),
      session_id: c.session_id,
      user_id: normalize_user_id(c.user_id),
      kind: :cmc_error,
      summary:
        "CMC error " <>
          String.trim(c.error_code || "") <>
          " severity " <>
          String.trim(c.severity_level || ""),
      source: c
    }
  end

  @doc "Map a persisted `%DataCollectionEvent{}` to the common event map."
  def data_collection_event(%DataCollectionEvent{kind: "object"} = d) do
    name = String.trim(d.object_name || "")

    %{
      at: to_datetime(d.inserted_at),
      session_id: d.session_id,
      user_id: d.user_id,
      kind: :data_collection_object,
      summary: "#{name} - #{format_duration(d.duration_seconds)}",
      source: d
    }
  end

  def data_collection_event(%DataCollectionEvent{kind: "function"} = d) do
    %{
      at: to_datetime(d.inserted_at),
      session_id: d.session_id,
      user_id: d.user_id,
      kind: :data_collection_function,
      summary: "function class #{d.function_class} - #{format_duration(d.duration_seconds)}",
      source: d
    }
  end

  @doc "Build an event map for a session logon/logoff broadcast."
  def session_logon_event(%Session{} = s), do: logon_event(s)
  def session_logoff_event(%Session{} = s), do: logoff_event(s)

  @doc "Human-friendly Mm SSs duration label for the events table."
  def format_duration(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m#{String.pad_leading(Integer.to_string(secs), 2, "0")}s"
  end

  def format_duration(_), do: "-"

  # CmcError timestamps land as NaiveDateTime (default `timestamps()`
  # opts), Session timestamps land as DateTime (utc_datetime schema
  # type). Normalize to DateTime in UTC so the sort step can compare
  # them without tripping over types.
  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = nd), do: DateTime.from_naive!(nd, "Etc/UTC")
  defp to_datetime(nil), do: nil

  # --- filters (DB + in-memory) --------------------------------------

  defp filter_by_kind(events, nil), do: events
  defp filter_by_kind(events, kind), do: Enum.filter(events, &(&1.kind == kind))

  defp filter_by_date(events, nil, nil), do: events

  defp filter_by_date(events, since, until) do
    Enum.filter(events, fn e ->
      (is_nil(since) or DateTime.compare(e.at, since) != :lt) and
        (is_nil(until) or DateTime.compare(e.at, until) != :gt)
    end)
  end

  defp maybe_session_user_filter(q, nil), do: q
  defp maybe_session_user_filter(q, user_id), do: from(s in q, where: s.user_id == ^user_id)

  defp maybe_session_id_filter(q, nil), do: q
  defp maybe_session_id_filter(q, session_id), do: from(s in q, where: s.id == ^session_id)

  defp maybe_cmc_user_filter(q, nil), do: q

  defp maybe_cmc_user_filter(q, user_id) do
    padded = String.pad_trailing(user_id, 7, "?")
    from(c in q, where: c.user_id == ^user_id or c.user_id == ^padded)
  end

  defp maybe_cmc_session_filter(q, nil), do: q

  defp maybe_cmc_session_filter(q, session_id),
    do: from(c in q, where: c.session_id == ^session_id)

  defp maybe_dc_user_filter(q, nil), do: q
  defp maybe_dc_user_filter(q, user_id), do: from(d in q, where: d.user_id == ^user_id)

  defp maybe_dc_session_filter(q, nil), do: q

  defp maybe_dc_session_filter(q, session_id),
    do: from(d in q, where: d.session_id == ^session_id)

  # --- opt normalization ---------------------------------------------

  defp opt_string(opts, key) do
    case Keyword.get(opts, key) do
      s when is_binary(s) -> if String.trim(s) == "", do: nil, else: String.trim(s)
      _ -> nil
    end
  end

  defp opt_int(opts, key) do
    case Keyword.get(opts, key) do
      n when is_integer(n) ->
        n

      s when is_binary(s) ->
        case Integer.parse(String.trim(s)) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp opt_kind(opts, key) do
    case Keyword.get(opts, key) do
      a when a in @kinds -> a
      s when is_binary(s) -> string_to_kind(s)
      _ -> nil
    end
  end

  defp string_to_kind(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> Enum.find(@kinds, fn k -> Atom.to_string(k) == trimmed end)
    end
  end

  defp opt_datetime(opts, key) do
    case Keyword.get(opts, key) do
      %DateTime{} = dt ->
        dt

      s when is_binary(s) ->
        case Date.from_iso8601(String.trim(s)) do
          {:ok, d} ->
            {:ok, dt} = DateTime.new(d, ~T[00:00:00], "Etc/UTC")
            dt

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp normalize_user_id(nil), do: nil

  defp normalize_user_id(s) when is_binary(s) do
    s |> String.trim() |> String.trim_trailing("?")
  end
end
