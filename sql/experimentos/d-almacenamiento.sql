-- D.1: Tamaño total de tabla e índices
SELECT
    pg_size_pretty(pg_total_relation_size('transactions')) AS total_con_indices,
    pg_size_pretty(pg_relation_size('transactions')) AS solo_tabla,
    pg_size_pretty(pg_indexes_size('transactions')) AS solo_indices;

-- D.2: Tamaño individual por índice
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS tamano
FROM pg_indexes
WHERE tablename = 'transactions'
ORDER BY pg_relation_size(indexname::regclass) DESC;
