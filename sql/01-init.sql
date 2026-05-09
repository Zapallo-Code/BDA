-- ============================================================
-- BDA Actividad: Configuración inicial
-- ============================================================

-- Crear tabla principal
CREATE TABLE transactions (
    step INT,
    type VARCHAR(20),
    amount NUMERIC(12,2),
    name_orig VARCHAR(20),
    oldbalance_org NUMERIC(16,2),
    newbalance_orig NUMERIC(16,2),
    name_dest VARCHAR(20),
    oldbalance_dest NUMERIC(16,2),
    newbalance_dest NUMERIC(16,2),
    is_fraud BOOLEAN,
    is_flagged_fraud BOOLEAN
);

-- Importar datos desde CSV (~6.36M filas)
COPY transactions
FROM '/data/paysim.csv'
DELIMITER ','
CSV HEADER;

-- Estadísticas para el optimizador
ANALYZE transactions;
