# Informe

**Integrantes del Team:** Valentin Rubio, Luciano Castro, Santiago Oses, Santiago Calzolari, Pablo Geyer

**Nombre del Team:** Zapallo Code

---

## Entorno donde probamos todo

- PostgreSQL 16.2 corriendo en Docker
- Usamos el dataset PaySim de transacciones financieras
- **6,362,620 filas** en una tabla de 625 MB

---

## Cómo lo hicimos

Hicimos 14 experimentos sobre la tabla `transactions` probando distintos tipos de índice. Cada query la ejecutamos con `EXPLAIN (ANALYZE, BUFFERS)` para ver los tiempos reales, qué tipo de scan usaba, y cuántas páginas leía.

Arrancamos sin ningún índice y los fuimos creando de a uno. Los experimentos de la H a la N crean su propio índice y lo borran al final para no molestar a los demás.

---

## Experimentos y qué pasó

### A: B-tree simple (type y amount)

Probamos ponerle índice a `type` (5 valores nomás) y a `amount` (montos altos).

| Query | Sin índice | Con índice | Qué pasó |
|---|---|---|---|
| type = 'TRANSFER' | 242 ms (Seq Scan) | 324 ms (Bitmap) | ❌ más lento |
| amount > 500000 | 289 ms (Seq Scan) | 674 ms (Bitmap) | ❌ mucho más lento |

El índice **empeoró** todo. El tema es que `type` tiene solo 5 valores, el índice no ayuda casi. Y con `amount > 500000` devuelve como 340 mil filas, que son muchas. El Bitmap Heap Scan termina siendo más lento que leer todo secuencialmente.

**A.1 — Sin índice:**
```sql
SELECT COUNT(*), AVG(amount) FROM transactions WHERE type = 'TRANSFER';
```
```
Parallel Seq Scan on transactions
  Filter: (type = 'TRANSFER')
  Rows Removed by Filter: 1,943,237
  Buffers: shared hit=10769 read=69199
Execution Time: 242.400 ms
```

**A.3 — Con índice:**
```sql
SELECT COUNT(*), AVG(amount) FROM transactions WHERE type = 'TRANSFER';
```
Parallel Bitmap Heap Scan on transactions
  Recheck Cond: (type = 'TRANSFER')
  Rows Removed by Index Recheck: 799,752
  Heap Blocks: exact=12750 lossy=10662
  Buffers: shared hit=1 read=72774
  ->  Bitmap Index Scan on idx_transactions_type
        Buffers: shared read=458
Execution Time: 324.241 ms
```

**A.2 — Sin índice:**
```sql
SELECT * FROM transactions WHERE amount > 500000;
```
Parallel Seq Scan on transactions
  Filter: (amount > 500000)
  Rows Removed by Filter: 2,007,445
  Buffers: shared hit=10865 read=69103
Execution Time: 288.974 ms
```

**A.4 — Con índice:**
```sql
SELECT * FROM transactions WHERE amount > 500000;
```
Bitmap Heap Scan on transactions
  Recheck Cond: (amount > 500000)
  Rows Removed by Index Recheck: 2,469,562
  Heap Blocks: exact=38812 lossy=33103
  Buffers: shared read=73214
  ->  Bitmap Index Scan on idx_transactions_amount
        Buffers: shared read=1299
Execution Time: 673.615 ms
```

**Conclusión:** si vas a devolver muchas filas (>5% de la tabla), el índice sobra y hasta molesta.

---

### B: Índice compuesto (type, amount)

Probamos un índice en dos columnas juntas `(type, amount)`.

| Query | Plan | Tiempo |
|---|---|---|
| Sin índice compuesto | Seq Scan | 927 ms |
| Solo columnas del índice | **Index Only Scan** | **386 ms** |
| Con columna que no está en el índice | Bitmap Heap Scan | 932 ms |

**B.1 — Sin índice compuesto:**
```sql
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;
```
Seq Scan on transactions
  Filter: ((amount > 100000) AND (type = 'CASH_OUT'))
  Rows Removed by Filter: 4,899,189
  Buffers: shared hit=16233 read=63735
Execution Time: 926.854 ms
```

**B.2 — Index Only Scan:**
```sql
SELECT type, amount
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;
```
Index Only Scan using idx_transactions_type_amount
  Index Cond: (type = 'CASH_OUT' AND amount > 100000)
  Heap Fetches: 0
  Buffers: shared hit=920172 read=7200
Execution Time: 385.501 ms
```

**B.3 — Bitmap Heap Scan (pidiendo columna del heap):**
```sql
SELECT type, amount, oldbalance_org
FROM transactions
WHERE type = 'CASH_OUT' AND amount > 100000;
```
Bitmap Heap Scan on transactions
  Recheck Cond: ((type = 'CASH_OUT') AND (amount > 100000))
  Rows Removed by Index Recheck: 1,971,368
  Heap Blocks: exact=44695 lossy=33138
  Buffers: shared hit=7200 read=77833
  ->  Bitmap Index Scan on idx_transactions_type_amount
        Buffers: shared hit=7200
Execution Time: 931.750 ms
```

Cuando todas las columnas del SELECT están en el índice, PostgreSQL ni toca la tabla (Index Only Scan) y es 2.4× más rápido. Pero si pedís una columna que no está indexada (`oldbalance_org`), tiene que ir a la tabla igual y termina siendo lo mismo que sin índice.

---

### C: Bitmap scans

**C.1 —** Buscar montos entre 100 y 10000. Devuelve como 1.27M de filas (~20%).
```sql
SELECT * FROM transactions WHERE amount BETWEEN 100 AND 10000;
```
```
Seq Scan on transactions
  Filter: ((amount >= 100) AND (amount <= 10000))
  Rows Removed by Filter: 5,090,632
  Buffers: shared hit=16235 read=63733
Execution Time: 929.022 ms
```
PostgreSQL usó Seq Scan directamente, sabiamente. Con índice sería un desastre porque tendría que saltar por toda la tabla.

**C.2 —** Buscar `type = 'TRANSFER' OR amount > 800000`.
```sql
SELECT * FROM transactions WHERE type = 'TRANSFER' OR amount > 800000;
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: ((type = 'TRANSFER') OR (amount > 800000))
  Rows Removed by Index Recheck: 2,398,202
  Heap Blocks: exact=39774 lossy=33054
  ->  BitmapOr
        ->  Bitmap Index Scan on idx_transactions_type
              Buffers: shared read=458
        ->  Bitmap Index Scan on idx_transactions_amount
              Buffers: shared hit=1 read=658
Execution Time: 772.709 ms
```
Usó **BitmapOr**: agarró los dos índices, hizo un bitmap de cada uno, los combinó con OR, y leyó el heap una sola vez. Dio 773 ms, mejor que barrer la tabla entera.

---

### D: Cuánto espacio ocupan los índices

```
total_con_indices|1082 MB
solo_tabla|625 MB
solo_indices|457 MB
```

Desglose:
```
idx_transactions_type_amount|235 MB
idx_transactions_amount|180 MB
idx_transactions_type|42 MB
```

O sea, los índices pesan casi 3/4 de lo que pesa la tabla. Y encima `idx_transactions_type` es redundante porque ya existe el compuesto que arranca con `type`. Eliminarlo ahorraría 42 MB.

---

### E: Redundancias

Miramos las estadísticas de uso:

```
idx_transactions_type|2|1065818|0
idx_transactions_type_amount|2|2926862|0
idx_transactions_amount|3|512974|0
```

Después creamos un índice duplicado (`idx_transactions_type_redundant`) a propósito para ver si se podía detectar automáticamente. El método de comparar las definiciones (`indexdef`) **no funcionó** porque los nombres de los índices son parte del texto. La query devolvió 0 filas. Habría que comparar las columnas indexadas con `pg_index.indkey`.

Redundancias que encontramos:
- `idx_transactions_type` es redundante si existe `idx_transactions_type_amount` (porque `(type)` es prefijo de `(type, amount)`)
- El duplicado que creamos también sobra

---

### F: is_fraud — alta selectividad (el mejor resultado)

`is_fraud = true` es solo el **0.13%** de los datos (8,213 filas de 6.3 millones).

| Query | Tiempo | Buffers |
|---|---|---|
| Sin índice | 228 ms | 79,968 |
| **Con índice** | **0.94 ms** | **13** |

**F.1 — Sin índice:**
```sql
SELECT COUNT(*) FROM transactions WHERE is_fraud = true;
```
```
Parallel Seq Scan on transactions
  Filter: is_fraud
  Rows Removed by Filter: 2,118,136
  Buffers: shared hit=16055 read=63913
Execution Time: 228.173 ms
```

**F.2 — Con índice:**
```sql
SELECT COUNT(*) FROM transactions WHERE is_fraud = true;
```
```
Index Only Scan using idx_transactions_fraud on transactions
  Index Cond: (is_fraud = true)
  Heap Fetches: 0
  Buffers: shared hit=3 read=10
Execution Time: 0.937 ms
```

**243 veces más rápido.** Pasamos de leer 80 mil páginas a solo 13. El Index Only Scan responde el COUNT(*) desde el índice nomás, sin tocar la tabla. Esto es exactamente para lo que sirven los índices.

---

### G: Index Scan (cuando necesitás columnas que no están en el índice)

Misma columna `is_fraud`, pero pidiendo `amount`, `oldbalance_org` y `newbalance_orig` que **no están** en el índice de fraude.

| Query | Tiempo | Buffers |
|---|---|---|
| Con índice (Index Scan) | **10.3 ms** | 2,106 |

```sql
SELECT amount, oldbalance_org, newbalance_orig FROM transactions WHERE is_fraud = true;
```
```
Index Scan using idx_transactions_fraud on transactions
  Index Cond: (is_fraud = true)
  Buffers: shared hit=856 read=1250
Execution Time: 10.333 ms
```

Acá PostgreSQL usó Index Scan: leyó el índice para encontrar las 8,213 filas de fraude, y después fue al heap fila por fila a buscar las otras columnas. Igual es 22× más rápido que el Seq Scan (228 ms), porque solo toca las páginas que tienen fraudes.

---

### H: Hash vs B-tree

Probamos ambos tipos de índice para buscar por `name_orig` exacto (`C1305486145`).

| Query | Tipo | Tiempo |
|---|---|---|
| Sin índice | Seq Scan | 228 ms |
| Con Hash | Index Scan | **0.063 ms** |
| Con B-tree | Index Scan | **0.061 ms** |

**H.1 — Sin índice:**
```sql
SELECT * FROM transactions WHERE name_orig = 'C1305486145';
```
```
Parallel Seq Scan on transactions
  Filter: (name_orig = 'C1305486145')
  Rows Removed by Filter: 2,120,873
  Buffers: shared hit=16060 read=63908
Execution Time: 227.770 ms
```

**H.2 — Con Hash:**
```sql
SELECT * FROM transactions WHERE name_orig = 'C1305486145';
```
```
Index Scan using idx_h_name_hash on transactions
  Index Cond: (name_orig = 'C1305486145')
  Buffers: shared hit=2 read=1
Execution Time: 0.063 ms
```

**H.3 — Con B-tree:**
```sql
SELECT * FROM transactions WHERE name_orig = 'C1305486145';
```
```
Index Scan using idx_h_name_hash on transactions
  Index Cond: (name_orig = 'C1305486145')
  Buffers: shared hit=3
Execution Time: 0.061 ms
```

**Tamaños:** Hash: **203 MB**, B-tree: **191 MB**

Son prácticamente lo mismo. Para búsquedas por igualdad exacta dan el mismo resultado. Como el B-tree además sirve para rangos y ordenamiento, no hay mucho sentido en usar Hash.

---

### I: BRIN (Block Range Index)

Probamos BRIN en `step` (que va de 1 a 743 en orden).

| Query | Tiempo | Buffers |
|---|---|---|
| Sin índice | 483 ms | 79,968 |
| **Con BRIN** | **289 ms** | 16,690 |

**I.1 — Sin índice:**
```sql
SELECT * FROM transactions WHERE step BETWEEN 100 AND 200;
```
```
Seq Scan on transactions
  Filter: ((step >= 100) AND (step <= 200))
  Rows Removed by Filter: 5,039,948
  Buffers: shared hit=129 read=79839
Execution Time: 482.729 ms
```

**I.2 — Con BRIN:**
```sql
SELECT * FROM transactions WHERE step BETWEEN 100 AND 200;
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: ((step >= 100) AND (step <= 200))
  Rows Removed by Index Recheck: 3,440
  Heap Blocks: lossy=16672
  Buffers: shared hit=18 read=16672
  ->  Bitmap Index Scan on idx_i_step_brin
        Buffers: shared hit=18
Execution Time: 288.777 ms
```

Y en tamaño:
```
brin|80 kB
btree|42 MB
```

BRIN es 1.7× más rápido y ocupa **80 KB contra 42 MB** del B-tree — 537 veces más chico. Esto funciona porque `step` se inserta en orden, así que los valores cercanos están en páginas cercanas.

**Conclusión:** Para columnas que se insertan en orden (IDs, fechas, logs) BRIN es ideal. Ocupa casi nada y rinde bien.

---

### J: Partial Index (índice parcial)

Creamos un índice solo para las filas donde `is_fraud = true`.

| Query | Tiempo |
|---|---|
| Sin índice parcial (usando idx_transactions_fraud + filter) | 12.4 ms |
| **Con índice parcial** | **1.06 ms** |

**J.1 — Sin índice parcial:**
```sql
SELECT COUNT(*), AVG(amount) FROM transactions WHERE is_fraud = true AND amount > 500000;
```
```
Aggregate
  Buffers: shared hit=338 read=1768
  ->  Index Scan using idx_transactions_fraud on transactions
        Index Cond: (is_fraud = true)
        Filter: (amount > 500000)
        Rows Removed by Filter: 4,349
        Buffers: shared hit=338 read=1768
Execution Time: 12.422 ms
```

**J.2 — Con índice parcial:**
```sql
SELECT COUNT(*), AVG(amount) FROM transactions WHERE is_fraud = true AND amount > 500000;
```
```
Aggregate
  Buffers: shared hit=1129 read=16
  ->  Index Only Scan using idx_j_fraud_amount on transactions
        Index Cond: (amount > 500000)
        Heap Fetches: 0
        Buffers: shared hit=1129 read=16
Execution Time: 1.061 ms
```

Y el tamaño:
```
parcial (is_fraud=true)|264 kB
completo (todos)|180 MB
```

700 veces más chico y 12 veces más rápido. El índice parcial solo indexa las filas que nos interesan (8,213 fraudes), así que ocupa muy poco espacio.

---

### K: Functional Index

Probamos un índice sobre `LOWER(type)` para búsquedas sin importar mayúsculas.

| Query | Tiempo |
|---|---|
| Sin índice | 712 ms (Seq Scan) |
| **Con índice** | **1078 ms** (Bitmap) |

**K.1 — Sin índice funcional:**
```sql
SELECT * FROM transactions WHERE LOWER(type) = 'transfer';
```
```
Parallel Seq Scan on transactions
  Filter: (lower(type) = 'transfer'::text)
  Rows Removed by Filter: 1,943,237
  Buffers: shared hit=16056 read=63912
Execution Time: 711.806 ms
```

**K.2 — Con índice funcional:**
```sql
SELECT * FROM transactions WHERE LOWER(type) = 'transfer';
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: (lower(type) = 'transfer'::text)
  Rows Removed by Index Recheck: 2,399,257
  Heap Blocks: exact=39264 lossy=33053
  Buffers: shared hit=713 read=72062
  ->  Bitmap Index Scan on idx_k_lower_type
        Buffers: shared read=458
Execution Time: 1077.717 ms
```

Otra vez el índice **empeoró** el rendimiento. El problema es el mismo de siempre: `type` tiene 5 valores, la búsqueda devuelve muchas filas, el bitmap es más lento que el Seq Scan. El índice funcional funciona bien, pero si la expresión no es selectiva, no sirve.

---

### L: Covering Index (INCLUDE)

Agregamos `oldbalance_org` al índice con `INCLUDE` para no tener que ir al heap.

| Query | Tiempo |
|---|---|
| Sin covering (Bitmap Heap Scan) | 988 ms |
| **Con covering (Index Only Scan)** | **395 ms** |

**L.1 — Sin covering:**
```sql
SELECT type, amount, oldbalance_org FROM transactions WHERE type = 'CASH_OUT' AND amount > 100000;
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: ((type = 'CASH_OUT') AND (amount > 100000))
  Rows Removed by Index Recheck: 1,971,368
  Heap Blocks: exact=44695 lossy=33138
  Buffers: shared read=85033
  ->  Bitmap Index Scan on idx_transactions_type_amount
        Buffers: shared read=7200
Execution Time: 988.037 ms
```

**L.2 — Con covering:**
```sql
SELECT type, amount, oldbalance_org FROM transactions WHERE type = 'CASH_OUT' AND amount > 100000;
```
```
Index Only Scan using idx_l_covering on transactions
  Index Cond: (type = 'CASH_OUT' AND amount > 100000)
  Heap Fetches: 0
  Buffers: shared hit=920172 read=7892
Execution Time: 395.322 ms
```

2.5× más rápido. El truco es simple: si todas las columnas que pedís están en el índice, PostgreSQL no toca la tabla. Con `INCLUDE` podés meter columnas extras sin que cuenten para el ordenamiento del B-tree.

---

### M: GIN Index (pg_trgm)

Usamos la extensión `pg_trgm` para buscar por patrones con `LIKE '%texto%'` en `name_orig`. Esto es algo que un B-tree no puede hacer.

| Query | Tiempo |
|---|---|
| Sin índice (Seq Scan) | 339 ms |
| **Con GIN** | **6.3 ms** |

**M.1 — Sin índice GIN:**
```sql
SELECT * FROM transactions WHERE name_orig LIKE '%1305486%';
```
```
Parallel Seq Scan on transactions
  Filter: (name_orig ~~ '%1305486%'::text)
  Rows Removed by Filter: 2,120,872
  Buffers: shared hit=8303 read=71665
Execution Time: 339.453 ms
```

**M.2 — Con GIN:**
```sql
SELECT * FROM transactions WHERE name_orig LIKE '%1305486%';
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: (name_orig ~~ '%1305486%'::text)
  Heap Blocks: exact=5
  Buffers: shared hit=119 read=7
  ->  Bitmap Index Scan on idx_m_name_gin
        Buffers: shared hit=119 read=2
Execution Time: 6.315 ms
```

**54 veces más rápido.** Pasamos de leer 80 mil páginas a 126. El índice GIN permite búsquedas en medio del texto, algo que con un B-tree normal es imposible.

---

### N: GiST Index (pg_trgm)

Misma extensión pero con GiST para búsqueda por similitud (operador `%`).

| Query | Índice usado | Tiempo |
|---|---|---|
| Con GIN (el de M) | GIN | 4168 ms |
| **Con GiST** | **GiST** | **1751 ms** |

**N.1 — Con GIN (aún presente de M):**
```sql
SELECT * FROM transactions WHERE name_orig % 'C1305486';
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: (name_orig % 'C1305486')
  Rows Removed by Index Recheck: 2,891,461
  Heap Blocks: exact=46724 lossy=33026
  ->  Bitmap Index Scan on idx_m_name_gin
        Buffers: shared hit=3263 read=72
Execution Time: 4168.219 ms
```

**N.2 — Con GiST:**
```sql
SELECT * FROM transactions WHERE name_orig % 'C1305486';
```
```
Bitmap Heap Scan on transactions
  Recheck Cond: (name_orig % 'C1305486')
  Heap Blocks: exact=5552
  Buffers: shared hit=1797 read=70112
  ->  Bitmap Index Scan on idx_n_name_gist
        Buffers: shared hit=1797 read=64560
Execution Time: 1750.875 ms
```

Tamaños:
```
gin|133 MB
gist|518 MB
```

GiST fue 2.4× más rápido para similitud, pero ocupa 4× más espacio. Para `LIKE '%patrón%'` conviene GIN. Para búsqueda por similitud (palabras parecidas), GiST es mejor.

---

## Resumen de todos los experimentos

| Experimento | Tipo de índice | Sin índice | Con índice | Mejora |
|---|---|---|---|---|
| A (type) | B-tree simple | 242 ms | 324 ms | ❌ peor |
| A (amount) | B-tree simple | 289 ms | 674 ms | ❌ peor |
| B (solo índice) | B-tree compuesto | 927 ms | **386 ms** | ✅ 2.4× |
| B (con heap) | B-tree compuesto | 927 ms | 932 ms | ~ igual |
| C (OR) | BitmapOr | — | **773 ms** | ✅ |
| F (is_fraud) | B-tree | 228 ms | **0.94 ms** | ✅ **243×** |
| G (heap cols) | B-tree | 228 ms | **10.3 ms** | ✅ 22× |
| H (name_orig) | Hash | 228 ms | **0.063 ms** | ✅ ~3600× |
| H (name_orig) | B-tree | 228 ms | **0.061 ms** | ✅ ~3700× |
| I (step) | BRIN | 483 ms | **289 ms** | ✅ 1.7× |
| J (fraud+amount) | Parcial | 12.4 ms | **1.06 ms** | ✅ 12× |
| K (LOWER) | Funcional | 712 ms | 1078 ms | ❌ peor |
| L (covering) | INCLUDE | 988 ms | **395 ms** | ✅ 2.5× |
| M (LIKE) | GIN | 339 ms | **6.3 ms** | ✅ **54×** |
| N (similitud) | GiST | 4168 ms | **1751 ms** | ✅ 2.4× |

---

## Cuánto ocupa cada tipo de índice

| Tipo | Columna | Tamaño | % de la tabla |
|---|---|---|---|
| B-tree (type) | type | 42 MB | 6.7% |
| B-tree (amount) | amount | 180 MB | 28.8% |
| B-tree (type, amount) | type, amount | 235 MB | 37.6% |
| B-tree (step) | step | 42 MB | 6.7% |
| B-tree (name_orig) | name_orig | 191 MB | 30.6% |
| **BRIN** (step) | step | **80 KB** | **0.01%** |
| Hash (name_orig) | name_orig | 203 MB | 32.5% |
| **Parcial** (amount WHERE is_fraud) | amount | **264 KB** | **0.04%** |
| GIN (name_orig trgm) | name_orig | 133 MB | 21.3% |
| GiST (name_orig trgm) | name_orig | 518 MB | 82.9% |

El que menos espacio ocupa es **BRIN** con 80 KB. El que más, **GiST** con 518 MB (más que la propia tabla).

---

## Tipos de scan que vimos

| Scan | Cuándo aparece | Ejemplos |
|---|---|---|
| **Seq Scan** | Muchas filas o no hay índice útil | A, B.1, C.1, H.1, I.1, K.1, M.1 |
| **Bitmap Heap Scan** | Selectividad media, o combinando índices | A.3, A.4, B.3, C.2, I.2, K.2, M.2 |
| **Index Scan** | Pocas filas, pero pido columnas que no están en el índice | G.1, H.2, H.3 |
| **Index Only Scan** | Pocas filas y todo lo que pido está en el índice | B.2, F.2, J.2, L.2 |

---

## Lo que aprendimos

### Cuándo usar cada tipo de índice

- **B-tree:** para casi todo lo común (`=`, `>`, `<`, rangos). El default y el más versátil.
- **Hash:** solo para `=` exacto. Casi no tiene sentido usarlo porque B-tree hace lo mismo.
- **BRIN:** para columnas que se insertan en orden (IDs, fechas). Ocupa muy poco espacio.
- **Parcial:** para consultas que siempre tienen un filtro booleano. Ahorra muchísimo espacio.
- **Funcional:** para buscar por expresiones. Mismas limitaciones que B-tree con selectividad.
- **Covering (INCLUDE):** para evitar ir al heap cuando necesitás columnas extras.
- **GIN:** para buscar texto, JSONB, arrays. Permite cosas que B-tree no puede.
- **GiST:** para geografía, similitud de texto, datos complejos.

### Reglas que nos sirvieron

1. Si tu consulta devuelve más del ~5% de la tabla, **no pongas índice**, empeora.
2. Si filtrás por dos columnas, usá un índice **compuesto**, no dos individuales.
3. Los índices **no siempre ayudan**. A veces son más lentos que barrer la tabla.
4. **Index Only Scan** es lo mejor que te puede pasar: el índice responde todo sin tocar la tabla.
5. Los índices redundantes ocupan espacio al pedo. Si tenés `(A, B)`, no necesitás `(A)` aparte.
6. BRIN es una masa para datos secuenciales: 80 KB vs 42 MB de un B-tree.
7. Los índices parciales son geniales para datos muy desparejos (como fraude que pasa poco).
8. GIN para `LIKE '%algo%'` es la única forma de hacerlo rápido con índices.
9. Hash y B-tree rinden igual para `=`. No te compliques, usá B-tree.

---

Repositorio: [github.com/Zapallo-Code/BDA](https://github.com/Zapallo-Code/BDA)
