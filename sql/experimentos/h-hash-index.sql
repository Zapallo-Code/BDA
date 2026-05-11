-- H.1: SIN índice — búsqueda exacta
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig = 'C1305486145';

CREATE INDEX idx_h_name_hash ON transactions USING HASH (name_orig);
ANALYZE transactions;

-- H.2: CON HASH
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig = 'C1305486145';

CREATE INDEX idx_h_name_btree ON transactions USING BTREE (name_orig);
ANALYZE transactions;

-- H.3: CON BTREE (comparación)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig = 'C1305486145';

-- H.4: Tamaños
SELECT 'hash' AS tipo, pg_size_pretty(pg_relation_size('idx_h_name_hash'))
UNION ALL
SELECT 'btree', pg_size_pretty(pg_relation_size('idx_h_name_btree'));

DROP INDEX idx_h_name_hash, idx_h_name_btree;
