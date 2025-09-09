#!/bin/bash
set -e

INIT_COMPLETE_FILE="/init_state/init_complete"
OBJECTS_DIR="/objects"

echo "Starting Prodigy initialization..."

# Check if initialization has already been completed
if [ -f "$INIT_COMPLETE_FILE" ]; then
    echo "Initialization already completed, skipping..."
    exit 0
fi

# Step 1: Run database migrations
echo "Running database migrations..."
/prod/rel/server/bin/server eval "Prodigy.Core.Release.migrate()"

# Step 2: Clone objects repository if not already present
if [ ! -d "$OBJECTS_DIR/.git" ]; then
    echo "Cloning objects repository..."
    git clone https://github.com/ProdigyReloaded/objects.git "$OBJECTS_DIR"
else
    echo "Objects repository already exists, pulling latest changes..."
    cd "$OBJECTS_DIR"
    git pull origin main || git pull origin master  # Handle different default branch names
fi

# Step 3: Import objects
echo "Importing objects..."
podbutil import "/objects/*"

# Step 4: Create user account
echo "Creating user account AAAA11..."
pomsutil create AAAA11 SECRET

# Mark initialization as complete
mkdir -p /init_state
touch "$INIT_COMPLETE_FILE"

echo "Prodigy initialization completed successfully!"