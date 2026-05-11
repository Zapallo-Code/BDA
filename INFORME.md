# Informe

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

**Conclusión:** si vas a devolver muchas filas (>5% de la tabla), el índice sobra y hasta molesta.

---

### B: Índice compuesto (type, amount)

Probamos un índice en dos columnas juntas `(type, amount)`.

| Query | Plan | Tiempo |
|---|---|---|
| Sin índice compuesto | Seq Scan | 927 ms |
| Solo columnas del índice | **Index Only Scan** | **386 ms** |
| Con columna  que no está en el índice | Bitmap Heap Scan | 932 ms |

Cuando todas las columnas del SELECT están en el índice, PostgreSQL ni toca la tabla (Index Only Scan) y es 2.4× más rápido. Pero si pedís una columna que no está indexada (`oldbalance_org`), tiene que ir a la tabla igual y termina siendo lo mismo que sin índice.

---

### C: Bitmap scans

**C.1 —** Buscar montos entre 100 y 10000. Devuelve como 1.27M de filas (~20%). PostgreSQL usó Seq Scan directamente, sabiamente. Con índice sería un desastre porque tendría que saltar por toda la tabla.

**C.2 —** Buscar `type = 'TRANSFER' OR amount > 800000`. Usó **BitmapOr**: agarró los dos índices, hizo un bitmap de cada uno, los combinó con OR, y leyó el heap una sola vez. Dio 773 ms, mejor que barrer la tabla entera.

---

### D: Cuánto espacio ocupan los índices

| Componente | Tamaño |
|---|---|
| Tabla sola | 625 MB |
| Con todos los índices | 1,082 MB |
| Solo los índices | **457 MB (73% de la tabla)** |

Desglose:
- `idx_transactions_type_amount` → 235 MB
- `idx_transactions_amount` → 180 MB
- `idx_transactions_type` → 42 MB

O sea, los índices pesan casi 3/4 de lo que pesa la tabla. Y encima `idx_transactions_type` es redundante porque ya existe el compuesto que arranca con `type`. Eliminarlo ahorraría 42 MB.

---

### E: Redundancias

Miramos las estadísticas de uso:

| Índice | Veces usado | Tuplas leídas |
|---|---|---|
| `idx_transactions_type` | 2 | 1,065,818 |
| `idx_transactions_type_amount` | 2 | 2,926,862 |
| `idx_transactions_amount` | 3 | 512,974 |

Después creamos un índice duplicado (`idx_transactions_type_redundant`) a propósito para ver si se podía detectar automáticamente. El método de comparar las definiciones (`indexdef`) **no funcionó** porque los nombres de los índices son parte del texto. Habría que comparar las columnas indexadas con `pg_index.indkey`.

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

**243 veces más rápido.** Pasamos de leer 80 mil páginas a solo 13. El Index Only Scan responde el COUNT(*) desde el índice nomás, sin tocar la tabla. Esto es exactamente para lo que sirven los índices.

---

### G: Index Scan (cuando necesitás columnas que no están en el índice)

Misma columna `is_fraud`, pero pidiendo `amount`, `oldbalance_org` y `newbalance_orig` que **no están** en el índice de fraude.

| Query | Tiempo | Buffers |
|---|---|---|
| Con índice (Index Scan) | **10.3 ms** | 2,106 |

Acá PostgreSQL usó Index Scan: leyó el índice para encontrar las 8,213 filas de fraude, y después fue al heap fila por fila a buscar las otras columnas. Igual es 22× más rápido que el Seq Scan (228 ms), porque solo toca las páginas que tienen fraudes.

---

### H: Hash vs B-tree

Probamos ambos tipos de índice para buscar por `name_orig` exacto (`C1305486145`).

| Query | Tipo | Tiempo |
|---|---|---|
| Sin índice | Seq Scan | 228 ms |
| Con Hash | Index Scan | **0.063 ms** |
| Con B-tree | Index Scan | **0.061 ms** |

Son prácticamente lo mismo. El Hash ocupa 203 MB, el B-tree 191 MB. Para búsquedas por igualdad exacta dan el mismo resultado. Como el B-tree además sirve para rangos y ordenamiento, no hay mucho sentido en usar Hash.

---

### I: BRIN (Block Range Index)

Probamos BRIN en `step` (que va de 1 a 743 en orden).

| Query | Tiempo | Buffers |
|---|---|---|
| Sin índice | 483 ms | 79,968 |
| **Con BRIN** | **289 ms** | 16,690 |

Y en tamaño:

| Índice | Tamaño |
|---|---|
| BRIN | **80 KB** |
| B-tree (para comparar) | **42 MB** |

BRIN es 1.7× más rápido y ocupa **80 KB contra 42 MB** del B-tree — 537 veces más chico. Esto funciona porque `step` se inserta en orden, así que los valores cercanos están en páginas cercanas.

**Conclusión:** Para columnas que se insertan en orden (IDs, fechas, logs) BRIN es ideal. Ocupa casi nada y rinde bien.

---

### J: Partial Index (índice parcial)

Creamos un índice solo para las filas donde `is_fraud = true`.

| Query | Tiempo |
|---|---|
| Sin índice parcial (usando idx_transactions_fraud + filter) | 12.4 ms |
| **Con índice parcial** | **1.06 ms** |

Y el tamaño:

| Índice | Tamaño |
|---|---|
| Parcial (solo fraudes) | **264 KB** |
| Completo (toda la columna amount) | **180 MB** |

700 veces más chico y 12 veces más rápido. El índice parcial solo indexa las filas que nos interesan (8,213 fraudes), así que ocupa muy poco espacio.

---

### K: Functional Index

Probamos un índice sobre `LOWER(type)` para búsquedas sin importar mayúsculas.

| Query | Tiempo |
|---|---|
| Sin índice | 712 ms (Seq Scan) |
| **Con índice** | **1078 ms** (Bitmap) |

Otra vez el índice **empeoró** el rendimiento. El problema es el mismo de siempre: `type` tiene 5 valores, la búsqueda devuelve muchas filas, el bitmap es más lento que el Seq Scan. El índice funcional funciona bien, pero si la expresión no es selectiva, no sirve.

---

### L: Covering Index (INCLUDE)

Agregamos `oldbalance_org` al índice con `INCLUDE` para no tener que ir al heap.

| Query | Tiempo |
|---|---|
| Sin covering (Bitmap Heap Scan) | 988 ms |
| **Con covering (Index Only Scan)** | **395 ms** |

2.5× más rápido. El truco es simple: si todas las columnas que pedís están en el índice, PostgreSQL no toca la tabla. Con `INCLUDE` podés meter columnas extras sin que cuenten para el ordenamiento del B-tree.

---

### M: GIN Index (pg_trgm)

Usamos la extensión `pg_trgm` para buscar por patrones con `LIKE '%texto%'` en `name_orig`. Esto es algo que un B-tree no puede hacer.

| Query | Tiempo |
|---|---|
| Sin índice (Seq Scan) | 339 ms |
| **Con GIN** | **6.3 ms** |

**54 veces más rápido.** Pasamos de leer 80 mil páginas a 126. El índice GIN permite búsquedas en medio del texto, algo que con un B-tree normal es imposible.

---

### N: GiST Index (pg_trgm)

Misma extensión pero con GiST para búsqueda por similitud (operador `%`).

| Query | Índice usado | Tiempo |
|---|---|---|
| Con GIN (el de M) | GIN | 4168 ms |
| **Con GiST** | **GiST** | **1751 ms** |

Tamaños:
- GIN: 133 MB
- GiST: 518 MB

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
