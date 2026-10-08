# CTE Explained: From Beginner to Advanced

[![Test SQL solutions](https://github.com/Amollo1/cte-explained-beginner-to-advanced/actions/workflows/test.yml/badge.svg)](https://github.com/Amollo1/cte-explained-beginner-to-advanced/actions/workflows/test.yml)

A hands-on, **PostgreSQL** course on Common Table Expressions (`WITH` queries), from your first CTE to recursive hierarchies, graph traversal and data-modifying queries.

Every lesson has runnable examples, exercises with self-checks, and **solutions that are tested automatically** against a real PostgreSQL server on every push.

## Who this is for

Analysts, data engineers, BI developers and developers who already write basic SQL (`SELECT`, `JOIN`, `GROUP BY`) and want to write clearer, more maintainable, production-quality queries.

## Quick start

```bash
git clone https://github.com/Amollo1/cte-explained-beginner-to-advanced.git
cd cte-explained-beginner-to-advanced

docker compose up -d                                   # PostgreSQL 16 + practice data
docker compose exec db psql -U postgres -d cte_lab     # open a SQL prompt
```

No Docker? Install PostgreSQL 14+ and run:

```bash
createdb cte_lab
psql -d cte_lab -f data/schema_and_data.sql
```

Then open [`00-setup/lesson.md`](00-setup/lesson.md) and follow the roadmap below in order.

## Roadmap

| # | Module | Level | You will learn | Status |
|---|---|---|---|---|
| 0 | [Setup & SQL Refresher](00-setup/lesson.md) | Beginner | Environment, dataset tour, joins, grouping, subqueries | Available |
| 1 | [What Is a CTE?](01-what-is-a-cte/lesson.md) | Beginner | Definition, `WITH` syntax, scope, readability | Available |
| 2 | [CTE vs Subquery vs View vs Temp Table](02-cte-vs-alternatives/lesson.md) | Beginner | Choosing the right tool, reuse, materialized views | Available |
| 3 | [Multiple & Chained CTEs](03-chained-ctes/lesson.md) | Beginner | Pipelines, grain, joining CTEs, anti-joins | Available |
| 4 | [CTEs for Aggregation & Joins](04-aggregation-patterns/lesson.md) | Intermediate | Pre-aggregation, the fan-out trap, `FILTER`, reconciliation, cohorts | Available |
| 5 | CTEs + Window Functions | Intermediate | Top-N per group, running totals, `LAG` | Planned |
| 6 | Data Cleaning & Deduplication | Intermediate | Normalising, dedup, data-quality profiling | Planned |
| 7 | Materialization & the Optimizer | Advanced | `MATERIALIZED`, predicate pushdown, `EXPLAIN ANALYZE` | Planned |
| 8 | Recursive CTE Fundamentals | Intermediate | Anchor and recursive members, series, termination | Planned |
| 9 | Hierarchies: Org Charts & Category Trees | Advanced | Depth, paths, breadcrumbs, roll-ups | Planned |
| 10 | Graphs, Cycles & `SEARCH`/`CYCLE` | Advanced | Path enumeration, cycle safety, PG 14+ clauses | Planned |
| 11 | Bill of Materials & Roll-ups | Advanced | Quantity explosion, cost roll-up, where-used | Planned |
| 12 | Data-Modifying CTEs | Advanced | `INSERT`/`UPDATE`/`DELETE ... RETURNING`, archive and audit patterns | Planned |
| 13 | Performance, Best Practices & Anti-Patterns | Advanced | Refactoring, indexing, alternatives (`ltree`, closure tables) | Planned |
| 14 | Capstone Portfolio Projects | Advanced | Four end-to-end projects | Planned |

The full plan (57 exercises, estimated hours, dataset map) is in [`docs/CTE_Explained_Beginner_to_Advanced.xlsx`](docs/CTE_Explained_Beginner_to_Advanced.xlsx).

## How each module is organised

```
NN-module-name/
├── lesson.md        concept, analogy, worked examples, common mistakes, checkpoint
├── examples.sql     every example from the lesson, runnable
├── exercises.md     tasks with self-checks and hints (no answers)
├── NN-01.sql        solution to exercise 1
├── NN-01.expected   expected output, used by the test runner
└── ...
```

## Practice dataset

`data/schema_and_data.sql` creates a small, **fully synthetic** dataset (employees with a manager hierarchy, a shop with orders, a category tree, a city graph with cycles, a bicycle bill of materials, and a deliberately messy customer table). Each table exists to teach a specific idea; see the dataset tour in Module 0.

## Run the tests yourself

```bash
export PGPASSWORD=postgres            # password used by docker-compose.yml
./scripts/run_all.sh                  # runs every example and checks every solution
```

The runner executes each `examples.sql` (must succeed) and each solution `NN-NN.sql` (must succeed **and** match its `.expected` file). GitHub Actions runs the same script against PostgreSQL 14, 16 and 17.

## Requirements

- PostgreSQL **14 or newer** (`MATERIALIZED` hints need 12, `SEARCH`/`CYCLE` need 14)
- `psql` and `bash` for the test runner
- Docker (optional, recommended)

## Contributing

Found an error or have a better solution? Open an issue or pull request. Please keep every solution deterministic (explicit `ORDER BY`) and run `./scripts/run_all.sh` before submitting.

## License

[MIT](LICENSE). All data is synthetic and contains no real people or companies.
