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

defmodule Prodigy.Portal.Router do
  use Prodigy.Portal, :router

  import Prodigy.Portal.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Prodigy.Portal.Layouts, :root}
    plug :protect_from_forgery
    plug :fetch_current_scope_for_user
  end

  # Identical to :browser except it also accepts JSON. Used by the
  # invite-issuance endpoint so the navbar's "Invite a friend" modal
  # can fetch JSON without being rejected as 406, while the same
  # route still HTML-renders for direct browser visits.
  pipeline :browser_json do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Prodigy.Portal.Layouts, :root}
    plug :protect_from_forgery
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug Prodigy.Portal.Plugs.ApiAuth
  end

  # Public marketing + DOSBox client pages. No auth required.
  scope "/", Prodigy.Portal do
    pipe_through :browser

    get "/", PageController, :home
    get "/faq", PageController, :faq
    get "/history", PageController, :history
    get "/start", PageController, :start
    get "/get-started", PageController, :get_started
    post "/signup/done", PageController, :signup_done
    get "/_health", HealthController, :index
  end

  # TCS-over-WebSocket upgrade endpoint for browser DOSBox clients. Lives
  # outside :browser (no CSRF, no session) because a WebSocket handshake
  # is its own beast. The Phoenix request hits here only for the initial
  # HTTP GET with Upgrade: websocket; after that it's pure binary frames
  # handled by Prodigy.Server.TcsWebSocket.
  scope "/", Prodigy.Portal do
    get "/tcs", TcsUpgradeController, :upgrade
  end

  # Auth routes: unified login + signup (magic-link), invitation
  # confirm/dismiss controllers.
  scope "/", Prodigy.Portal do
    pipe_through :browser

    live_session :current_user,
      on_mount: [{Prodigy.Portal.UserAuth, :mount_current_scope}] do
      live "/users/login", UserLive.Login, :new
      live "/users/login/:token", UserLive.Confirmation, :new
    end

    post "/users/login", UserSessionController, :create
    delete "/users/logout", UserSessionController, :delete

    get "/users/confirm/:token", InvitationController, :confirm
    get "/users/dismiss/:token", InvitationController, :dismiss

    # Invite-flow plain controllers. Order matters: every literal
    # path under /users/invite/ must be declared before the `:code`
    # dynamic match below, otherwise the dynamic route catches them
    # (e.g. /users/invite/new would resolve as code="new").
    get "/users/invite/required", InviteController, :required
    post "/users/invite/submit", InviteController, :submit
    get "/users/invite/:code", InviteController, :land
  end

  # Mint endpoint - content-negotiates HTML vs JSON so the navbar's
  # "Invite a friend" modal can fetch without a 406. Action enforces
  # authentication itself; lives outside the require_authenticated
  # scope so its path ordering with the `:code` dynamic above is
  # locked in.
  scope "/", Prodigy.Portal do
    pipe_through :browser_json

    get "/users/invite/new", InviteController, :new
    post "/users/invite/new", InviteController, :new
  end

  # Ueberauth OAuth callbacks. `:request` never runs; Ueberauth intercepts
  # and redirects to the provider. `:callback` receives the provider
  # response and hands off to UserAuth.log_in_user.
  scope "/auth", Prodigy.Portal do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # Authenticated-only routes: settings, password update.
  scope "/", Prodigy.Portal do
    pipe_through [:browser, :require_authenticated_user]

    post "/users/update-password", UserSessionController, :update_password

    live_session :require_authenticated_user,
      on_mount: [{Prodigy.Portal.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :general
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # Service-user signup wizard. Gated at the pipeline + on_mount
      # so unauthenticated visitors get redirected to /users/login
      # with their return-to stashed - they land back here after the
      # round-trip.
      live "/signup", StartLive.SignupWizard, :index
    end

    live_session :user_settings_api_keys,
      on_mount: [
        {Prodigy.Portal.UserAuth, :require_authenticated},
        {Prodigy.Portal.UserAuth, {:require_scope, :api_keys, :self}}
      ] do
      live "/users/settings/api-keys", UserLive.Settings.ApiKeys, :index
    end
  end

  # Admin console. `/admin` lands the operator on the first surface
  # their scopes let them see; sub-routes live under /admin/service/*
  # (and /admin/portal/* for portal-user / role / audit / settings
  # management). All admin pages share one live_session so navigation
  # across them stays inside the websocket (no cross-live_session
  # full-reload on every sidebar click). The
  # per-page scope check moves to each LiveView's own `on_mount` declaration
  # so the security guarantee stays declarative; see e.g.
  # AdminLive.Portal.Users for the pattern.
  scope "/", Prodigy.Portal do
    pipe_through [:browser, :require_authenticated_user]

    get "/admin", AdminController, :index

    live_session :admin,
      on_mount: [{Prodigy.Portal.UserAuth, :require_authenticated}] do
      live "/admin/service/online", AdminLive.Online, :index
      live "/admin/service/users", AdminLive.Users, :index
      live "/admin/service/events", AdminLive.Service.Events, :index
      live "/admin/service/objects", AdminLive.Objects, :database
      live "/admin/service/objects/deficits", AdminLive.Objects, :deficits
      live "/admin/service/keywords", AdminLive.Keywords, :index
      live "/admin/portal/users", AdminLive.Portal.Users, :index
      live "/admin/portal/roles", AdminLive.Portal.Roles, :index
      live "/admin/portal/audit", AdminLive.Portal.Audit, :index
      live "/admin/portal/settings", AdminLive.Portal.Settings, :index
    end

    # Object download - plain GET returning application/octet-stream.
    # Scope gate is in the controller itself.
    get "/admin/service/objects/:name/:sequence/:type/:version/download",
        AdminObjectController,
        :download
  end

  # Non-browser HTTP API for CLI clients (podbutil et al). Bearer-token
  # auth via Prodigy.Portal.Plugs.ApiAuth; no session cookie, no CSRF.
  # Per-action scope gates live in the controllers (via Authz.can?/3);
  # an API-key request additionally intersects the key's scopes with
  # its owner's effective scopes at verify time.
  scope "/api/v1", Prodigy.Portal.Api do
    pipe_through [:api, :api_authenticated]

    get "/ping", PingController, :index
    post "/objects/upload", ObjectsController, :upload

    get "/keywords", KeywordsController, :index
    get "/keywords/:keyword", KeywordsController, :show
    post "/keywords", KeywordsController, :create
    put "/keywords/:keyword", KeywordsController, :update
    delete "/keywords/:keyword", KeywordsController, :delete
  end

  # Dev-only routes: Swoosh mailbox preview + mock OAuth. The
  # DevOnly plug halts with 404 when :portal, :dev_routes is not
  # true - same prod release image powers both dev docker compose
  # and real prod, distinguished only by the PHX_DEV_ROUTES env.
  pipeline :dev_only do
    plug Prodigy.Portal.Plugs.DevOnly
  end

  scope "/dev", Prodigy.Portal do
    pipe_through [:browser, :dev_only]
    get "/mock-login", MockAuthController, :new
    post "/mock-login", MockAuthController, :create
  end

  scope "/dev" do
    pipe_through [:browser, :dev_only]
    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end
end
