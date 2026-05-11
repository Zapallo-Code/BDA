-- A.1: SIN índice — Seq Scan en type
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE type = 'TRANSFER';

-- A.2: SIN índice — amount alto
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM transactions
WHERE amount > 500000;

-- Crear índices
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
