-- K.1: SIN índice funcional
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE LOWER(type) = 'transfer';

CREATE INDEX idx_k_lower_type ON transactions (LOWER(type));
ANALYZE transactions;

-- K.2: CON índice funcional
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE LOWER(type) = 'transfer';

DROP INDEX idx_k_lower_type;
