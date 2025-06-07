#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/usr/lib/unifi/data/backup/autobackup}
META_FILE=${META_FILE:-$BACKUP_DIR/autobackup_meta.json}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-86400}

log(){ echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") [INFO] $*"; }

cleanup(){
  log "Cleanup job started"

  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.unf' -mtime +7 -print0 \
    | while IFS= read -r -d '' file; do
        rm -f "$file"
        log "Deleted expired backup: $file"
      done

  log "Pruning metadata entries"
  jq -r 'keys[]' "$META_FILE" \
    | while read -r name; do
        if [ ! -e "$BACKUP_DIR/$name" ]; then
          log "Removing metadata for missing file: $name"
          jq "del(.\"$name\")" -i "$META_FILE"
        fi
      done

  log "Cleanup job completed"
}

trap 'log "Signal received, exiting"; exit 0' SIGINT SIGTERM

while true; do
  cleanup
  sleep "$INTERVAL_SECONDS"
done
