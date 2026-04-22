# Savvy Infrastructure

Docker Compose infrastructure for compiling and running the Savvy ecosystem, including PostgreSQL and the NestJS backend API.

## Requirements

- Docker (v24 or higher)
- Docker Compose (v2.20 or higher)
- The backend application cloned and configured in the sister directory

Directory Structure:
```text
parent/
├── savvy-back/      (Backend Codebase)
└── savvy-infra/     (Current Infrastructure Directory)
```

## Getting Started

1. Set up your environment variables:
```bash
cp .env.example .env
```
Ensure you configure variables such as `JWT_SECRET`, `POSTGRES_USER`, and API keys.

2. Build and start the services:
```bash
docker compose up --build
```
The `backend` service is configured to wait for the `postgres` healthcheck to pass before starting. It will also automatically execute database migrations on initialization.

## Useful Commands

```bash
# Start services in the background
docker compose up -d --build

# View real-time logs
docker compose logs -f backend
docker compose logs -f postgres

# Stop and remove containers (data volumes are preserved)
docker compose down

# Stop and entirely remove containers and data volumes
docker compose down -v

# Connect to the PostgreSQL instance via CLI
docker compose exec postgres psql -U savvy_user -d savvy
```

## Environment Variables

| Variable | Description |
|---|---|
| `POSTGRES_DB` | Name of the PostgreSQL database |
| `POSTGRES_USER` | PostgreSQL Username |
| `POSTGRES_PASSWORD` | PostgreSQL Password |
| `DATABASE_URL` | Database connection URL for Prisma (Use `postgres` as the internal host) |
| `JWT_SECRET` | Secret key for JWT signing |
| `BREVO_API_KEY` | (Optional) Brevo API key for transactional emails |
| `EXCHANGERATE_API_KEY` | (Optional) ExchangeRate API key for USD-MXN conversion |

## Exposed Ports

| Service | Port |
|---|---|
| PostgreSQL | `5433` (maps internally to 5432) |
| Backend API | `4000` |
