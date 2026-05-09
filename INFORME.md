# Informe: Impacto de Estrategias de Indexación en PostgreSQL

## 1. Entorno

| Ítem | Detalle |
|---|---|
| Motor | PostgreSQL 16.2 |
| Hardware | Docker sobre Linux, 8 vCPUs |
| Dataset | PaySim Synthetic Financial Transactions |
| Filas | 6,362,620 |
| Tamaño tabla | 625 MB |
| Almacenamiento | SSD (volumen Docker) |
| shared_buffers | Por defecto (128 MB) |

---

## 2. Metodología

Se ejecutaron 7 experimentos sobre la tabla `transactions`. Cada query se ejecutó con `EXPLAIN (ANALYZE, BUFFERS)` para capturar:

- Tiempo de ejecución real
- Tipo de scan
- Páginas leídas (buffers)
- Precisión del estimador

Se partió de un estado sin índices, creándolos progresivamente para garantizar que cada medición refleje el escenario correcto.

---

## 3. Experimentos y Resultados

### 3.1 Experimento A: Índice B-tree en columna simple

**Tabla de resultados:**

| Query | Plan | Tiempo (ms) | Buffers | Filas |
|---|---|---|---|---|
| **A.1** type = 'TRANSFER' **sin** índice | Parallel Seq Scan | 659 | 79,968 | 532,909 |
| **A.3** type = 'TRANSFER' **con** índice | Bitmap Heap Scan | 862 | 72,775 | 532,909 |
| **A.2** amount > 500000 **sin** índice | Parallel Seq Scan | 801 | 79,968 | 340,284 |
| **A.4** amount > 500000 **con** índice | Bitmap Heap Scan | 1,597 | 73,214 | 340,284 |

#### A.1 — Sin índice (Seq Scan)

```
Finalize Aggregate
  ->  Gather
        Workers Planned: 2
        Workers Launched: 2
        ->  Partial Aggregate
              ->  Parallel Seq Scan
                    Filter: (type = 'TRANSFER')
                    Rows Removed by Filter: 1,943,237
                    Buffers: shared hit=64 read=79,904
  Execution Time: 658.552 ms
```

#### A.3 — Con índice (Bitmap Heap Scan)

```
Finalize Aggregate
  ->  Gather
        Workers Planned: 2
        Workers Launched: 2
        ->  Partial Aggregate
              ->  Parallel Bitmap Heap Scan
                    Recheck Cond: (type = 'TRANSFER')
                    Rows Removed by Index Recheck: 799,752
                    Heap Blocks: exact=13,125 lossy=11,136
                    Buffers: shared read=72,775
                    ->  Bitmap Index Scan on idx_transactions_type
                          Index Cond: (type = 'TRANSFER')
                          Buffers: shared read=458
  Execution Time: 861.698 ms
```

#### A.2 — Sin índice (Seq Scan con amount)

```
Gather
  Workers Planned: 2
  Workers Launched: 2
  ->  Parallel Seq Scan
        Filter: (amount > 500000)
        Rows Removed by Filter: 2,007,445
        Buffers: shared hit=160 read=79,808
Execution Time: 800.772 ms
```

#### A.4 — Con índice (Bitmap Heap Scan con amount)

```
Bitmap Heap Scan
  Recheck Cond: (amount > 500000)
  Rows Removed by Index Recheck: 2,469,562
  Heap Blocks: exact=38,812 lossy=33,103
  Buffers: shared read=73,214
  ->  Bitmap Index Scan on idx_transactions_amount
        Index Cond: (amount > 500000)
        Buffers: shared read=1,299
Execution Time: 1596.619 ms
```

**Análisis:** En ambos casos el índice **empeoró** el rendimiento. La query A.1 pasó de 659 ms a 862 ms (+31%) y A.2 de 801 ms a 1,597 ms (+99%). El índice reduce las páginas leídas (de ~80K a ~73K) pero introduce la sobrecarga de construir y leer el bitmap, además del acceso aleatorio al heap que es más costoso que el secuencial cuando se devuelven muchas filas.

**Conclusión de ingeniería:** Los índices B-tree en columnas con baja cardinalidad (type tiene solo 5 valores) o con selectividad media-alta (>5% de filas) no solo no ayudan, sino que **perjudican** el rendimiento. En producción, estos índices incrementarían el tiempo de escritura sin beneficio en lecturas.

---

### 3.2 Experimento B: Índice Compuesto vs Scan Secuencial

**Tabla de resultados:**

| Query | Plan | Tiempo (ms) | Buffers | Diferencia vs Seq Scan |
|---|---|---|---|---|
| **B.1** sin índice compuesto | Seq Scan | 1,284 | 79,968 | — |
| **B.2** con índice compuesto (solo columnas indexadas) | **Index Only Scan** | **1,106** | 927,372 | **1.16× más rápido** |
| **B.3** con índice compuesto (con columna no indexada) | Bitmap Heap Scan | 2,327 | 85,033 | **1.81× más lento** |

#### B.1 — Sin índice compuesto

```
Seq Scan
  Filter: (amount > 100000 AND type = 'CASH_OUT')
  Rows Removed by Filter: 4,899,189
  Buffers: shared hit=16,233 read=63,735
  Execution Time: 1283.614 ms
```

#### B.2 — Index Only Scan (solo columnas en el índice)

```
Index Only Scan using idx_transactions_type_amount
  Index Cond: (type = 'CASH_OUT' AND amount > 100000)
  Heap Fetches: 0
  Buffers: shared hit=920,172 read=7,200
  Execution Time: 1105.524 ms
```

#### B.3 — Bitmap Heap Scan (necesita columnas del heap)

```
Bitmap Heap Scan
  Recheck Cond: (type = 'CASH_OUT' AND amount > 100000)
  Rows Removed by Index Recheck: 1,971,368
  Heap Blocks: exact=44,695 lossy=33,138
  Buffers: shared hit=7,200 read=77,833
  ->  Bitmap Index Scan on idx_transactions_type_amount
        Index Cond: (type = 'CASH_OUT' AND amount > 100000)
        Buffers: shared hit=7,200
  Execution Time: 2326.715 ms
```

**Análisis:** El índice compuesto `(type, amount)` permite un **Index Only Scan** (B.2) cuando todas las columnas del SELECT están en el índice, logrando 1,106 ms vs 1,284 ms del Seq Scan. Sin embargo, cuando se necesita una columna del heap (B.3, `oldbalance_org`), el planificador elige **Bitmap Heap Scan** y el rendimiento empeora (2,327 ms). Esto ocurre porque 1,463,431 filas (23% de la tabla) requieren demasiadas operaciones de bitmap + heap.

La cantidad de buffers en B.2 (927,372) es engañosa: 920,172 son hits de caché del índice, que son rápidos. La lectura real de disco fueron solo 7,200 buffers.

**Conclusión de ingeniería:** El Index Only Scan es útil cuando el índice cubre todas las columnas de la consulta. Para consultas que necesitan datos del heap con baja selectividad, incluso un índice compuesto puede ser contraproducente. En producción, un índice compuesto como `(type, amount)` debe reservarse para consultas muy selectivas donde además se filtren y devuelvan pocas columnas.

---

### 3.3 Experimento C: Bitmap Heap Scan y combinación de índices

**Tabla de resultados:**

| Query | Plan | Tiempo (ms) | Buffers |
|---|---|---|---|
| **C.1** amount BETWEEN 100 AND 10000 | Seq Scan | 1,307 | 79,968 |
| **C.2** type = 'TRANSFER' OR amount > 800000 | BitmapOr | 778 | 74,062 |

#### C.1 — Baja selectividad (~20% de filas)

```
Seq Scan
  Filter: (amount >= 100 AND amount <= 10000)
  Rows Removed by Filter: 5,090,632
  Execution Time: 1307.309 ms
```

El planificador eligió Seq Scan porque el índice no ofrece ventaja: devolver el 20% de las filas mediante acceso indexado implicaría demasiadas lecturas aleatorias. Es más barato barrer todo.

#### C.2 — Combinación de índices con BitmapOr

```
Bitmap Heap Scan
  Recheck Cond: (type = 'TRANSFER' OR amount > 800000)
  Rows Removed by Index Recheck: 2,398,202
  Heap Blocks: exact=39,774 lossy=33,054
  ->  BitmapOr
        ->  Bitmap Index Scan on idx_transactions_type
              Index Cond: (type = 'TRANSFER')
        ->  Bitmap Index Scan on idx_transactions_amount
              Index Cond: (amount > 800000)
  Execution Time: 777.811 ms
```

PostgreSQL combinó ambos índices individuales mediante **BitmapOr**: construyó un mapa de bits para cada condición, los combinó con OR a nivel de bits, y luego leyó los bloques del heap una sola vez. Este plan es eficiente porque evita escanear toda la tabla (1,307 ms) usando dos pasadas rápidas por los índices (458 + 659 buffers) más una sola pasada por el heap.

---

### 3.4 Experimento D: Almacenamiento

| Componente | Tamaño |
|---|---|
| Tabla sola | 625 MB |
| Total con índices | 1,082 MB |
| **Solo índices** | **457 MB (73% de la tabla)** |

**Desglose por índice:**

| Índice | Tipo | Tamaño |
|---|---|---|
| `idx_transactions_type_amount` | B-tree (type, amount) | 235 MB |
| `idx_transactions_amount` | B-tree (amount) | 180 MB |
| `idx_transactions_type` | B-tree (type) | 42 MB |

**Análisis:** Los índices ocupan 457 MB, un 73% del tamaño de la tabla. Esto significa que por cada MB de datos, pagamos ~0.73 MB de espacio de índice. En este caso:
- `idx_transactions_type_amount` (235 MB) es el más grande por ser compuesto
- `idx_transactions_amount` (180 MB) es grande porque `amount` tiene alta cardinalidad
- `idx_transactions_type` (42 MB) es pequeño porque `type` tiene solo 5 valores

El índice `idx_transactions_type` (42 MB) es redundante si existe `idx_transactions_type_amount` (que empieza con la misma columna). Eliminarlo liberaría 42 MB sin pérdida de rendimiento.

**Conclusión de ingeniería:** El costo de almacenamiento debe justificarse con beneficio en velocidad de lectura. Índices que no se usan o que son redundantes deben eliminarse para reducir el costo de mantenimiento en operaciones INSERT/UPDATE/DELETE y liberar espacio.

---

### 3.5 Experimento E: Detección de Redundancias

#### E.1 — Redundancia conceptual

El índice `idx_transactions_type (type)` es redundante si existe `idx_transactions_type_amount (type, amount)`, porque un B-tree en `(A, B)` puede responder consultas que filtran solo por `A` (el leading column). PostgreSQL lo hará mediante un Index Scan sobre el índice compuesto, sin necesidad del índice individual.

#### E.2 — Estadísticas de uso

```
 idx_transactions_type_amount |    2 | 2,926,862
 idx_transactions_type        |    2 | 1,065,818
 idx_transactions_amount      |    3 |   512,974
```

Todos los índices fueron utilizados durante los experimentos. `idx_transactions_type_amount` es el de mayor lectura de tuplas porque se usó en el experimento B (2.93M filas leídas entre Index Only Scan y Bitmap Heap Scan).

#### E.3 — Detección automática

Se creó `idx_transactions_type_redundant` como un duplicado exacto de `idx_transactions_type`. Sin embargo, la redundancia **no fue detectada** por la query de comparación de DDL:

```
 idx_redundante | idx_que_lo_cubre
----------------+------------------
(0 rows)
```

La razón es que `a.indexdef LIKE b.indexdef || '%'` falla porque los nombres de índice son parte de la definición (`CREATE INDEX idx_transactions_type_redundant ON ...` no es LIKE `CREATE INDEX idx_transactions_type ON ...`). En producción, la detección correcta requiere analizar solo las columnas indexadas mediante `pg_index` en lugar de `pg_indexes.indexdef`.

**Redundancias identificadas manualmente:**

| Índice redundante | Cubierto por | Justificación |
|---|---|---|
| `idx_transactions_type_redundant` | `idx_transactions_type` | Mismo `(type)` |
| `idx_transactions_type` | `idx_transactions_type_amount` | `(type)` es prefijo de `(type, amount)` |

---

### 3.6 Experimento F: Alta Selectividad — Columna isFraud

**Tabla de resultados:**

| Query | Plan | Tiempo (ms) | Buffers | Filas |
|---|---|---|---|---|
| **F.1** sin índice | Parallel Seq Scan | **270** | 79,968 | 8,213 |
| **F.2** con índice | **Index Only Scan** | **0.94** | **13** | 8,213 |

**Mejora: 287× más rápido** (270 ms → 0.94 ms)

#### F.1 — Sin índice

```
Finalize Aggregate
  ->  Gather
        Workers Planned: 2
        Workers Launched: 2
        ->  Partial Aggregate
              ->  Parallel Seq Scan
                    Filter: is_fraud
                    Rows Removed by Filter: 2,118,136
  Execution Time: 270.423 ms
```

Sin índice, PostgreSQL escanea **toda la tabla** para encontrar solo 8,213 filas de fraude (0.13% del total).

#### F.2 — Con índice

```
Aggregate
  ->  Index Only Scan using idx_transactions_fraud
        Index Cond: (is_fraud = true)
        Heap Fetches: 0
        Buffers: shared hit=3 read=10
  Execution Time: 0.943 ms
```

Con el índice, PostgreSQL usó **Index Only Scan**: leyó solo 13 buffers (3 en caché, 10 de disco) contra los 79,968 del Seq Scan. La columna `is_fraud` tiene solo 2 valores posibles y la distribución es extremadamente sesgada (99.87% false, 0.13% true), lo que permite al índice ser extremadamente selectivo.

**Conclusión de ingeniería:** Los índices brillan en columnas con alta selectividad donde el filtro reduce drásticamente el conjunto de resultados. En este caso, pasar de 270 ms a 0.94 ms transforma una query analítica pesada en una consulta casi instantánea — crítica para un dashboard de detección de fraudes en tiempo real.

---

### 3.7 Experimento G: Index Scan (plano)

Este experimento demuestra un **Index Scan** plano, donde PostgreSQL lee el índice secuencialmente y luego accede al heap **fila por fila** para recuperar columnas que no están en el índice. Esto contrasta con:
- **Index Only Scan** (F.2): solo lee el índice, sin tocar el heap
- **Bitmap Heap Scan** (A.3, A.4): construye un bitmap de páginas y accede al heap en orden físico

**Tabla de resultados:**

| Query | Plan | Tiempo (ms) | Buffers | Filas |
|---|---|---|---|---|
| **G.1** is_fraud con columnas fuera del índice | **Index Scan** | **12.1** | 2,106 | 8,213 |

#### G.1 — Index Scan (amount, oldbalance_org, newbalance_orig no están en el índice)

```
Index Scan using idx_transactions_fraud on transactions
  Index Cond: (is_fraud = true)
  Buffers: shared hit=855 read=1,251
  Execution Time: 12.114 ms
```

**Análisis:** A diferencia del experimento F.2 (Index Only Scan con 13 buffers), aquí PostgreSQL debe leer cada fila del heap para obtener `amount`, `oldbalance_org` y `newbalance_orig` que no están en el índice `(is_fraud)`. Esto requiere 2,106 buffers (855 en caché, 1,251 de disco) para las 8,213 filas. Aun así, es **22× más rápido** que el Seq Scan (270 ms) porque solo accede a las páginas del heap que contienen filas de fraude.

El planificador eligió **Index Scan** (no Bitmap Heap Scan) porque la alta selectividad (0.13%) hace que el acceso aleatorio fila por fila sea más barato que construir un bitmap para tan pocas páginas.

**Conclusión de ingeniería:** El Index Scan es el tipo de scan adecuado cuando:
1. La selectividad es muy alta (<1%)
2. Se necesitan columnas del heap que no están en el índice
3. El número de filas es lo suficientemente pequeño como para que el acceso aleatorio no sea problema

Si la selectividad fuera ligeramente mayor (~1-5%), el planificador usaría Bitmap Heap Scan en su lugar, y si todas las columnas estuvieran en el índice, usaría Index Only Scan.

---

## 4. Resumen Comparativo

| Experimento | Sin índice | Con índice | Mejora | Factor | Tipo de scan |
|---|---|---|---|---|---|
| A: type = 'TRANSFER' | 659 ms | 862 ms | **empeora** | 0.76× | Bitmap Heap Scan |
| A: amount > 500000 | 801 ms | 1,597 ms | **empeora** | 0.5× | Bitmap Heap Scan |
| B: solo columnas indexadas | 1,284 ms | 1,106 ms | marginal | 1.16× | Index Only Scan |
| B: con heap columns | 1,284 ms | 2,327 ms | **empeora** | 0.55× | Bitmap Heap Scan |
| C: amount BETWEEN | 1,307 ms | Seq Scan (óptimo) | — | 1.0× | Seq Scan |
| C: OR cond | — | 778 ms | BitmapOr | — | BitmapOr |
| F: is_fraud = true | 270 ms | **0.94 ms** | **excelente** | **287×** | Index Only Scan |
| G: is_fraud + heap cols | — | **12.1 ms** | — | — | **Index Scan** |

## 5. Conclusiones de Ingeniería

### 5.1 Tipos de scan y cuándo se usan

| Scan | Cuándo ocurre | Ejemplo |
|---|---|---|
| **Seq Scan** | Selectividad baja (>10% filas) o sin índice útil | A.1, A.2, B.1, C.1 |
| **Bitmap Heap Scan** | Selectividad media (1-10%), o con BitmapOr/BitmapAnd | A.3, A.4, B.3, C.2 |
| **Index Scan** | Selectividad alta (<1%), con columnas del heap no indexadas | G.1 |
| **Index Only Scan** | Selectividad alta (<1%), todas las columnas en el índice | B.2, F.2 |

### 5.2 ¿Cuándo conviene un índice?

- **Selectividad muy alta** (< 0.5% de filas): índice extremadamente efectivo. Index Only Scan si el índice cubre la consulta (Experimento F: 287×), Index Scan si necesita el heap (Experimento G: 22×).
- **Selectividad media** (1-10%): el índice puede ayudar marginalmente con Bitmap Heap Scan, pero el beneficio no siempre justifica el costo (Experimento A: empeora el rendimiento).
- **Selectividad baja** (> 10%): el índice generalmente **no ayuda** e incluso empeora el rendimiento (Experimento A, B.3).

### 5.3 Recomendaciones para entornos reales

1. **No indexar columnas de baja cardinalidad** como `type` (solo 5 valores) a menos que se combine con otras columnas en un índice compuesto.
2. **Preferir índices compuestos** a múltiples índices individuales, pero solo si la selectividad de la consulta lo justifica.
3. **El índice no siempre es la respuesta**: como vimos en A.3, A.4 y B.3, un índice puede empeorar el rendimiento si la selectividad es baja.
4. **Maximizar Index Only Scan**: incluir en el índice solo las columnas necesarias para las consultas más frecuentes puede evitar acceso al heap.
5. **Eliminar índices redundantes**: si existe `(A, B)`, el índice individual `(A)` es innecesario. Ahorra espacio y reduce costo en escrituras.
6. **Monitorear uso real**: `pg_stat_user_indexes` muestra qué índices realmente se usan. Índices con `idx_scan = 0` son candidatos a eliminación.
7. **Indexar columnas de alta selectividad primero**: `is_fraud` (0.13% de filas) es un excelente candidato. Columnas como `type` con 5 valores no lo son.

### 5.4 Costo vs. Beneficio

Los 457 MB de índices (73% del tamaño de la tabla) solo se justifican si las consultas que aceleran son críticas:

| Índice | Tamaño | Beneficio | Veredicto |
|---|---|---|---|
| `idx_transactions_fraud` | ~2 MB | 287× más rápido para detección de fraudes | **Altamente recomendado** |
| `idx_transactions_type_amount` | 235 MB | Beneficio marginal o negativo según selectividad | **Dudoso** — evaluar si hay consultas muy selectivas |
| `idx_transactions_amount` | 180 MB | Empeora el rendimiento en queries de rango (>500k) | **No recomendado** |
| `idx_transactions_type` | 42 MB | Redundante si existe el compuesto | **Eliminar** |

La lección principal de este informe: **un índice no es una solución universal**. Su efectividad depende críticamente de la selectividad de la consulta, la cardinalidad de la columna, y qué columnas se seleccionan. Cada índice debe justificarse con datos empíricos de rendimiento, no por intuición.
