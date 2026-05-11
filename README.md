# BDA — Indexación en PostgreSQL

**Integrantes:** Valentin Rubio, Pablo Geyer, Luciano Castro, Santiago Oses, Santiago Calzolari

## Requisitos

- [Docker](https://docker.com) instalado
- Dataset [PaySim](https://www.kaggle.com/datasets/ealaxi/paysim1) descargado como `paysim.csv` en la raíz del proyecto

## Pasos para levantar el entorno

1. Clonar el repositorio:
   ```bash
   git clone https://github.com/Zapallo-Code/BDA.git
   cd BDA
   ```

2. Crear archivo `.env`:
   ```env
   POSTGRES_USER=postgres
   POSTGRES_PASSWORD=postgres
   POSTGRES_DB=bda
   ```

3. Descargar el dataset de [PaySim en Kaggle](https://www.kaggle.com/datasets/ealaxi/paysim1) y ubicarlo como `paysim.csv` en la raíz del proyecto.

4. Levantar PostgreSQL:
   ```bash
   docker compose up -d
   ```

   Esto ejecuta automáticamente `sql/01-init.sql` que crea la tabla e importa las ~6.36M filas.

## Ejecutar experimentos

### Todos juntos
```bash
./run-experiments.sh
```

### Manualmente (uno por uno)
```bash
docker exec -it bda-postgres psql -U postgres -d bda
```

O ejecutar un experimento específico:
```bash
docker exec -i bda-postgres psql -U postgres -d bda < sql/experimentos/f-alta-selectividad.sql
```

## Informe

Los resultados y conclusiones están en [INFORME.md](./INFORME.md).


