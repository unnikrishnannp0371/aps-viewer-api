#!/bin/bash
set -e

echo "=== APS Viewer API — Starting ==="

if [ -f tmp/pids/server.pid ]; then
  rm -f tmp/pids/server.pid
fi

echo "Running database migrations..."
bundle exec rails db:migrate

echo "Starting server..."
exec "$@"