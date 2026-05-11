-- G.1: Index Scan — columnas NO en el índice idx_transactions_fraud
EXPLAIN (ANALYZE, BUFFERS)
SELECT amount, oldbalance_org, newbalance_orig
FROM transactions
WHERE is_fraud = true;
