"""Approved SQLite V1 DDL, exact fingerprinting, and version admission."""

from __future__ import annotations

import sqlite3
from typing import Any


SCHEMA_VERSION = 1


class StorageSchemaError(Exception):
    def __init__(self, code: str, detail: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.detail = detail
        self.message = message


SCHEMA_STATEMENTS = (
    """
    CREATE TABLE IF NOT EXISTS routing_decisions (
        trace_id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        run_mode TEXT NOT NULL CHECK (run_mode IN ('normal', 'benchmark', 'calibration')),
        request_profile_json TEXT NOT NULL,
        task_type TEXT NOT NULL,
        domain TEXT NOT NULL,
        complexity TEXT NOT NULL,
        quality_floor TEXT NOT NULL,
        latency_preference TEXT NOT NULL,
        privacy_level TEXT NOT NULL,
        risk_level TEXT NOT NULL,
        output_length TEXT NOT NULL,
        language TEXT NOT NULL,
        additional_capabilities_json TEXT NOT NULL,
        selected_candidate_identity TEXT,
        output_status TEXT NOT NULL,
        reason_code TEXT,
        effective_quality TEXT,
        quality_bottleneck TEXT,
        price TEXT,
        price_final INTEGER NOT NULL CHECK (price_final IN (0, 1)),
        latency_ms REAL,
        router_policy_version TEXT NOT NULL,
        profile_schema_version TEXT NOT NULL,
        model_profile_version TEXT NOT NULL,
        pricing_snapshot_date TEXT NOT NULL,
        quality_snapshot_date TEXT NOT NULL,
        calibration_set_version TEXT NOT NULL,
        prompt_hash TEXT NOT NULL,
        response_hash TEXT,
        prompt_content TEXT,
        response_content TEXT,
        candidate_count INTEGER NOT NULL CHECK (candidate_count >= 0)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS candidate_evaluations (
        trace_id TEXT NOT NULL,
        candidate_identity TEXT NOT NULL,
        launcher TEXT NOT NULL,
        configuration_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        effort TEXT NOT NULL,
        eligible INTEGER NOT NULL CHECK (eligible IN (0, 1)),
        selected INTEGER NOT NULL CHECK (selected IN (0, 1)),
        rejection_stage TEXT,
        rejection_reason_codes_json TEXT NOT NULL,
        requirements_passed INTEGER CHECK (requirements_passed IN (0, 1)),
        requirements_json TEXT,
        quality_passed INTEGER CHECK (quality_passed IN (0, 1)),
        effective_quality TEXT,
        quality_bottleneck TEXT,
        quality_json TEXT,
        price_available INTEGER CHECK (price_available IN (0, 1)),
        price TEXT,
        price_final INTEGER CHECK (price_final IN (0, 1)),
        price_json TEXT,
        latency_available INTEGER NOT NULL CHECK (latency_available IN (0, 1)),
        latency_ms REAL,
        PRIMARY KEY (trace_id, candidate_identity),
        FOREIGN KEY (trace_id) REFERENCES routing_decisions(trace_id) ON DELETE RESTRICT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_routing_decisions_created_at ON routing_decisions(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_routing_decisions_run_mode ON routing_decisions(run_mode)",
    "CREATE INDEX IF NOT EXISTS idx_routing_decisions_output_status ON routing_decisions(output_status)",
    "CREATE INDEX IF NOT EXISTS idx_routing_decisions_selected_candidate ON routing_decisions(selected_candidate_identity)",
    "CREATE INDEX IF NOT EXISTS idx_candidate_evaluations_candidate_identity ON candidate_evaluations(candidate_identity)",
)

SCHEMA_TABLES = ("routing_decisions", "candidate_evaluations")
_EXPECTED_SCHEMA_SNAPSHOT: tuple[Any, ...] | None = None


def schema_snapshot(connection: sqlite3.Connection) -> tuple[Any, ...]:
    objects = tuple(connection.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_schema "
        "WHERE type IN ('table', 'index', 'view', 'trigger') ORDER BY type, name"
    ).fetchall())
    tables: list[tuple[Any, ...]] = []
    for table_name in SCHEMA_TABLES:
        columns = tuple(connection.execute(
            "SELECT * FROM pragma_table_xinfo(?) ORDER BY cid",
            (table_name,),
        ).fetchall())
        foreign_keys = tuple(sorted(
            connection.execute(
                "SELECT * FROM pragma_foreign_key_list(?)",
                (table_name,),
            ).fetchall()
        ))
        indexes: list[tuple[Any, ...]] = []
        index_rows = connection.execute(
            "SELECT * FROM pragma_index_list(?)",
            (table_name,),
        ).fetchall()
        for index_row in index_rows:
            index_name = index_row[1]
            index_columns = tuple(connection.execute(
                "SELECT * FROM pragma_index_info(?) ORDER BY seqno",
                (index_name,),
            ).fetchall())
            indexes.append((index_name, index_row[2], index_row[3], index_row[4], index_columns))
        tables.append((table_name, columns, foreign_keys, tuple(sorted(indexes))))
    return objects, tuple(tables)


def expected_schema_snapshot() -> tuple[Any, ...]:
    global _EXPECTED_SCHEMA_SNAPSHOT
    if _EXPECTED_SCHEMA_SNAPSHOT is None:
        connection = sqlite3.connect(":memory:")
        try:
            connection.execute("PRAGMA foreign_keys = ON")
            for statement in SCHEMA_STATEMENTS:
                connection.execute(statement)
            _EXPECTED_SCHEMA_SNAPSHOT = schema_snapshot(connection)
        finally:
            connection.close()
    return _EXPECTED_SCHEMA_SNAPSHOT


def setup_schema(connection: sqlite3.Connection) -> bool:
    if not connection.in_transaction:
        raise sqlite3.ProgrammingError("Schema setup requires an active trace transaction.")
    current_version = connection.execute("PRAGMA user_version").fetchone()[0]
    if current_version == 0:
        existing_objects = connection.execute(
            "SELECT 1 FROM sqlite_schema LIMIT 1"
        ).fetchone()
        if existing_objects is not None:
            raise StorageSchemaError(
                "schema_migration_required",
                "version_zero_database_not_empty",
                "A nonempty version-0 database requires an explicit migration.",
            )
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)
        if schema_snapshot(connection) != expected_schema_snapshot():
            raise StorageSchemaError(
                "schema_invalid",
                "fresh_schema_creation_mismatch",
                "The exact V1 trace schema could not be created.",
            )
        return True
    if current_version == SCHEMA_VERSION:
        if schema_snapshot(connection) != expected_schema_snapshot():
            raise StorageSchemaError(
                "schema_invalid",
                "version_one_schema_mismatch",
                "The existing version-1 trace schema is not exact.",
            )
        return False
    raise StorageSchemaError(
        "schema_invalid",
        "unsupported_schema_version",
        "The SQLite trace schema version is unsupported.",
    )


__all__ = [
    "SCHEMA_STATEMENTS",
    "SCHEMA_VERSION",
    "StorageSchemaError",
    "expected_schema_snapshot",
    "schema_snapshot",
    "setup_schema",
]
