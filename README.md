# Savvy Infrastructure

Infraestructura de base de datos PostgreSQL para el ecosistema Savvy.

## 🎯 Propósito

Este repositorio contiene:
- Configuración de PostgreSQL via Docker
- Scripts de setup automatizado
- Herramientas de backup y restauración
- Documentación técnica del schema

## 📋 Requisitos

- Docker >= 24.0
- Docker Compose >= 2.20
- Bash (para scripts de automatización)

## 🚀 Inicio Rápido

### Desarrollo Local

```bash
# 1. Copiar variables de entorno
cp .env.example .env.local

# 2. Editar credenciales (opcional, los defaults funcionan)
nano .env.local

# 3. Levantar PostgreSQL
./setup-database.sh local
```

### Producción (DigitalOcean)

```bash
# 1. Crear .env.production con credenciales seguras
cp .env.example .env.production
nano .env.production  # Cambiar TODAS las contraseñas

# 2. Setup automatizado
./setup-database.sh production
```

## 🔌 Conexión

Después del setup, conecta desde el backend:

**Desarrollo Local:**
