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

OUTPUT_FILE="/home/valerubio_7/Dev/BDA/resultados-experimentos.txt"
exec > >(tee "$OUTPUT_FILE") 2>&1

# ═══════════════════════════════════════════════════════════
# 0. Limpieza inicial
# ═══════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════╗"
echo "║  BDA — Experimentos de Indexación PostgreSQL        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "Inicio: $(date)"
echo

run_sql "DROP EXTENSION IF EXISTS pg_trgm;"
run_sql "DROP INDEX IF EXISTS
  idx_transactions_amount,
  idx_transactions_type,
  idx_transactions_type_amount,
  idx_transactions_fraud,
  idx_transactions_type_redundant,
  idx_h_name_hash,
  idx_h_name_btree,
  idx_i_step_brin,
  idx_i_step_btree,
  idx_j_fraud_amount,
  idx_j_fraud_amount_full,
  idx_k_lower_type,
  idx_l_covering,
  idx_m_name_gin,
  idx_n_name_gist;"
run_sql "ANALYZE transactions;"
echo "✓ Estado inicial: sin índices"
echo

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO A: B-tree simple
# ═══════════════════════════════════════════════════════════
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO A — B-tree en columna simple           ║"
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

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO A                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO B: Índice compuesto
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO B — Índice Compuesto (type, amount)    ║"
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

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO B                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

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

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO C                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

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

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO D                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════
# EXPERIMENTO E: Redundancias
# ═══════════════════════════════════════════════════════════
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO E — Detección de Redundancias          ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "E.1 — Estadísticas de uso de índices" \
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

run_query "E.2 — Detección de redundancia por DDL" \
"SELECT
    a.indexname AS idx_redundante,
    b.indexname AS idx_que_lo_cubre
FROM pg_indexes a
JOIN pg_indexes b ON a.tablename = b.tablename
    AND a.indexname < b.indexname
    AND a.indexdef LIKE b.indexdef || '%';"

run_query "E.3 — Detección de redundancia por columnas (pg_index)" \
"SELECT
    a.indexname AS idx_redundante,
    b.indexname AS idx_que_lo_cubre
FROM pg_indexes a
JOIN pg_indexes b ON a.tablename = b.tablename
    AND a.indexname <> b.indexname
WHERE a.indexdef LIKE (SELECT regexp_replace(b.indexdef, 'CREATE INDEX \S+ ', 'CREATE INDEX test ') )
  AND b.indexdef LIKE (SELECT regexp_replace(a.indexdef, 'CREATE INDEX \S+ ', 'CREATE INDEX test ') );"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO E                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

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

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO F                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

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

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO G                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO H: Hash Index
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO H — Hash Index                         ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "H.1 — SIN índice: búsqueda exacta por name_orig" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig = 'C1305486145';"

run_sql "CREATE INDEX idx_h_name_hash ON transactions USING HASH (name_orig);
ANALYZE transactions;"
echo "✓ Índice HASH creado"

run_query "H.2 — CON índice HASH: misma búsqueda exacta" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig = 'C1305486145';"

run_sql "CREATE INDEX idx_h_name_btree ON transactions USING BTREE (name_orig);
ANALYZE transactions;"
echo "✓ Índice BTREE creado (para comparación)"

run_query "H.3 — CON índice BTREE: misma búsqueda exacta" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig = 'C1305486145';"

run_query "H.4 — Comparación de tamaños HASH vs BTREE" \
"SELECT 'hash' AS tipo, pg_size_pretty(pg_relation_size('idx_h_name_hash')) AS tamano
UNION ALL
SELECT 'btree', pg_size_pretty(pg_relation_size('idx_h_name_btree'));"

run_sql "DROP INDEX idx_h_name_hash, idx_h_name_btree;"
echo "✓ Índices HASH y BTREE eliminados"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO H                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO I: BRIN Index
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO I — BRIN Index                         ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "I.1 — SIN índice: búsqueda por rango de step" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE step BETWEEN 100 AND 200;"

run_sql "CREATE INDEX idx_i_step_brin ON transactions USING BRIN (step) WITH (pages_per_range = 32);
ANALYZE transactions;"
echo "✓ Índice BRIN creado en step"

run_query "I.2 — CON índice BRIN: misma búsqueda por rango" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE step BETWEEN 100 AND 200;"

run_sql "CREATE INDEX idx_i_step_btree ON transactions USING BTREE (step);
ANALYZE transactions;"
echo "✓ Índice BTREE creado en step (para comparación)"

run_query "I.3 — Comparación de tamaños BRIN vs BTREE" \
"SELECT 'brin' AS tipo, pg_size_pretty(pg_relation_size('idx_i_step_brin')) AS tamano
UNION ALL
SELECT 'btree', pg_size_pretty(pg_relation_size('idx_i_step_btree'));"

run_sql "DROP INDEX idx_i_step_brin, idx_i_step_btree;"
echo "✓ Índices BRIN y BTREE eliminados"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO I                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO J: Partial Index
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO J — Partial Index                      ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "J.1 — SIN índice parcial: is_fraud=true AND amount>500000" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE is_fraud = true AND amount > 500000;"

run_sql "CREATE INDEX idx_j_fraud_amount ON transactions (amount) WHERE is_fraud = true;
ANALYZE transactions;"
echo "✓ Índice PARCIAL creado: ON (amount) WHERE is_fraud=true"

run_query "J.2 — CON índice parcial: misma consulta" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE is_fraud = true AND amount > 500000;"

run_sql "CREATE INDEX idx_j_fraud_amount_full ON transactions (amount);
ANALYZE transactions;"
echo "✓ Índice COMPLETO creado en amount (para comparación de tamaño)"

run_query "J.3 — Comparación de tamaños: parcial vs completo" \
"SELECT 'parcial (is_fraud=true)' AS tipo,
    pg_size_pretty(pg_relation_size('idx_j_fraud_amount')) AS tamano
UNION ALL
SELECT 'completo (todos)',
    pg_size_pretty(pg_relation_size('idx_j_fraud_amount_full'));"

run_sql "DROP INDEX idx_j_fraud_amount, idx_j_fraud_amount_full;"
echo "✓ Índices parcial y completo eliminados"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO J                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO K: Functional Index
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO K — Functional Index                   ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "K.1 — SIN índice funcional: LOWER(type) = 'transfer'" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE LOWER(type) = 'transfer';"

run_sql "CREATE INDEX idx_k_lower_type ON transactions (LOWER(type));
ANALYZE transactions;"
echo "✓ Índice FUNCIONAL creado: ON (LOWER(type))"

run_query "K.2 — CON índice funcional: misma consulta" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE LOWER(type) = 'transfer';"

run_sql "DROP INDEX idx_k_lower_type;"
echo "✓ Índice funcional eliminado"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO K                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO L: Covering Index (INCLUDE)
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO L — Covering Index (INCLUDE)           ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "L.1 — SIN covering: usa índice compuesto pero necesita heap para oldbalance_org" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;"

run_sql "CREATE INDEX idx_l_covering ON transactions (type, amount) INCLUDE (oldbalance_org);
ANALYZE transactions;"
echo "✓ Covering Index creado: ON (type, amount) INCLUDE (oldbalance_org)"

run_query "L.2 — CON covering: Index Only Scan (todas las columnas en el índice)" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;"

run_sql "DROP INDEX idx_l_covering;"
echo "✓ Covering Index eliminado"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO L                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO M: GIN Index
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO M — GIN Index (pg_trgm)                ║"
echo "╚══════════════════════════════════════════════════════╝"

run_sql "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
echo "✓ Extensión pg_trgm instalada"

run_query "M.1 — SIN índice GIN: búsqueda por patrón LIKE" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig LIKE '%1305486%';"

run_sql "CREATE INDEX idx_m_name_gin ON transactions USING GIN (name_orig gin_trgm_ops);
ANALYZE transactions;"
echo "✓ Índice GIN creado con trigramas"

run_query "M.2 — CON índice GIN: misma búsqueda LIKE" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig LIKE '%1305486%';"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO M                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ============================================================
# EXPERIMENTO N: GiST Index
# ============================================================
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  EXPERIMENTO N — GiST Index (pg_trgm)               ║"
echo "╚══════════════════════════════════════════════════════╝"

run_query "N.1 — SIN índice GiST: búsqueda por similitud" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig % 'C1305486';"

run_sql "CREATE INDEX idx_n_name_gist ON transactions USING GIST (name_orig gist_trgm_ops);
ANALYZE transactions;"
echo "✓ Índice GiST creado con trigramas"

run_query "N.2 — CON índice GiST: misma búsqueda por similitud" \
"EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig % 'C1305486';"

run_query "N.3 — Comparación tamaños: GIN vs GiST" \
"SELECT 'gin' AS tipo, pg_size_pretty(pg_relation_size('idx_m_name_gin')) AS tamano
UNION ALL
SELECT 'gist', pg_size_pretty(pg_relation_size('idx_n_name_gist'));"

run_sql "DROP INDEX idx_m_name_gin, idx_n_name_gist;"
echo "✓ Índices GIN y GiST eliminados"

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  FIN EXPERIMENTO N                                  ║"
echo "╚══════════════════════════════════════════════════════╝"

# ─── Fin ───────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ Todos los experimentos completados               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "Fin: $(date)"
