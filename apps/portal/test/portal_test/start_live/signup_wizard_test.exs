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

defmodule Prodigy.Portal.StartLive.SignupWizardTest do
  @moduledoc """
  LiveView interaction tests for the three-step signup wizard:
  choose -> pick -> reveal, plus the validation / conflict edges.
  """
  use Prodigy.Portal.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, User}

  setup %{conn: conn} do
    user = Prodigy.Portal.AccountsFixtures.user_fixture()
    {:ok, conn: log_in_user(conn, user), portal_user: user}
  end

  describe "auth gate" do
    test "redirects anonymous visitors to the login page" do
      anon = Phoenix.ConnTest.build_conn()
      assert {:error, {:redirect, %{to: to}}} = live(anon, ~p"/signup")
      assert to =~ "/users/login"
    end
  end

  describe "choose step" do
    test "mounts on the choose step", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/signup")
      assert html =~ "Create your Prodigy account"
      assert html =~ "Pick one for me"
      assert html =~ "Let me choose"
    end

    test "random mode advances to pick with a candidate id visible", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      html = view |> element("button[phx-click='choose'][phx-value-mode='random']") |> render_click()

      # 7-char assigned id (6 + trailing A). Use regex so we don't care
      # what the generator produced.
      assert html =~ ~r/[A-Z]{4}\d{2}A/
    end

    test "custom mode advances to pick with an empty text input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      html = view |> element("button[phx-click='choose'][phx-value-mode='custom']") |> render_click()

      assert html =~ "household_id"
      assert has_element?(view, "input[name='household_id']")
    end
  end

  describe "custom pick validation" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      view |> element("button[phx-click='choose'][phx-value-mode='custom']") |> render_click()
      {:ok, view: view}
    end

    test "a well-formed id leaves the commit button enabled", %{view: view} do
      view
      |> form("form[phx-change='validate_typed']", %{"household_id" => "bxrt99"})
      |> render_change()

      # No `invalid-feedback` block rendered, and no disabled attr on the
      # submit button.
      refute has_element?(view, ".invalid-feedback")
      refute has_element?(view, "button[type='submit'][disabled]")
    end

    test "a reserved prefix surfaces an error and disables commit", %{view: view} do
      html =
        view
        |> form("form[phx-change='validate_typed']", %{"household_id" => "demo99"})
        |> render_change()

      assert html =~ "not available"
      assert has_element?(view, "button[type='submit'][disabled]")
    end

    test "a too-short id disables commit", %{view: view} do
      # 4 chars - too short for the 6-char id. validate_custom rejects.
      view
      |> form("form[phx-change='validate_typed']", %{"household_id" => "WXYZ"})
      |> render_change()

      assert has_element?(view, "button[type='submit'][disabled]")
    end
  end

  describe "commit -> reveal" do
    test "commits a random id, transitions to reveal, and writes a household row",
         %{conn: conn, portal_user: portal_user} do
      {:ok, view, _html} = live(conn, ~p"/signup")
      view |> element("button[phx-click='choose'][phx-value-mode='random']") |> render_click()

      # Grab the displayed candidate from the rendered HTML so we know
      # what household id should land in the DB.
      html_after_choose = render(view)
      [match] = Regex.run(~r/[A-Z]{4}\d{2}A/, html_after_choose) |> List.wrap()
      household_id = String.slice(match, 0, 6)

      # Random path renders a phx-click="commit" button (form lives in
      # the custom path); trigger it directly.
      html = view |> element("button[phx-click='commit']") |> render_click()
      assert html =~ "You&#39;re set. Welcome to Prodigy."
      assert html =~ match

      assert %Household{} = Repo.get(Household, household_id)
      reloaded_user = Repo.get(User, household_id <> "A")
      assert reloaded_user.portal_user_id == portal_user.id
    end

    test "custom mode surfaces a taken id via the inline error before commit",
         %{conn: conn, portal_user: portal_user} do
      # SignupIds.validate_custom checks the DB - if an id is already
      # taken, typing it into the custom field is rejected at the
      # validate step so commit never fires. Pin that contract.
      taken = "CSDF99"

      {:ok, _} =
        Prodigy.Core.Data.Service.Enroller.create_subscriber(taken, "SECRET",
          portal_user_id: portal_user.id
        )

      # The portal user now has one service account; bump the quota so
      # the wizard's at-quota gate doesn't redirect us before we can
      # exercise the custom-id validation.
      portal_user
      |> Ecto.Changeset.change(%{service_user_quota: 2})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/signup")
      view |> element("button[phx-click='choose'][phx-value-mode='custom']") |> render_click()

      html =
        view
        |> form("form[phx-change='validate_typed']", %{"household_id" => taken})
        |> render_change()

      assert html =~ "not available"
      assert has_element?(view, "button[type='submit'][disabled]")
    end
  end
end
