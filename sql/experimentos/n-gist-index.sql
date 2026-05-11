-- N.1: CON GIN (aún presente de M) — similitud
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig % 'C1305486';

CREATE INDEX idx_n_name_gist ON transactions USING GIST (name_orig gist_trgm_ops);
ANALYZE transactions;

-- N.2: CON GiST — similitud
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig % 'C1305486';

-- N.3: Tamaños
SELECT 'gin' AS tipo, pg_size_pretty(pg_relation_size('idx_m_name_gin'))
UNION ALL
SELECT 'gist', pg_size_pretty(pg_relation_size('idx_n_name_gist'));

DROP INDEX idx_m_name_gin, idx_n_name_gist;
