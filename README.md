# Instagram

Проект начинается со схемы PostgreSQL для Instagram-подобного приложения.

- SQL-скрипт: [`db/schema.sql`](./db/schema.sql)
- Описание связей и индексов: [`db/README.md`](./db/README.md)

Запуск:

```bash
psql "$DATABASE_URL" -f db/schema.sql
```
