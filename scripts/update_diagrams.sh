#!/bin/bash

set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/lib:/usr/local/lib:$DYLD_FALLBACK_LIBRARY_PATH"

echo "Generating architecture diagrams..."


APPS=("pilgrims" "vehicles" "accommodations" "accounts" "dashboard" "homecoming" "meals" "pricing" "reports")



for app in "${APPS[@]}"
do
    echo "/t- Updating diagram for: $app..."
    .venv/bin/python manage.py graph_models $app -g -o docs/schema_${app}.png
done

echo "All diagrams updated successfully!"