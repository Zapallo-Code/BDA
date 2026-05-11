-- E.1: Estadísticas de uso de índices
SELECT
    indexrelname AS indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE relname = 'transactions'
ORDER BY idx_scan ASC;

CREATE INDEX idx_transactions_type_redundant ON transactions (type);

-- E.2: Detección de redundancia por DDL
SELECT
    a.indexname AS idx_redundante,
    b.indexname AS idx_que_lo_cubre
FROM pg_indexes a
JOIN pg_indexes b ON a.tablename = b.tablename
    AND a.indexname < b.indexname
    AND a.indexdef LIKE b.indexdef || '%';
