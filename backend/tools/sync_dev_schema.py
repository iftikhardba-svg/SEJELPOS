"""Bring a development SQLite database up to the current models.

    python tools/sync_dev_schema.py real.db

The demo databases (`real.db`, `dev_e2e.db`) are created by `create_all` when
`load_backend.py` or `seed_dev.py` runs, so they carry no alembic stamp and
`alembic upgrade` cannot touch them: it tries to build the schema from nothing
and trips over tables that already exist. They then drift silently — a column
added by a migration is simply absent, and the first request that writes to it
fails deep inside a transaction with "table X has no column named Y".

This adds what is missing: new tables, and new *nullable* columns. It will not
alter or drop anything, and it refuses a column the models require, because
back-filling a NOT NULL column is a decision about data and not a schema
chore — for those, rebuild the database from `load_backend.py`.

Production databases are migrated by alembic and must never go through this.
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.schema import CreateIndex, CreateTable  # noqa: E402

from app.models import Base  # noqa: E402


def main(path: str) -> int:
    if not Path(path).exists():
        print(f"{path}: no such database")
        return 2

    engine = create_engine("sqlite://")  # for DDL compilation only
    conn = sqlite3.connect(path)
    existing = {
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }

    added_tables: list[str] = []
    added_columns: list[str] = []
    refused: list[str] = []
    drifted: list[str] = []

    for table in Base.metadata.sorted_tables:
        if table.name not in existing:
            conn.execute(str(CreateTable(table).compile(engine)))
            for index in table.indexes:
                conn.execute(str(CreateIndex(index).compile(engine)))
            added_tables.append(table.name)
            continue

        info = {row[1]: row for row in conn.execute(
            f"PRAGMA table_info({table.name})")}
        have = set(info)
        # A column whose nullability changed cannot be altered in SQLite — the
        # table has to be rebuilt, which is what alembic's batch mode does.
        # Reported rather than attempted, because rebuilding a table with data
        # in it is a migration, not a chore.
        for column in table.columns:
            row = info.get(column.name)
            if row is None:
                continue
            # SQLite does not set the notnull flag on a PRIMARY KEY column
            # even though it behaves as one, so a PK always looks nullable
            # here. Skip them rather than report a drift that is not real.
            if row[5]:
                continue
            was_required = bool(row[3])
            if was_required and column.nullable:
                drifted.append(
                    f"{table.name}.{column.name} is NOT NULL here but "
                    f"nullable in the models"
                )
            elif not was_required and not column.nullable:
                drifted.append(
                    f"{table.name}.{column.name} is nullable here but "
                    f"required by the models"
                )
        for column in table.columns:
            if column.name in have:
                continue
            if not column.nullable and column.server_default is None:
                refused.append(f"{table.name}.{column.name}")
                continue
            ddl = column.type.compile(engine.dialect)
            default = ""
            if column.server_default is not None:
                default = f" DEFAULT {column.server_default.arg.text}"
            null = "" if column.nullable else " NOT NULL"
            conn.execute(
                f"ALTER TABLE {table.name} "
                f"ADD COLUMN {column.name} {ddl}{null}{default}"
            )
            added_columns.append(f"{table.name}.{column.name}")

        # Indexes are cheap to re-declare and a partial one on a new column is
        # exactly what a drifted database is missing.
        for index in table.indexes:
            try:
                conn.execute(
                    str(CreateIndex(index, if_not_exists=True).compile(engine))
                )
            except sqlite3.OperationalError as e:
                print(f"  index {index.name}: {e}")

    conn.commit()
    conn.close()

    for name in added_tables:
        print(f"+ table  {name}")
    for name in added_columns:
        print(f"+ column {name}")
    for name in refused:
        print(f"! {name} is NOT NULL with no default — rebuild the database")
    for note in drifted:
        print(f"! {note}")
    if drifted:
        print("  SQLite cannot alter a column: stamp this database at the "
              "revision before the change and run `alembic upgrade head`, "
              "which rebuilds the table in batch mode.")
    if not (added_tables or added_columns or refused or drifted):
        print(f"{path} already matches the models")
    return 1 if (refused or drifted) else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
