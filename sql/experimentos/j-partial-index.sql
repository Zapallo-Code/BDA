-- J.1: SIN índice parcial
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE is_fraud = true AND amount > 500000;

CREATE INDEX idx_j_fraud_amount ON transactions (amount) WHERE is_fraud = true;
ANALYZE transactions;

-- J.2: CON índice parcial
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(amount)
FROM transactions
WHERE is_fraud = true AND amount > 500000;

CREATE INDEX idx_j_fraud_amount_full ON transactions (amount);
ANALYZE transactions;

-- J.3: Tamaños
SELECT 'parcial' AS tipo, pg_size_pretty(pg_relation_size('idx_j_fraud_amount'))
UNION ALL
SELECT 'completo', pg_size_pretty(pg_relation_size('idx_j_fraud_amount_full'));

DROP INDEX idx_j_fraud_amount, idx_j_fraud_amount_full;
