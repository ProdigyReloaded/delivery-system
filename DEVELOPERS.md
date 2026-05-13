# Developer setup

Three supported ways to run the delivery-system locally. Pick whichever
matches how you like to work; all three reach the same place
functionally (a Phoenix portal serving on http://localhost or
http://localhost:4000, talking to a Postgres that has the seeded
objects + AAAA11A + DEMO99A).

For the higher-level "what is this," see the project README.

| Method | App runtime | Postgres | URL |
|--------|-------------|----------|-----|
| **a**  | host `mix phx.server` | host install on `:5432` | http://localhost:4000 |
| **b**  | host `mix phx.server` | docker on `:5433`       | http://localhost:4000 |
| **c**  | docker (Phoenix release)  | docker (internal DNS) | http://localhost (via Caddy on `:80`) |

Method **a** is the lightest - no docker. Best if you've already got
a Postgres running on your machine and you want fast edit-compile-reload.

Method **b** is "I don't want to manage Postgres on the host." Mix
gets you the same fast feedback loop as a, but the database is in a
docker volume that's reset by `docker compose down -v` if it gets
into a weird state.

Method **c** is the production-shape dev. Everything in containers,
prod release artifacts, Caddy in front. Slower edit cycle (each code
change needs a `docker compose up -d --build`) but exercises the
same code path as the production deployments. Use it before pushing changes
that touch compose, Caddy, the release config, or the sidecar.

## Common prerequisites

- macOS or Linux. (Windows-via-WSL probably works; untested.)
- `git`
- `asdf` with `.tool-versions` honored (Erlang/OTP 27 + Elixir 1.17.x at
  the time of writing). From a fresh checkout: `asdf install`.
- Method b/c also need: any modern Docker engine (Docker Desktop,
  OrbStack, colima, native dockerd, etc.) with `docker compose`
  available.
- Method a also needs: a running Postgres 15+ (installed however you
  prefer - package manager, asdf-postgres, official installer) and
  the `psql` CLI.

## .env

For methods b and c, copy the example env file and edit if you want to
override anything:

```
cp .env.example .env
```

The example values (`PHX_HOST=localhost`, `PHX_DEV_ROUTES=true`, the
placeholder `SECRET_KEY_BASE`, etc.) are fine for local dev. Method a
doesn't read this file - `config/dev.exs` reads `DB_*` env vars
directly with `prodigydev/*` defaults.

---

## Method a: everything local

### One-time setup

1. Make sure your local Postgres is running and reachable:
   ```
   pg_isready -h localhost -p 5432
   ```
   (How you start Postgres depends on how you installed it - `brew
   services start postgresql@<n>`, `systemctl start postgresql`,
   `pg_ctl start`, etc.)

2. Create the dev role + database. (Adjust `prodigydev`/`prodigytest`
   if you need different names; you'll then have to set the matching
   `DB_*` env vars when running mix.)
   ```
   psql -d postgres <<'EOF'
   CREATE ROLE prodigydev WITH LOGIN PASSWORD 'prodigydev' CREATEDB;
   CREATE DATABASE prodigydev OWNER prodigydev;
   CREATE ROLE prodigytest WITH LOGIN PASSWORD 'prodigytest' CREATEDB;
   CREATE DATABASE prodigytest OWNER prodigytest;
   EOF
   ```

3. Fetch deps and migrate:
   ```
   cd delivery-system
   mix deps.get
   mix ecto.migrate
   ```

4. Seed the database (clones ProdigyReloaded/objects to
   `~/.cache/prodigy/objects` on first run, imports them, creates
   AAAA11A + DEMO99A):
   ```
   mix prodigy.seed
   ```

   Re-running is safe (idempotent on objects via content-hash, and
   user creation reports "already exists" cleanly).

### Daily

```
mix phx.server                    # http://localhost:4000
```

To exit: Ctrl-C twice.

### Method a notes

- Default config in `config/dev.exs` connects as
  `prodigydev/prodigydev/prodigydev` to `localhost:5432`. To override
  any of those, set `DB_NAME` / `DB_USER` / `DB_PASS` / `DB_HOST` /
  `DB_PORT` in the shell before running mix.
- Tests run against `prodigytest` (`config/test.exs`).
- The dowjones quote sidecar is **not** running in this mode. Stock
  quote calls will fail until you bring up the sidecar separately
  (`docker compose up -d dowjones-sidecar` and expose its port + set
  `DOWJONES_API_URL`) or skip that feature.

---

## Method b: mix on host, postgres in docker

### One-time setup

1. Copy `.env.example` to `.env`.
2. Bring up just the docker postgres:
   ```
   cd delivery-system
   docker compose up -d db
   ```
   The dev override maps it to host `:5433` to avoid colliding with
   a host-side Postgres on the default `:5432`.
3. Fetch deps and run migrations against the dockered db:
   ```
   mix deps.get
   DB_NAME=prodigy DB_USER=prodigy DB_PASS=prodigy DB_PORT=5433 mix ecto.migrate
   ```
4. Seed:
   ```
   DB_NAME=prodigy DB_USER=prodigy DB_PASS=prodigy DB_PORT=5433 mix prodigy.seed
   ```

### Daily

```
docker compose up -d db
DB_NAME=prodigy DB_USER=prodigy DB_PASS=prodigy DB_PORT=5433 mix phx.server
```

### Method b notes

- The five `DB_*` env vars get tedious. A `direnv` `.envrc` or a shell
  alias is reasonable:
  ```
  alias prodigy-mix='env DB_NAME=prodigy DB_USER=prodigy DB_PASS=prodigy DB_PORT=5433 mix'
  prodigy-mix phx.server
  ```
  (Don't commit a personal alias; it's a developer convenience.)
- The dockered db data lives in volume `prodigy_db_data`. To reset:
  `docker compose down -v db` (removes the volume).
- Same dowjones-sidecar caveat as method a.

---

## Method c: full compose

### One-time setup

1. Copy `.env.example` to `.env`.
2. Build + bring everything up:
   ```
   cd delivery-system
   docker compose up -d --build
   ```
   First build is ~5 min (Phoenix release + Python sidecar). Subsequent
   rebuilds are layer-cached.

3. Watch the seed complete:
   ```
   docker compose logs -f db-seed
   ```
   You'll see the objects clone, import, and AAAA11A/DEMO99A creation.
   Compose's `db-seed` runs `apps/server/seed.sh` which is the
   container-side equivalent of `mix prodigy.seed`.

### Daily

```
docker compose up -d --build      # rebuild after code changes
docker compose down                # stop, keep volumes
docker compose down -v             # stop, wipe volumes (forces re-seed next up)
docker compose logs -f server      # tail Phoenix logs
docker compose logs -f caddy       # tail Caddy access logs
```

Browser to:
- `http://localhost`         - portal homepage (via Caddy)
- `http://localhost/dev/mailbox`    - Swoosh inbox (auth emails land here)
- `http://localhost/dev/mock-login`  - bypass-login for OAuth flow

### Method c notes

- Caddy listens on `:80` plain HTTP. No TLS at this layer; in production,
  Cloudflare's Tunnel terminates TLS at the edge and forwards plain
  HTTP to Caddy. Locally, no Tunnel - http only.
- The sidecar is reachable internally as `http://dowjones-sidecar:8000`.
  Quote calls in this mode work end-to-end.
- TCS port `25234` is published on the host so vintage Prodigy clients
  (DOSBox bundle in `private/start/`) can connect.
- Volume `prodigy_dowjones_cache` holds the upstream cookie cache.
  Cold cache means the first few quote calls are slow; the upstream
  rate-limits aggressively, so plan for a warm-up window on a fresh
  volume.

---

## Common operations

### Promote a user to admin

After someone signs up via the portal (invitation-only flow), promote
them to `platform-admin` so they can reach `/admin/...` pages. The
first portal admin is bootstrap-path: pass `nil` as the actor id.

From an iex session attached to the running app:

**Method a / b** (host mix):
```
iex -S mix
iex> Prodigy.Portal.Authz.grant_role_by_email(nil, "user@example.com", "platform-admin")
```

**Method c** (compose, prod release):
```
docker exec prodigy-server-1 /prod/rel/server/bin/server rpc \
  'Prodigy.Portal.Authz.grant_role_by_email(nil, "user@example.com", "platform-admin")'
```

Available role names: `viewer`, `content-operator`, `support-operator`,
`platform-admin`. The same `Authz.grant_role_by_email/3` works for any
of them.

To revoke: `Prodigy.Portal.Authz.revoke_role_by_email/3` with the same
arguments.

### Importing objects

Object import always converges on `Prodigy.Core.Objects.Store.insert_or_bump/2`,
which does content-hash dedup, version bumping, and keyword index
maintenance. There are three front doors:

| Front door | DB access required | When to use |
|---|---|---|
| `mix prodigy.seed [--objects PATH]` | yes (dev DB) | Default for any local dev environment - this is what `mix prodigy.seed` runs internally for the seed step. |
| `podbutil import --url URL <path>` | no | Importing to a remote instance you don't have DB access to. Posts a tar.gz of the inputs to `/api/v1/objects/upload`. |
| Admin portal upload (browser) | n/a | One-off uploads through the admin UI; same endpoint as `--url`. |

#### Keyword collision policy

If a new object claims a keyword that another object already owns,
the three paths take different actions:

| Front door | Policy | Behaviour |
|---|---|---|
| `mix prodigy.seed` / local `podbutil import` | `:skip` | Object lands without the keyword binding. The summary line reports `N keyword claim(s) skipped`. |
| `podbutil import --url ...` and admin portal upload | `:error` | The entire batch rolls back. The error surfaces which keyword collided and who owns it. |

Bulk imports (the local path) get `:skip` so a 500-object batch
doesn't drown the operator in unactionable warnings. The HTTP paths
get `:error` so an interactive operator can see each collision and
choose how to resolve it.

#### Authenticating `podbutil --url`

The HTTP mode needs an API key for a user with the `objects.upload`
scope. Three ways to supply it, in priority order:

```
# Explicit file (newline-trimmed):
podbutil import --url URL --api-key-file ~/.config/prodigy/api-key <path>

# Custom env var:
podbutil import --url URL --api-key-env MY_KEY_VAR <path>

# Default env var (PRODIGY_API_KEY):
PRODIGY_API_KEY=pk_... podbutil import --url URL <path>
```

Issue API keys from the admin portal at `/users/settings` (per-user)
or `/admin/portal/users` (administered for another user).

#### Build the `podbutil` binary for use outside mix

The compose `db-seed` container has `podbutil` on `PATH` because the
prod release builds the escript. To use the same `podbutil` binary
from your dev shell:

```
cd apps/podbutil
mix escript.build
./podbutil import --help
```

Or invoke without building:

```
mix run --no-start -e 'Prodigy.OdbUtil.CLI.main(["import", "--help"])'
```

### Run tests

```
# Method a (host postgres, prodigytest db):
mix test

# Method b (dockered db on :5433):
DB_NAME=prodigytest DB_USER=prodigytest DB_PASS=prodigytest DB_PORT=5433 mix test

# Method c: tests don't run inside compose. Drop to method a or b for the test loop.
```

### Re-seed without losing the schema

The seed task is idempotent - running `mix prodigy.seed` (or
`docker compose run --rm db-seed`) a second time is a no-op on users
and re-imports objects via content-hash dedup.

To force a complete reset (drops the database), use `mix ecto.reset`
or, for compose, `docker compose down -v db` followed by `up -d`.

### Switching between methods

Methods a and b both run mix on the host but talk to different
databases. Switching is just a matter of env vars (`DB_HOST` /
`DB_PORT`). Method c uses an entirely separate database (in the
`prodigy_db_data` docker volume); switching from c to a/b doesn't
carry data over, so you'll re-seed in the new mode.

---

## Troubleshooting

**Postgres start command reports success but `psql` won't connect.**
Common cause is a stale `postmaster.pid` from an unclean shutdown.
Confirm the process the lock file references is actually gone (`ps -p
<pid>`), then remove the lock file from your Postgres data directory
and restart the server. The data dir lives wherever your install
placed it - some defaults: `/opt/homebrew/var/postgresql@<n>/`,
`/var/lib/postgresql/<n>/main/`, `~/.asdf/installs/postgres/<n>/data/`.
The Postgres log (also in or next to the data dir) will name the
specific file.

**`mix prodigy.seed` exits with `:eaddrinuse 25234`.** You're on a
build that pre-dates the `@requirements ["compile"]` fix on the seed
task. Stop your `mix phx.server` first, run the seed, then restart
phx. (On current main this shouldn't happen.)

**Method b mix is silently hitting the host Postgres on `:5432`
instead of the dockered one on `:5433`.** Make sure you're setting
`DB_PORT=5433` *and* the matching `DB_NAME` / `DB_USER` / `DB_PASS`
(the dockered db uses `prodigy/prodigy/prodigy` per `.env`; mix's
default is `prodigydev/prodigydev/prodigydev`).

**Caddy serves an HTTPS warning page in method c.** The dev
`Caddyfile` should open with `:80 {` (plain HTTP). If you see an
HTTPS warning, you're on a stale checkout where it was `{$DOMAIN} {`,
which makes Caddy auto-TLS for localhost via its internal CA.

**Signup-confirmation email links go to `https://localhost/...` and
404.** Current code reads `URL_SCHEME` / `URL_PORT` env vars (defaults
https/443 for prod); the dev override sets http/80 for method c.
Method b reads its URL config from `config/dev.exs` which is
`http://localhost:4000`. If you see https links from a method-c run,
check that no leftover env var (likely `URL_SCHEME=https`) is
overriding the override.
