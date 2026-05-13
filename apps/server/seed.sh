#!/bin/bash
set -e

# Dev-only: clones ProdigyReloaded/objects, imports them, creates a default user.
# Migrations are NOT done here - they're in the base compose stack via db-migrate.
# Sentinel-gated so re-running is a no-op; delete /init_state/init_complete to re-seed.

SENTINEL="/init_state/init_complete"
OBJECTS_DIR="/objects"

if [ -f "$SENTINEL" ]; then
    echo "Seed already completed (sentinel present). Skipping."
    exit 0
fi

if [ ! -d "$OBJECTS_DIR/.git" ]; then
    echo "Cloning objects repository..."
    git clone https://github.com/ProdigyReloaded/objects.git "$OBJECTS_DIR"
fi

echo "Importing objects..."
podbutil import "/objects/*"

if [ -n "$INIT_USER" ] && [ -n "$INIT_PASS" ]; then
    echo "Creating default user $INIT_USER..."
    pomsutil create "$INIT_USER" "$INIT_PASS"
else
    echo "INIT_USER/INIT_PASS not set - skipping default user creation."
fi

# Always create the demo account the /start page advertises. Concurrency
# limit 0 = unlimited, so every visitor to /start can sign in as DEMO99A
# simultaneously without tripping the single-session default.
# pomsutil create exits non-zero if the household already exists, which is
# fine on re-runs - the outer sentinel usually prevents that, but we don't
# want the seed to fail if someone pre-created DEMO99.
echo "Creating demo account DEMO99A (unlimited concurrency, pre-enrolled)..."
pomsutil create DEMO99 SECRET --concurrency-limit 0 --enroll "Demo Subscriber" \
  || echo "DEMO99 already exists - continuing."

mkdir -p /init_state
touch "$SENTINEL"
echo "Seed completed."
