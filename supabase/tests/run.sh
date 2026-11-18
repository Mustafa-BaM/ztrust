#!/usr/bin/env bash
# Spins up a throwaway PostgreSQL 16, applies all migrations on a Supabase stand-in, runs the flow tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DATA="$(mktemp -d)"; PORT="${PORT:-$((55000 + RANDOM % 900))}"
chown -R postgres "$DATA" 2>/dev/null || true
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }
as_pg "$PGBIN/initdb -D $DATA -A trust -U postgres >/dev/null"
as_pg "$PGBIN/pg_ctl -D $DATA -o '-p $PORT -k /tmp' -l $DATA/log -w start >/dev/null"
trap 'as_pg "$PGBIN/pg_ctl -D $DATA -m immediate stop >/dev/null"; rm -rf "$DATA"' EXIT
PSQL="psql -h /tmp -p $PORT -U postgres -d postgres -v ON_ERROR_STOP=1 -q"
$PSQL -f "$ROOT/supabase/tests/bootstrap.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do echo "apply $(basename "$f")"; $PSQL -f "$f"; done
for t in "$ROOT"/supabase/tests/*_flow.sql; do $PSQL -f "$t"; done
