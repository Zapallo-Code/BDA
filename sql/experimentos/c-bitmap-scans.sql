-- C.1: Baja selectividad (~20% filas) — Seq Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount BETWEEN 100 AND 10000;

-- C.2: BitmapOr — combina dos índices con OR
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE type = 'TRANSFER' OR amount > 800000;
