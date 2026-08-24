"""Atomically persist one already-validated deterministic-router V1 trace."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any, NoReturn


if __package__ in {None, ""}:
    repository_root = str(Path(__file__).resolve().parents[2])
    if repository_root not in sys.path:
        sys.path.insert(0, repository_root)

from router.storage.sqlite_schema import (  # noqa: E402
    SCHEMA_STATEMENTS,
    SCHEMA_VERSION,
    StorageSchemaError,
    expected_schema_snapshot,
    schema_snapshot,
    setup_schema,
)
from router.storage.trace_contract import (  # noqa: E402
    TraceInputError,
    canonical_json,
    load_trace,
    validate_trace,
)


DECISION_COLUMNS = (
    "trace_id",
    "created_at",
    "run_mode",
    "request_profile_json",
    "task_type",
    "domain",
    "complexity",
    "quality_floor",
    "latency_preference",
    "privacy_level",
    "risk_level",
    "output_length",
    "language",
    "additional_capabilities_json",
    "selected_candidate_identity",
    "output_status",
    "reason_code",
    "effective_quality",
    "quality_bottleneck",
    "price",
    "price_final",
    "latency_ms",
    "router_policy_version",
    "profile_schema_version",
    "model_profile_version",
    "pricing_snapshot_date",
    "quality_snapshot_date",
    "calibration_set_version",
    "prompt_hash",
    "response_hash",
    "prompt_content",
    "response_content",
    "candidate_count",
)
CANDIDATE_COLUMNS = (
    "trace_id",
    "candidate_identity",
    "launcher",
    "configuration_id",
    "provider",
    "model",
    "effort",
    "eligible",
    "selected",
    "rejection_stage",
    "rejection_reason_codes_json",
    "requirements_passed",
    "requirements_json",
    "quality_passed",
    "effective_quality",
    "quality_bottleneck",
    "quality_json",
    "price_available",
    "price",
    "price_final",
    "price_json",
    "latency_available",
    "latency_ms",
)
DECISION_INSERT = (
    f"INSERT INTO routing_decisions ({', '.join(DECISION_COLUMNS)}) "
    f"VALUES ({', '.join('?' for _ in DECISION_COLUMNS)})"
)
CANDIDATE_INSERT = (
    f"INSERT INTO candidate_evaluations ({', '.join(CANDIDATE_COLUMNS)}) "
    f"VALUES ({', '.join('?' for _ in CANDIDATE_COLUMNS)})"
)


class StructuredArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise TraceInputError(
            "The trace writer received unsupported command arguments.",
            detail="invalid_arguments",
            code="invalid_arguments",
        )


def decision_parameters(trace: dict[str, Any]) -> tuple[Any, ...]:
    profile = trace["request_profile"]
    return (
        trace["trace_id"],
        trace["created_at"],
        trace["run_mode"],
        canonical_json(profile),
        profile["task_type"],
        profile["domain"],
        profile["complexity"],
        profile["quality_floor"],
        profile["latency"],
        profile["privacy_level"],
        profile["risk_level"],
        profile["output_length"],
        profile["language"],
        canonical_json(profile["additional_capabilities"]),
        trace["selected_candidate"],
        trace["output_status"],
        trace["reason_code"],
        trace["effective_quality"],
        trace["quality_bottleneck"],
        trace["price"],
        int(trace["price_final"]),
        trace["latency_ms"],
        trace["router_policy_version"],
        trace["profile_schema_version"],
        trace["model_profile_version"],
        trace["pricing_snapshot_date"],
        trace["quality_snapshot_date"],
        trace["calibration_set_version"],
        trace["prompt_hash"],
        trace["response_hash"],
        trace["prompt_content"],
        trace["response_content"],
        len(trace["candidate_evaluations"]),
    )


def candidate_parameters(trace_id: str, candidate: dict[str, Any]) -> tuple[Any, ...]:
    requirements = candidate["requirements"]
    quality = candidate["quality"]
    price = candidate["price"]
    return (
        trace_id,
        candidate["candidate_identity"],
        candidate["launcher"],
        candidate["configuration_id"],
        candidate["provider"],
        candidate["model"],
        candidate["effort"],
        int(candidate["eligible"]),
        int(candidate["selected"]),
        candidate["rejection_stage"],
        canonical_json(candidate["rejection_reason_codes"]),
        None if requirements is None else int(requirements["passed"]),
        None if requirements is None else canonical_json(requirements),
        None if quality is None else int(quality["passed"]),
        None if quality is None else quality["effective_quality"],
        None if quality is None else quality["quality_bottleneck"],
        None if quality is None else canonical_json(quality),
        None if price is None else int(price["available"]),
        None if price is None else price["price"],
        None if price is None else int(price["price_final"]),
        None if price is None else canonical_json(price),
        int(candidate["latency_available"]),
        candidate["latency_ms"],
    )


def write_trace(database_path: Path, trace: dict[str, Any]) -> int:
    database_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database_path)
    try:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("BEGIN IMMEDIATE")
        try:
            fresh_schema = setup_schema(connection)
            connection.execute(DECISION_INSERT, decision_parameters(trace))
            rows = [
                candidate_parameters(trace["trace_id"], candidate)
                for candidate in trace["candidate_evaluations"]
            ]
            connection.executemany(CANDIDATE_INSERT, rows)
            if fresh_schema:
                connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            connection.commit()
        except Exception:
            connection.rollback()
            raise
    finally:
        connection.close()
    return len(trace["candidate_evaluations"])


def emit(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":"), ensure_ascii=False) + "\n")


def error_result(error: TraceInputError) -> dict[str, Any]:
    return {
        "ok": False,
        "error": {
            "code": error.code,
            "detail": error.detail,
            "path": error.path,
            "message": error.message,
        },
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    default_database = Path(__file__).resolve().parents[2] / "data" / "router.sqlite"
    parser = StructuredArgumentParser(
        description="Persist one router V1 trace from standard input."
    )
    parser.add_argument("--database", type=Path, default=default_database)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        trace = validate_trace(load_trace(sys.stdin.read()))
        inserted = write_trace(args.database, trace)
    except TraceInputError as error:
        emit(error_result(error))
        return 1
    except StorageSchemaError as error:
        emit({
            "ok": False,
            "error": {
                "code": error.code,
                "detail": error.detail,
                "path": "$",
                "message": error.message,
            },
        })
        return 1
    except sqlite3.IntegrityError:
        emit({
            "ok": False,
            "error": {
                "code": "storage_conflict",
                "detail": "immutable_trace_conflict",
                "path": "$.trace_id",
                "message": "The trace ID already exists or violates an immutable storage constraint.",
            },
        })
        return 1
    except (sqlite3.Error, OSError):
        emit({
            "ok": False,
            "error": {
                "code": "storage_error",
                "detail": "sqlite_write_failed",
                "path": "$",
                "message": "The trace could not be stored.",
            },
        })
        return 1
    except Exception:
        emit({
            "ok": False,
            "error": {
                "code": "internal_error",
                "detail": "unexpected_writer_failure",
                "path": "$",
                "message": "The trace writer failed safely.",
            },
        })
        return 1
    emit({
        "ok": True,
        "trace_id": trace["trace_id"],
        "candidate_evaluations_inserted": inserted,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
