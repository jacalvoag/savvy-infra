#!/bin/bash
set -euo pipefail

# CONFIGURATION

ENVIRONMENT="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.${ENVIRONMENT}"
DEFAULT_ENV="${SCRIPT_DIR}/.env.example"

LOG_FILE="${SCRIPT_DIR}/setup-${ENVIRONMENT}-$(date +%Y%m%d_%H%M%S).log"
DOCKER_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
DOCKER_COMPOSE_TIMEOUT=120

# COLORS & LOGGING

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
  echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
  echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
  exit 1
}

warn() {
  echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

# VALIDATION

validate_environment() {
  log "Validating setup for environment: $ENVIRONMENT"
  
  # Check environment file
  if [ ! -f "$ENV_FILE" ] && [ "$ENVIRONMENT" != "local" ]; then
    warn "Environment file not found: $ENV_FILE"
    log "Creating from template..."
    cp "$DEFAULT_ENV" "$ENV_FILE"
    error "Please edit $ENV_FILE with correct values and run again"
  fi
  
  if [ "$ENVIRONMENT" = "local" ] && [ ! -f "$ENV_FILE" ]; then
    log "Creating .env.local from example..."
    cp "$DEFAULT_ENV" "$ENV_FILE"
    success "Created $ENV_FILE - using default development credentials"
  fi
  
  # Check required files
  [ -f "$DOCKER_COMPOSE_FILE" ] || error "Docker Compose file not found: $DOCKER_COMPOSE_FILE"
  [ -f "${SCRIPT_DIR}/init-postgres.sql" ] || warn "init-postgres.sql not found (will be created on first run)"
  [ -f "${SCRIPT_DIR}/init-roles.sh" ] || error "init-roles.sh not found"
  
  # Check Docker
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Install from: https://docs.docker.com/get-docker/"
  fi
  
  if ! docker compose version &> /dev/null; then
    error "Docker Compose is not installed or not available"
  fi
  
  # Make init scripts executable
  chmod +x "${SCRIPT_DIR}/init-roles.sh" 2>/dev/null || true
  
  success "All validations passed"
}

# SECURITY WARNINGS

check_production_security() {
  if [ "$ENVIRONMENT" = "production" ]; then
    warn "  PRODUCTION ENVIRONMENT DETECTED"
    
    # Load env vars to check passwords
    set -a
    source "$ENV_FILE"
    set +a
    
    # Check for default passwords
    if [ "${DB_PASSWORD:-changeme}" = "changeme" ] || \
       [ "${DB_ADMIN_PASSWORD:-postgres_admin_changeme}" = "postgres_admin_changeme" ]; then
      error "SECURITY ERROR: Default passwords detected in production environment. Change them in $ENV_FILE"
    fi
    
    # Check password strength (basic)
    if [ ${#DB_PASSWORD} -lt 16 ]; then
      error "SECURITY ERROR: DB_PASSWORD must be at least 16 characters in production"
    fi
    
    success "Production security checks passed"
    
    warn "Make sure to:"
    warn "  1. Restrict PostgreSQL port (5432) to localhost only"
    warn "  2. Enable SSL/TLS for database connections"
    warn "  3. Set up automated backups"
    warn "  4. Configure firewall rules"
    echo ""
    read -p "Continue with production setup? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
      error "Production setup cancelled by user"
    fi
  fi
}

# DOCKER SETUP

start_docker_services() {
  log "Starting Docker services for $ENVIRONMENT environment..."
  
  cd "$SCRIPT_DIR"
  
  # Stop existing services (graceful)
  if docker compose -f "$DOCKER_COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then
    warn "Existing services found. Stopping them..."
    docker compose --env-file "$ENV_FILE" -f "$DOCKER_COMPOSE_FILE" down --timeout=30 2>&1 | tee -a "$LOG_FILE"
  fi
  
  # Start services
  log "Bringing up PostgreSQL..."
  docker compose --env-file "$ENV_FILE" \
                 -f "$DOCKER_COMPOSE_FILE" \
                 up -d \
                 2>&1 | tee -a "$LOG_FILE"
  
  success "Docker services started"
}

wait_for_postgres() {
  log "Waiting for PostgreSQL to be ready..."
  
  # Load DB_ADMIN_USER from env
  set -a
  source "$ENV_FILE"
  set +a
  
  local max_retries=30
  local retry=0
  
  while [ $retry -lt $max_retries ]; do
    if docker exec savvy-postgres pg_isready -U "${DB_ADMIN_USER:-postgres}" > /dev/null 2>&1; then
      success "PostgreSQL is ready"
      return 0
    fi
    
    retry=$((retry + 1))
    echo "  Attempt $retry/$max_retries..." | tee -a "$LOG_FILE"
    sleep 2
  done
  
  error "PostgreSQL failed to start after ${max_retries} attempts"
}

# VERIFICATION

verify_postgres() {
  log "Verifying PostgreSQL installation..."
  
  set -a
  source "$ENV_FILE"
  set +a
  
  # Check if database exists
  local db_exists=$(docker exec savvy-postgres \
    psql -U "${DB_ADMIN_USER:-postgres}" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME:-savvy}';" 2>/dev/null || echo "0")
  
  if [ "$db_exists" != "1" ]; then
    error "Database ${DB_NAME:-savvy} was not created"
  fi
  
  # Check if app user exists
  local user_exists=$(docker exec savvy-postgres \
    psql -U "${DB_ADMIN_USER:-postgres}" -tAc \
    "SELECT 1 FROM pg_user WHERE usename='${DB_USER:-savvy_app}';" 2>/dev/null || echo "0")
  
  if [ "$user_exists" != "1" ]; then
    error "Application user ${DB_USER:-savvy_app} was not created"
  fi
  
  # List databases and users
  log "Databases:"
  docker exec savvy-postgres psql -U "${DB_ADMIN_USER:-postgres}" -c "\l" 2>&1 | tee -a "$LOG_FILE"
  
  log "Users:"
  docker exec savvy-postgres psql -U "${DB_ADMIN_USER:-postgres}" -c "\du" 2>&1 | tee -a "$LOG_FILE"
  
  success "PostgreSQL verification complete"
}

test_connection() {
  log "Testing database connection..."
  
  set -a
  source "$ENV_FILE"
  set +a
  
  # Test connection with app user
  if docker exec savvy-postgres \
    psql -U "${DB_USER:-savvy_app}" -d "${DB_NAME:-savvy}" \
    -c "SELECT version();" > /dev/null 2>&1; then
    success "Connection test successful"
  else
    error "Failed to connect with application user"
  fi
}

# CREDENTIALS OUTPUT

print_credentials() {
  set -a
  source "$ENV_FILE"
  set +a
  
  cat << EOF | tee -a "$LOG_FILE"

$(echo -e "${GREEN}========== DATABASE SETUP COMPLETE ==========${NC}")

Environment: ${ENVIRONMENT}
Container: savvy-postgres

PostgreSQL:
  Host: ${DB_HOST:-localhost}
  Port: ${DB_PORT:-5432}
  Database: ${DB_NAME:-savvy}
  
Users:
  App User: ${DB_USER:-savvy_app}
  Admin User: ${DB_ADMIN_USER:-postgres}
  Readonly User: savvy_readonly

Connection Strings:
  Application:
    DATABASE_URL=postgresql://${DB_USER:-savvy_app}:${DB_PASSWORD}@${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-savvy}
  
  Admin:
    postgresql://${DB_ADMIN_USER:-postgres}:****@${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-savvy}
  
  Readonly:
    postgresql://savvy_readonly:****@${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-savvy}

Docker Commands:
  View logs:    docker compose logs -f postgres
  Stop:         docker compose down
  Restart:      docker compose restart postgres
  Shell:        docker exec -it savvy-postgres psql -U ${DB_ADMIN_USER:-postgres} -d ${DB_NAME:-savvy}

Next Steps:
  1. Copy the APPLICATION connection string to savvy-backend/.env
  2. Run Prisma migrations: cd ../savvy-backend && npx prisma migrate dev
  3. Backup database: ./backup-restore.sh backup-postgres-custom
  4. See README.md for more commands

Setup log: ${LOG_FILE}

$(echo -e "${GREEN}===========================================${NC}")
EOF
}

print_backend_env_snippet() {
  set -a
  source "$ENV_FILE"
  set +a
  
  cat << EOF

$(echo -e "${YELLOW}Copy this to savvy-backend/.env:${NC}")

# Database
DATABASE_URL="postgresql://${DB_USER:-savvy_app}:${DB_PASSWORD}@${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-savvy}"

EOF
}

# CLEANUP & ERROR HANDLING

cleanup_on_error() {
  error_code=$?
  error "Setup failed with exit code $error_code"
  error "See logs: $LOG_FILE"
  
  warn "To clean up and retry:"
  echo "  docker compose down -v"
  echo "  rm $ENV_FILE"
  echo "  ./setup-database.sh $ENVIRONMENT"
  
  exit $error_code
}

trap cleanup_on_error ERR

# MAIN EXECUTION

main() {
  echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  Savvy Database Setup Automation       ║${NC}"
  echo -e "${BLUE}║  Environment: $(printf '%-25s' "$ENVIRONMENT") ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
  echo
  
  log "Setup log: $LOG_FILE"
  log "Starting initialization for $ENVIRONMENT environment..."
  
  validate_environment
  check_production_security
  start_docker_services
  wait_for_postgres
  
  log "Verifying installation..."
  sleep 3
  verify_postgres
  test_connection
  
  print_credentials
  print_backend_env_snippet
  
  success "✓ Database setup completed successfully!"
  
  if [ "$ENVIRONMENT" = "local" ]; then
    log ""
    log "Quick start:"
    log "  1. cd ../savvy-backend"
    log "  2. npm install"
    log "  3. npx prisma migrate dev"
    log "  4. npm run start:dev"
  fi
  
  exit 0
}

# Run main
main "$@"