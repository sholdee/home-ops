#!/usr/bin/env bash
# Apply Poweradmin schema migrations to the powerdns database, once each.
#
# Runs as the poweradmin-db-migrate ArgoCD sync hook before the Poweradmin
# Deployment is applied. Every *.sql file in MIGRATIONS_DIR is applied in
# filename order inside one transaction and recorded in
# poweradmin_schema_migrations; files already recorded are skipped, so the hook
# is a no-op on syncs that bring no new migration. The connection comes from the
# standard libpq PG* environment variables and must be the CNPG superuser:
# the tables are owned by postgres, so ALTER TABLE needs it.
#
# To ship a new Poweradmin release that needs a schema update, add the upstream
# sql/poweradmin-pgsql-update-to-<version>.sql as the next NNNN-poweradmin-<version>.sql
# in this directory and list it in apps/powerdns/kustomization.yaml.

set -euo pipefail
export LC_ALL=C

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/opt/poweradmin-migrations}"
TRACKING_TABLE="poweradmin_schema_migrations"
APP_ROLE="${PA_DB_APP_ROLE:?PA_DB_APP_ROLE (database role that owns the application grants) is required}"
WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-120}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

psql_run() {
  psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 "$@"
}

waited=0
until pg_isready -q; do
  if ((waited >= WAIT_TIMEOUT)); then
    log "ERROR: ${PGHOST:-localhost} did not answer within ${WAIT_TIMEOUT}s"
    exit 1
  fi
  ((waited == 0)) && log "Waiting for ${PGHOST:-localhost} to answer..."
  sleep 2
  waited=$((waited + 2))
done

psql_run -c "SET client_min_messages TO warning; CREATE TABLE IF NOT EXISTS ${TRACKING_TABLE} (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"

shopt -s nullglob
migrations=("${MIGRATIONS_DIR}"/*.sql)
if ((${#migrations[@]} == 0)); then
  log "ERROR: no *.sql migrations found in ${MIGRATIONS_DIR}"
  exit 1
fi

applied=0
for file in "${migrations[@]}"; do
  name="$(basename "${file}")"
  # psql only interpolates :'variables' in script input, not in -c strings.
  recorded="$(psql_run -tA -v name="${name}" <<<"SELECT count(*) FROM ${TRACKING_TABLE} WHERE name = :'name'")"
  if [[ "${recorded}" == "1" ]]; then
    log "skip ${name}: already applied"
    continue
  fi

  log "apply ${name}"
  # The migration, the grants for the application role, and the tracking row
  # commit together or not at all. The role is passed as a psql variable so
  # psql quotes it as an identifier.
  {
    cat "${file}"
    cat <<'SQL'

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO :"app_role";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO :"app_role";
INSERT INTO poweradmin_schema_migrations (name) VALUES (:'migration');
SQL
  } | psql_run --single-transaction -v app_role="${APP_ROLE}" -v migration="${name}" -f -
  log "done ${name}"
  applied=$((applied + 1))
done

log "${applied} migration(s) applied, $((${#migrations[@]} - applied)) already present"
psql_run -c "SELECT name, applied_at FROM ${TRACKING_TABLE} ORDER BY applied_at, name"
