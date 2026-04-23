#!/bin/bash
set -e

APP_USER="${APP_USER:-savvy_app}"
APP_PASSWORD="${APP_PASSWORD:-changeme}"

echo "[roles] Creando usuario de aplicación: $APP_USER"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  -- Usuario de la aplicación (read/write)
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$APP_USER') THEN
      CREATE USER $APP_USER WITH PASSWORD '$APP_PASSWORD';
    END IF;
  END \$\$;

  -- Permisos completos en el schema public
  GRANT USAGE ON SCHEMA public TO $APP_USER;
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $APP_USER;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $APP_USER;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO $APP_USER;

  -- Permisos automáticos para tablas futuras
  ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $APP_USER;
  
  ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT ON SEQUENCES TO $APP_USER;

  -- Usuario de solo lectura (para analytics/reportes)
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'savvy_readonly') THEN
      CREATE USER savvy_readonly WITH PASSWORD 'readonly_changeme';
    END IF;
  END \$\$;

  GRANT USAGE ON SCHEMA public TO savvy_readonly;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO savvy_readonly;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT ON TABLES TO savvy_readonly;
EOSQL

echo "[roles] Roles creados correctamente"