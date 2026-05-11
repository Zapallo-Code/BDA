-- L.1: Bitmap Heap Scan — necesita oldbalance_org del heap
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

CREATE INDEX idx_l_covering ON transactions (type, amount) INCLUDE (oldbalance_org);
ANALYZE transactions;

-- L.2: Index Only Scan — oldbalance_org ahora está en el índice
EXPLAIN (ANALYZE, BUFFERS)
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;

DROP INDEX idx_l_covering;
