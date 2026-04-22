# Savvy Infrastructure - PostgreSQL

Base de datos PostgreSQL para el ecosistema Savvy.

## Requisitos

- Docker >= 24.0
- Docker Compose >= 2.20

## Inicio Rápido

1. Configurar variables de entorno:
```bash
cp .env.example .env
```

2. Levantar PostgreSQL:
```bash
docker compose up -d
```

3. Verificar estado:
```bash
docker compose ps
docker compose logs -f postgres
```

## Conexión

- **Host:** localhost
- **Puerto:** 5432
- **Base de datos:** savvy
- **Usuario:** savvy_user
- **Contraseña:** changeme (cambiar en producción)

**Connection String:**