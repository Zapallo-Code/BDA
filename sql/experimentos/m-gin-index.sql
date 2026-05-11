CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- M.1: SIN índice GIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig LIKE '%1305486%';

CREATE INDEX idx_m_name_gin ON transactions USING GIN (name_orig gin_trgm_ops);
ANALYZE transactions;

-- M.2: CON índice GIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM transactions WHERE name_orig LIKE '%1305486%';

-- (El índice se elimina en N)
