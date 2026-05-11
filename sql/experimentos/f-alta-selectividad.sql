-- F.1: SIN índice en is_fraud
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM transactions
WHERE is_fraud = true;

CREATE INDEX idx_transactions_fraud ON transactions (is_fraud);
ANALYZE transactions;

-- F.2: CON índice — Index Only Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM transactions
WHERE is_fraud = true;
