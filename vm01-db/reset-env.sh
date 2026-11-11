#!/bin/bash
set -e

echo "Recriando banco PostgreSQL e aplicando massa de dados (Pagila)..."
docker compose stop postgres
docker compose rm -f -v postgres
docker compose up -d postgres

echo "Aguardando PostgreSQL e scripts SQL inicializarem..."
until docker exec tcc-postgres pg_isready -U postgres -d pagila > /dev/null 2>&1; do
    echo "Aguardando banco..."
    sleep 2
done

echo "PostgreSQL pronto e populado para a rodada de testes!"