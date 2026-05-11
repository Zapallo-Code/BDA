-- I.1: SIN índice — rango de step
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE step BETWEEN 100 AND 200;

CREATE INDEX idx_i_step_brin ON transactions USING BRIN (step) WITH (pages_per_range = 32);
ANALYZE transactions;

-- I.2: CON BRIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE step BETWEEN 100 AND 200;

CREATE INDEX idx_i_step_btree ON transactions USING BTREE (step);
ANALYZE transactions;

-- I.3: Tamaños BRIN vs B-tree
SELECT 'brin' AS tipo, pg_size_pretty(pg_relation_size('idx_i_step_brin'))
UNION ALL
SELECT 'btree', pg_size_pretty(pg_relation_size('idx_i_step_btree'));

DROP INDEX idx_i_step_brin, idx_i_step_btree;
