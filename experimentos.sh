#!/usr/bin/env bash
# ============================================================
# BDA - Runner de experimentos de indexación
# Ejecuta dentro del container Docker de PostgreSQL
# ============================================================
set -euo pipefail

CONTAINER="${PG_CONTAINER:-bda-postgres}"
DB_USER="${PGUSER:-postgres}"
DB_NAME="${PGDATABASE:-bda}"

PSQL="docker exec -i $CONTAINER psql -U $DB_USER -d $DB_NAME"

SEP="────────────────────────────────────────────────────────────"

# ─── Helper ─────────────────────────────────────────────────
run_query() {
    local label="$1"
    local sql="$2"
    echo
    echo "$SEP"
    echo ">>> $label"
    echo "$SEP"
    echo "$sql"
    echo "───"
    echo "$sql" | $PSQL -X -A -t 2>&1 || true
    echo
}

run_sql() {
    local sql="$1"
    echo "$sql" | $PSQL -X -A -t 2>&1 || true
}

# ═══════════════════════════════════════════════════════════
# 0. Limpieza inicial
# ═══════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════╗"
echo "║  BDA — Experimentos de Indexación PostgreSQL        ║"
echo "╚══════════════════════════════════════════════════════╝"

run_sql "DROP INDEX IF EXISTS
  idx_transactions_amount,
  idx_transactions_type,
  idx_transactions_type_amount,
  idx_transactions_fraud,
  idx_transactions_type_redundant;"
run_sql "ANALYZE transactions;"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO A: Sin índices
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO A — Sin Índices                        ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "A.1 — SIN índice: type = 'TRANSFER' (COUNT, AVG)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE type = 'TRANSFER';"

run_query "A.2 — SIN índice: amount > 500000 (SELECT *)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount > 500000;"

# ─── EXPERIMENTO A: Con índices ────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO A — Con Índices                        ║"
echo "╚══════════════════════════════════════════════════════╝"

run_sql "CREATE INDEX idx_transactions_type ON transactions (type);
CREATE INDEX idx_transactions_amount ON transactions (amount);
ANALYZE transactions;"
echo "✓ Índices creados: idx_transactions_type, idx_transactions_amount"

run_query "A.3 — CON índice: type = 'TRANSFER' (COUNT, AVG)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE type = 'TRANSFER';"

run_query "A.4 — CON índice: amount > 500000 (SELECT *)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount > 500000;"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO B: Índice compuesto
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO B — Índice Compuesto                   ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "B.1 — SIN índice compuesto: type='CASH_OUT' AND amount>100000" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;"

run_sql "CREATE INDEX idx_transactions_type_amount ON transactions (type, amount);
ANALYZE transactions;"
echo "✓ Índice creado: idx_transactions_type_amount"

run_query "B.2 — CON índice compuesto (Index Only Scan)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;"

run_query "B.3 — CON índice compuesto + columna heap (Bitmap Heap Scan)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO C: Bitmap Scans
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO C — Bitmap Heap Scan                   ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "C.1 — Baja selectividad: amount BETWEEN 100 AND 10000" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount BETWEEN 100 AND 10000;"

run_query "C.2 — BitmapOr: type='TRANSFER' OR amount>800000" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE type = 'TRANSFER' OR amount > 800000;"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO D: Almacenamiento
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO D — Almacenamiento                     ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "D.1 — Tamaño total de tabla e índices" \
"SELECT
    'total_con_indices' AS metrica,
    pg_size_pretty(pg_total_relation_size('transactions')) AS valor
UNION ALL
SELECT
    'solo_tabla',
    pg_size_pretty(pg_relation_size('transactions'))
UNION ALL
SELECT
    'solo_indices',
    pg_size_pretty(pg_indexes_size('transactions'));"

run_query "D.2 — Tamaño individual por índice" \
"SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS tamano
FROM pg_indexes
WHERE tablename = 'transactions'
ORDER BY pg_relation_size(indexname::regclass) DESC;"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO E: Redundancias
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO E — Detección de Redundancias          ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "E.2 — Estadísticas de uso de índices" \
"SELECT
    indexrelname AS indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE relname = 'transactions'
ORDER BY idx_scan ASC;"

run_sql "CREATE INDEX idx_transactions_type_redundant ON transactions (type);"
echo "✓ Índice redundante creado: idx_transactions_type_redundant"

run_query "E.3 — Detección de redundancia por DDL" \
"SELECT
    a.indexname AS idx_redundante,
    b.indexname AS idx_que_lo_cubre
FROM pg_indexes a
JOIN pg_indexes b ON a.tablename = b.tablename
    AND a.indexname < b.indexname
    AND a.indexdef LIKE b.indexdef || '%';"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO F: Alta selectividad
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO F — Alta Selectividad (is_fraud)       ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "F.1 — SIN índice: is_fraud = true" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM transactions
WHERE is_fraud = true;"

run_sql "CREATE INDEX idx_transactions_fraud ON transactions (is_fraud);
ANALYZE transactions;"
echo "✓ Índice creado: idx_transactions_fraud"

run_query "F.2 — CON índice: Index Only Scan" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM transactions
WHERE is_fraud = true;"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO G: Index Scan plano
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO G — Index Scan (columnas fuera índice) ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "G.1 — Index Scan: columnas NO en el índice" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT amount, oldbalance_org, newbalance_orig
FROM transactions
WHERE is_fraud = true;"

# ─── Fin ───────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ Todos los experimentos completados               ║"
echo "╚══════════════════════════════════════════════════════╝"
