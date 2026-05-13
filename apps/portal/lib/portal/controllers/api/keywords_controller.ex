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

defmodule Prodigy.Portal.Api.KeywordsController do
  @moduledoc """
  `/api/v1/keywords` CRUD. Read-side gated on `keywords.view`;
  writes gated on `keywords.manage`. Both scopes resolve through
  the `current_api_scopes` MapSet the `ApiAuth` plug sets (i.e.
  `key.scopes & owner.scopes`), so a degraded key returns 403
  instead of partially working.

  Body shape for create / update:

      {
        "keyword": "NEWS",
        "object_name": "PAGE0000   ",
        "object_sequence": 0,
        "object_type": 4
      }

  Successful create / update responses carry the persisted row.
  Errors come back as `{"error": "reason", "detail": {...}}`.
  """
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.Admin.Keywords
  alias Prodigy.Portal.Authz

  plug :gate_read when action in [:index, :show]
  plug :gate_write when action in [:create, :update, :delete]

  def index(conn, _params) do
    rows =
      Keywords.list()
      |> Enum.map(&row_to_json/1)

    json(conn, %{keywords: rows})
  end

  def show(conn, %{"keyword" => keyword}) do
    case Keywords.get(keyword) do
      nil -> json_error(conn, 404, "not_found")
      row -> json(conn, row_to_json(row))
    end
  end

  def create(conn, params) do
    attrs = Map.take(params, ~w(keyword object_name object_sequence object_type))

    case Keywords.create(attrs) do
      {:ok, row} ->
        conn |> put_status(201) |> json(row_to_json(row))

      {:error, changeset} ->
        json_error(conn, 422, "invalid", %{errors: changeset_errors(changeset)})
    end
  end

  def update(conn, %{"keyword" => old_keyword} = params) do
    attrs = Map.take(params, ~w(keyword object_name object_sequence object_type))

    case Keywords.update(old_keyword, attrs) do
      {:ok, row} -> json(conn, row_to_json(row))
      :not_found -> json_error(conn, 404, "not_found")
      {:error, changeset} -> json_error(conn, 422, "invalid", %{errors: changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"keyword" => keyword}) do
    case Keywords.delete(keyword) do
      {:ok, row} -> json(conn, row_to_json(row))
      :not_found -> json_error(conn, 404, "not_found")
      {:error, reason} -> json_error(conn, 422, "failed", %{detail: inspect(reason)})
    end
  end

  # --- plug helpers --------------------------------------------------

  defp gate_read(conn, _opts), do: gate(conn, :keywords, :view)
  defp gate_write(conn, _opts), do: gate(conn, :keywords, :manage)

  defp gate(conn, resource, action) do
    if Authz.can?(conn.assigns[:current_api_scopes], resource, action) do
      conn
    else
      conn
      |> put_status(403)
      |> put_resp_content_type("application/json")
      |> send_resp(403, Phoenix.json_library().encode_to_iodata!(%{error: "forbidden"}))
      |> halt()
    end
  end

  defp row_to_json(%Prodigy.Core.Data.Service.Keyword{} = row) do
    %{
      keyword: row.keyword,
      object_name: row.object_name,
      object_sequence: row.object_sequence,
      object_type: row.object_type,
      updated_at: row.updated_at
    }
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end

  defp json_error(conn, status, reason, extra \\ %{}) do
    body = Map.merge(%{error: reason}, extra)

    conn
    |> put_status(status)
    |> json(body)
  end
end
