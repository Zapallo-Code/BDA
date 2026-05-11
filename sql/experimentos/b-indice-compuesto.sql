-- B.1: SIN índice compuesto — índices individuales no ayudan con AND
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

CREATE INDEX idx_transactions_type_amount ON transactions (type, amount);
ANALYZE transactions;

-- B.2: Index Only Scan — todas las columnas del SELECT están en el índice
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

-- B.3: Bitmap Heap Scan — necesita oldbalance_org del heap
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;
