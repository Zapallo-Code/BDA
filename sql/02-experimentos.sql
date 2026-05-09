-- ============================================================
-- BDA Actividad: Experimentos de indexación
-- Ejecutar cada bloque CON y SIN índices y capturar
-- el output completo de EXPLAIN (ANALYZE, BUFFERS)
-- ============================================================

-- ============================================================
-- EXPERIMENTO A: Impacto de índice B-tree en columna simple
-- ============================================================

-- A.1: SIN índice — Seq Scan en type
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE type = 'TRANSFER';

-- A.2: SIN índice — búsqueda por amount alto
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount > 500000;

-- Crear índice para comparar
CREATE INDEX idx_transactions_type ON transactions (type);
CREATE INDEX idx_transactions_amount ON transactions (amount);

ANALYZE transactions;

-- A.3: CON índice — misma consulta que A.1
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE type = 'TRANSFER';

-- A.4: CON índice — misma consulta que A.2
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount > 500000;

-- ============================================================
-- EXPERIMENTO B: Index Only Scan vs Index Scan con índice compuesto
-- ============================================================

-- B.1: SIN índice compuesto — Seq Scan
-- Los índices individuales (type) y (amount) no son útiles para filtrar
-- ambas columnas simultáneamente con AND
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

-- Crear índice compuesto
CREATE INDEX idx_transactions_type_amount ON transactions (type, amount);
ANALYZE transactions;

-- B.2: Index Only Scan — todas las columnas del SELECT están en el índice
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

-- B.3: Bitmap Heap Scan — necesita ir al heap por oldbalance_org (no está en el índice)
-- Con 23% de filas, el planificador prefiere Bitmap Heap Scan sobre Index Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

-- ============================================================
-- EXPERIMENTO C: Bitmap Heap Scan (baja selectividad)
-- ============================================================

-- C.1: Query que devuelve ~10% de filas — el planificador elige Seq Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount BETWEEN 100 AND 10000;

-- C.2: Query con OR entre dos columnas indexadas — BitmapOr
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE type = 'TRANSFER' OR amount > 800000;

-- ============================================================
-- EXPERIMENTO D: Almacenamiento de índices
-- ============================================================

SELECT
    pg_size_pretty(pg_total_relation_size('transactions')) AS total_con_indices,
    pg_size_pretty(pg_relation_size('transactions')) AS solo_tabla,
    pg_size_pretty(pg_indexes_size('transactions')) AS solo_indices;

-- Tamaño individual de cada índice
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS tamano
FROM pg_indexes
WHERE tablename = 'transactions'
ORDER BY pg_relation_size(indexname::regclass) DESC;

-- ============================================================
-- EXPERIMENTO E: Detección de redundancias
-- ============================================================

-- E.1: Índices duplicados/redundantes
-- idx_transactions_type (type) es redundante si existe idx_transactions_type_amount (type, amount)
-- porque un índice en (A, B) ya cubre búsquedas solo por A.

-- E.2: Estadísticas de uso de índices
SELECT
    schemaname,
    relname AS tablename,
    indexrelname AS indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE relname = 'transactions'
ORDER BY idx_scan ASC;

-- E.3: Crear índice redundante a propósito para detectarlo
CREATE INDEX idx_transactions_type_redundant ON transactions (type);

-- Verificar redundancia: índices con misma definición
SELECT
    a.indexname AS idx_redundante,
    b.indexname AS idx_que_lo_cubre
FROM pg_indexes a
JOIN pg_indexes b ON a.tablename = b.tablename
    AND a.indexname < b.indexname
    AND a.indexdef LIKE b.indexdef || '%';

-- ============================================================
-- EXPERIMENTO F: isFraud — alta selectividad (0.13% de filas)
-- ============================================================

-- F.1: Sin índice en is_fraud
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM transactions
WHERE is_fraud = true;

CREATE INDEX idx_transactions_fraud ON transactions (is_fraud);
ANALYZE transactions;

-- F.2: Con índice — Index Only Scan (COUNT(*) se responde desde el índice)
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM transactions
WHERE is_fraud = true;

-- ============================================================
-- EXPERIMENTO G: Index Scan plano — misma alta selectividad,
-- pero seleccionando columnas NO incluidas en el índice
-- ============================================================

-- G.1: Index Scan — amount no está en idx_transactions_fraud,
-- así que PostgreSQL debe leer el índice y luego ir al heap por cada fila
EXPLAIN (ANALYZE, BUFFERS)
SELECT amount, oldbalance_org, newbalance_orig
FROM transactions
WHERE is_fraud = true;
