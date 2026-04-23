#!/bin/bash
set -euo pipefail

# CONFIGURATION: Load from environment variables

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.local"

# Try to load environment file
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-savvy}"
DB_USER="${DB_USER:-savvy_app}"
DB_PASSWORD="${DB_PASSWORD:-changeme}"
DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-postgres}"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_COMPRESS="${BACKUP_COMPRESS:-true}"
BACKUP_PARALLEL_JOBS="${BACKUP_PARALLEL_JOBS:-4}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"

# UTILITIES

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
  echo "[ERROR] $1" | tee -a "$LOG_FILE"
  exit 1
}

create_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
}

# POSTGRESQL: BACKUP PROCEDURES

backup_postgres_full() {
  local backup_file="${BACKUP_DIR}/postgres_full_${TIMESTAMP}.sql"
  
  log "Starting PostgreSQL full backup (plain SQL)..."
  
  docker exec savvy-postgres pg_dump \
    -U "$DB_ADMIN_USER" \
    -d "$DB_NAME" \
    --verbose \
    --format plain \
    > "$backup_file" 2>> "$LOG_FILE" || error "PostgreSQL backup failed"
  
  if [ "$BACKUP_COMPRESS" = "true" ]; then
    gzip "$backup_file"
    backup_file="${backup_file}.gz"
    log "Compressed backup: $backup_file"
  fi
  
  log "PostgreSQL full backup completed: $backup_file ($(du -h "$backup_file" | cut -f1))"
  echo "$backup_file"
}

backup_postgres_custom() {
  local backup_file="${BACKUP_DIR}/postgres_custom_${TIMESTAMP}.dump"
  
  log "Starting PostgreSQL custom format backup (faster, compressed)..."
  
  docker exec savvy-postgres pg_dump \
    -U "$DB_ADMIN_USER" \
    -d "$DB_NAME" \
    --format custom \
    --file "/tmp/backup.dump" \
    --verbose \
    --jobs "$BACKUP_PARALLEL_JOBS" \
    2>> "$LOG_FILE" || error "PostgreSQL backup failed"
  
  # Copy from container to host
  docker cp savvy-postgres:/tmp/backup.dump "$backup_file"
  docker exec savvy-postgres rm /tmp/backup.dump
  
  log "PostgreSQL custom backup completed: $backup_file ($(du -h "$backup_file" | cut -f1))"
  echo "$backup_file"
}

backup_postgres_directory() {
  local backup_dir="${BACKUP_DIR}/postgres_dir_${TIMESTAMP}"
  mkdir -p "$backup_dir"
  
  log "Starting PostgreSQL directory format backup (parallel)..."
  
  docker exec savvy-postgres pg_dump \
    -U "$DB_ADMIN_USER" \
    -d "$DB_NAME" \
    --format directory \
    --file "/tmp/backup_dir" \
    --verbose \
    --jobs "$BACKUP_PARALLEL_JOBS" \
    2>> "$LOG_FILE" || error "PostgreSQL backup failed"
  
  # Copy from container to host
  docker cp savvy-postgres:/tmp/backup_dir/. "$backup_dir/"
  docker exec savvy-postgres rm -rf /tmp/backup_dir
  
  if [ "$BACKUP_COMPRESS" = "true" ]; then
    tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
    rm -rf "$backup_dir"
    log "PostgreSQL directory backup completed: ${backup_dir}.tar.gz ($(du -h "${backup_dir}.tar.gz" | cut -f1))"
    echo "${backup_dir}.tar.gz"
  else
    log "PostgreSQL directory backup completed: $backup_dir ($(du -sh "$backup_dir" | cut -f1))"
    echo "$backup_dir"
  fi
}

# POSTGRESQL: RESTORE PROCEDURES

restore_postgres_full() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Starting PostgreSQL restore from: $backup_file"
  log "WARNING: This will overwrite existing data. Press Ctrl+C to cancel..."
  sleep 5
  
  # Check if compressed
  if [[ "$backup_file" == *.gz ]]; then
    zcat "$backup_file" | docker exec -i savvy-postgres \
      psql -U "$DB_ADMIN_USER" -d "$DB_NAME" \
      2>> "$LOG_FILE" || error "PostgreSQL restore failed"
  else
    cat "$backup_file" | docker exec -i savvy-postgres \
      psql -U "$DB_ADMIN_USER" -d "$DB_NAME" \
      2>> "$LOG_FILE" || error "PostgreSQL restore failed"
  fi
  
  log "PostgreSQL restore completed"
}

restore_postgres_custom() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Starting PostgreSQL restore from custom format: $backup_file"
  log "WARNING: This will overwrite existing data. Press Ctrl+C to cancel..."
  sleep 5
  
  # Copy to container
  docker cp "$backup_file" savvy-postgres:/tmp/restore.dump
  
  # Restore
  docker exec savvy-postgres pg_restore \
    -U "$DB_ADMIN_USER" \
    -d "$DB_NAME" \
    --verbose \
    --clean \
    --if-exists \
    --jobs "$BACKUP_PARALLEL_JOBS" \
    /tmp/restore.dump \
    2>> "$LOG_FILE" || error "PostgreSQL restore failed"
  
  # Cleanup
  docker exec savvy-postgres rm /tmp/restore.dump
  
  log "PostgreSQL restore completed"
}

# MAINTENANCE: Retention and cleanup

cleanup_old_backups() {
  log "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
  
  find "$BACKUP_DIR" -type f -name "postgres_*" -mtime "+$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
  find "$BACKUP_DIR" -type d -name "postgres_dir_*" -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true
  
  log "Cleanup completed"
}

list_backups() {
  log "Available backups in $BACKUP_DIR:"
  if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    ls -lh "$BACKUP_DIR" | grep -E "postgres_" | awk '{print $9, "("$5")", $6, $7, $8}'
  else
    log "No backups found"
  fi
}

# VERIFICATION: Test backup integrity

verify_postgres_backup() {
  local backup_file="$1"
  
  [ -f "$backup_file" ] || error "Backup file not found: $backup_file"
  
  log "Verifying PostgreSQL backup: $backup_file"
  
  if [[ "$backup_file" == *.dump ]]; then
    docker cp "$backup_file" savvy-postgres:/tmp/verify.dump
    docker exec savvy-postgres pg_restore --list /tmp/verify.dump > /dev/null || error "Backup is corrupted"
    docker exec savvy-postgres rm /tmp/verify.dump
  elif [[ "$backup_file" == *.sql.gz ]]; then
    zcat "$backup_file" | head -n 10 > /dev/null || error "Backup is corrupted"
  elif [[ "$backup_file" == *.sql ]]; then
    head -n 10 "$backup_file" > /dev/null || error "Backup is corrupted"
  else
    error "Unknown backup format"
  fi
  
  log "PostgreSQL backup verification successful"
}

# MAIN: Command dispatcher

usage() {
  cat <<EOF
Usage: $0 <command> [options]

BACKUP COMMANDS:
  backup-postgres-full       Full SQL dump (largest, most compatible)
  backup-postgres-custom     Custom format (compressed, faster restore)
  backup-postgres-dir        Directory format (fastest, parallel)
  
RESTORE COMMANDS:
  restore-postgres <file>    Restore PostgreSQL from backup
  
MAINTENANCE:
  list-backups              Show all available backups
  cleanup                   Delete backups older than retention period
  verify-postgres <file>    Test PostgreSQL backup integrity

ENVIRONMENT VARIABLES:
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
  BACKUP_DIR (default: ./backups)
  BACKUP_RETENTION_DAYS (default: 30)
  BACKUP_COMPRESS (default: true)

EXAMPLES:
  # Create backup
  ./backup-restore.sh backup-postgres-custom
  
  # Restore from backup
  ./backup-restore.sh restore-postgres ./backups/postgres_custom_20260423_120000.dump
  
  # List and cleanup
  ./backup-restore.sh list-backups
  ./backup-restore.sh cleanup

EOF
  exit 1
}

main() {
  create_backup_dir
  
  case "${1:-}" in
    backup-postgres-full)
      backup_postgres_full
      ;;
    backup-postgres-custom)
      backup_postgres_custom
      ;;
    backup-postgres-dir)
      backup_postgres_directory
      ;;
    restore-postgres)
      restore_postgres_custom "${2:-}"
      ;;
    list-backups)
      list_backups
      ;;
    cleanup)
      cleanup_old_backups
      ;;
    verify-postgres)
      verify_postgres_backup "${2:-}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"