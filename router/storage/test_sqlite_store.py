import copy
import gc
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from router.storage import sqlite_store
from router.storage.sqlite_store import SCHEMA_STATEMENTS, validate_trace, write_trace


STORE_PATH = Path(__file__).with_name("sqlite_store.py")


def candidate(
    identity: str,
    *,
    selected: bool = False,
    rejection_stage: str | None = None,
) -> dict:
    launcher, configuration_id = identity.split("|", 1)
    eligible = rejection_stage is None
    requirements = {
        "candidate_identity": identity,
        "passed": rejection_stage not in {"request_validation", "requirements"},
        "reason_codes": [] if rejection_stage != "requirements" else ["candidate_unavailable"],
        "unavailable_capabilities": [],
        "unsupported_requirements": [],
    }
    quality = None
    price = None
    if requirements["passed"]:
        quality = {
            "candidate_identity": identity,
            "passed": rejection_stage != "quality",
            "reason_code": "quality_floor_not_met" if rejection_stage == "quality" else None,
            "effective_quality": "strong",
            "quality_bottleneck": "task_type.coding",
            "relevant_categories": [
                {"key": "task_type.coding", "category": "strong"},
                {"key": "domain.computer_science", "category": "frontier"},
            ],
        }
    if quality is not None and quality["passed"]:
        price = {
            "candidate_identity": identity,
            "available": rejection_stage != "price",
            "reason_code": "pricing_snapshot_unavailable" if rejection_stage == "price" else None,
            "request_profile_group": "coding|computer_science|medium|normal",
            "estimated_input_tokens": 1536 if rejection_stage != "price" else None,
            "estimated_visible_output_tokens": 512 if rejection_stage != "price" else None,
            "estimated_reasoning_tokens": 256 if rejection_stage != "price" else None,
            "estimated_billable_output_tokens": 768 if rejection_stage != "price" else None,
            "input_usd_per_million_tokens": "1.25" if rejection_stage != "price" else None,
            "output_usd_per_million_tokens": "10.00" if rejection_stage != "price" else None,
            "price": "0.0096000000000000000000000001" if rejection_stage != "price" else None,
            "price_final": False,
        }
        if selected:
            price["price"] = "0.1234567890123456789012345678"
            price["price_final"] = True
    return {
        "candidate_identity": identity,
        "launcher": launcher,
        "configuration_id": configuration_id,
        "provider": "openai" if launcher == "codex" else "google",
        "model": f"{launcher}-model",
        "effort": "medium",
        "eligible": eligible,
        "selected": selected,
        "rejection_stage": rejection_stage,
        "rejection_reason_codes": [] if eligible else [
            {
                "request_validation": "request_validation_failed",
                "requirements": "candidate_unavailable",
                "quality": "quality_floor_not_met",
                "price": "pricing_snapshot_unavailable",
            }[rejection_stage]
        ],
        "requirements": None if rejection_stage == "request_validation" else requirements,
        "quality": quality,
        "price": price,
        "latency_available": eligible,
        "latency_milliseconds": "275.125" if eligible else None,
    }


def complete_trace(trace_id: str = "trace-0001", run_mode: str = "normal") -> dict:
    prompt_content = None
    response_content = None
    if run_mode != "normal":
        prompt_content = "Reproduce benchmark case; the word api_key here is ordinary prompt text."
        response_content = "A reproducible benchmark output."
    return {
        "trace_id": trace_id,
        "created_at": "2026-08-24T03:30:00Z",
        "run_mode": run_mode,
        "request_profile": {
            "task_type": "coding",
            "domain": "computer_science",
            "complexity": "medium",
            "quality_floor": "strong",
            "latency": "normal",
            "privacy_level": "standard",
            "risk_level": "standard",
            "output_length": "normal",
            "language": "english",
            "additional_capabilities": ["reasoning", "structured_output"],
        },
        "selected_candidate": "codex|gpt-test__medium",
        "output_status": "completed",
        "reason_code": None,
        "effective_quality": "strong",
        "quality_bottleneck": "task_type.coding",
        "price": "0.1234567890123456789012345678",
        "price_final": True,
        "latency_ms": "421.875",
        "router_policy_version": "policy-v1",
        "profile_schema_version": "router-model-profile/v1",
        "model_profile_version": "catalog-2026-08-24",
        "pricing_snapshot_date": "2026-08-22",
        "quality_snapshot_date": "2026-08-22",
        "calibration_set_version": "calibration-set-v1",
        "prompt_hash": "A" * 64,
        "response_hash": "B" * 64,
        "prompt_content": prompt_content,
        "response_content": response_content,
        "candidate_evaluations": [
            candidate("codex|gpt-test__medium", selected=True),
            candidate("agy|gemini-test__high", rejection_stage="quality"),
            candidate("claude|claude-test__medium", rejection_stage="requirements"),
        ],
    }


def failure_trace(evaluation: dict, trace_id: str = "failure-trace") -> dict:
    trace = complete_trace(trace_id)
    trace.update({
        "selected_candidate": None,
        "output_status": "no_eligible_configuration",
        "reason_code": "all_routes_unavailable",
        "effective_quality": None,
        "quality_bottleneck": None,
        "price": None,
        "price_final": False,
        "latency_ms": None,
        "response_hash": None,
        "candidate_evaluations": [evaluation],
    })
    return trace


class SQLiteStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.database_path = Path(self.temp_dir.name) / "router.sqlite"

    def run_raw(self, raw_input: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        self.assertTrue(STORE_PATH.is_file(), f"SQLite writer is missing: {STORE_PATH}")
        result = subprocess.run(
            [sys.executable, str(STORE_PATH), "--database", str(self.database_path)],
            input=raw_input,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.stderr, "", result.stderr)
        try:
            output = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            self.fail(f"writer stdout was not one JSON object: {error}: {result.stdout!r}")
        return result, output

    def write(self, trace: dict) -> tuple[subprocess.CompletedProcess[str], dict]:
        return self.run_raw(json.dumps(trace, separators=(",", ":")))

    def rows(self, sql: str, parameters: tuple = ()) -> list[tuple]:
        connection = sqlite3.connect(self.database_path)
        try:
            return connection.execute(sql, parameters).fetchall()
        finally:
            connection.close()

    def create_exact_v1_schema(self) -> None:
        connection = sqlite3.connect(self.database_path)
        try:
            for statement in SCHEMA_STATEMENTS:
                connection.execute(statement)
            connection.execute("PRAGMA user_version = 1")
            connection.commit()
        finally:
            connection.close()

    def user_schema_objects(self) -> list[tuple]:
        return self.rows(
            "SELECT type, name, tbl_name, sql FROM sqlite_schema "
            "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
        )

    def assert_invalid(self, trace: dict, code: str = "invalid_trace") -> dict:
        result, output = self.write(trace)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["ok"], False)
        self.assertEqual(output["error"]["code"], code)
        return output

    def test_creates_only_v1_schema_and_approved_indexes(self) -> None:
        result, output = self.write(complete_trace())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(output, {
            "ok": True,
            "trace_id": "trace-0001",
            "candidate_evaluations_inserted": 3,
        })

        objects = self.rows(
            "SELECT type, name FROM sqlite_master "
            "WHERE name NOT LIKE 'sqlite_autoindex%' ORDER BY type, name"
        )
        self.assertEqual(objects, [
            ("index", "idx_candidate_evaluations_candidate_identity"),
            ("index", "idx_routing_decisions_created_at"),
            ("index", "idx_routing_decisions_output_status"),
            ("index", "idx_routing_decisions_run_mode"),
            ("index", "idx_routing_decisions_selected_candidate"),
            ("table", "candidate_evaluations"),
            ("table", "routing_decisions"),
        ])
        self.assertEqual(self.rows("PRAGMA user_version"), [(1,)])
        foreign_keys = self.rows("PRAGMA foreign_key_list(candidate_evaluations)")
        self.assertEqual(len(foreign_keys), 1)
        self.assertEqual(foreign_keys[0][2:5], ("routing_decisions", "trace_id", "trace_id"))

    def test_partial_version_zero_database_is_rejected_without_mutation(self) -> None:
        connection = sqlite3.connect(self.database_path)
        try:
            connection.execute("CREATE TABLE legacy_trace (id INTEGER PRIMARY KEY)")
            connection.execute("INSERT INTO legacy_trace (id) VALUES (?)", (1,))
            connection.commit()
        finally:
            connection.close()
        before_bytes = self.database_path.read_bytes()
        before_objects = self.user_schema_objects()

        result, output = self.write(complete_trace("partial-v0"))

        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["error"]["code"], "schema_migration_required")
        self.assertEqual(self.database_path.read_bytes(), before_bytes)
        self.assertEqual(self.user_schema_objects(), before_objects)
        self.assertEqual(self.rows("PRAGMA user_version"), [(0,)])

    def test_malformed_version_one_database_is_rejected_without_mutation(self) -> None:
        self.create_exact_v1_schema()
        connection = sqlite3.connect(self.database_path)
        try:
            connection.execute("DROP INDEX idx_routing_decisions_run_mode")
            connection.commit()
        finally:
            connection.close()
        before_bytes = self.database_path.read_bytes()
        before_objects = self.user_schema_objects()

        result, output = self.write(complete_trace("malformed-v1"))

        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["error"]["code"], "schema_invalid")
        self.assertEqual(self.database_path.read_bytes(), before_bytes)
        self.assertEqual(self.user_schema_objects(), before_objects)
        self.assertEqual(self.rows("PRAGMA user_version"), [(1,)])

    def test_version_one_database_with_extra_object_is_rejected_without_mutation(self) -> None:
        self.create_exact_v1_schema()
        connection = sqlite3.connect(self.database_path)
        try:
            connection.execute("CREATE VIEW unapproved_trace_view AS SELECT trace_id FROM routing_decisions")
            connection.commit()
        finally:
            connection.close()
        before_bytes = self.database_path.read_bytes()
        before_objects = self.user_schema_objects()

        result, output = self.write(complete_trace("extra-v1-object"))

        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["error"]["code"], "schema_invalid")
        self.assertEqual(self.database_path.read_bytes(), before_bytes)
        self.assertEqual(self.user_schema_objects(), before_objects)

    def test_unsupported_schema_version_is_rejected_without_mutation(self) -> None:
        connection = sqlite3.connect(self.database_path)
        try:
            connection.execute("PRAGMA user_version = 2")
            connection.commit()
        finally:
            connection.close()
        before_bytes = self.database_path.read_bytes()

        result, output = self.write(complete_trace("unsupported-v2"))

        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["error"]["code"], "schema_invalid")
        self.assertEqual(output["error"]["detail"], "unsupported_schema_version")
        self.assertEqual(self.database_path.read_bytes(), before_bytes)
        self.assertEqual(self.rows("PRAGMA user_version"), [(2,)])

    def test_exact_version_one_schema_is_accepted_idempotently(self) -> None:
        self.create_exact_v1_schema()
        before_objects = self.user_schema_objects()

        result, output = self.write(complete_trace("exact-v1"))

        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(self.user_schema_objects(), before_objects)
        self.assertEqual(self.rows("PRAGMA user_version"), [(1,)])

    def test_fresh_schema_and_first_write_roll_back_together(self) -> None:
        trace = validate_trace(complete_trace("atomic-schema-write"))
        with mock.patch.object(
            sqlite_store,
            "CANDIDATE_INSERT",
            "INSERT INTO missing_candidate_table (trace_id) VALUES (?)",
        ):
            with self.assertRaises(sqlite3.Error):
                write_trace(self.database_path, trace)

        self.assertEqual(self.user_schema_objects(), [])
        self.assertEqual(self.rows("PRAGMA user_version"), [(0,)])

    def test_one_transaction_stores_decision_and_every_candidate(self) -> None:
        self.write(complete_trace())
        decision = self.rows(
            "SELECT selected_candidate_identity, output_status, candidate_count, "
            "task_type, quality_floor FROM routing_decisions"
        )
        self.assertEqual(decision, [
            ("codex|gpt-test__medium", "completed", 3, "coding", "strong")
        ])
        evaluations = self.rows(
            "SELECT candidate_identity, selected, rejection_stage "
            "FROM candidate_evaluations ORDER BY candidate_identity"
        )
        self.assertEqual(evaluations, [
            ("agy|gemini-test__high", 0, "quality"),
            ("claude|claude-test__medium", 0, "requirements"),
            ("codex|gpt-test__medium", 1, None),
        ])

    def test_stores_versions_normalized_hashes_and_exact_price_text(self) -> None:
        self.write(complete_trace())
        stored = self.rows(
            "SELECT router_policy_version, profile_schema_version, model_profile_version, "
            "pricing_snapshot_date, quality_snapshot_date, calibration_set_version, "
            "prompt_hash, response_hash, price, price_final, latency_ms "
            "FROM routing_decisions"
        )
        self.assertEqual(stored, [(
            "policy-v1",
            "router-model-profile/v1",
            "catalog-2026-08-24",
            "2026-08-22",
            "2026-08-22",
            "calibration-set-v1",
            "a" * 64,
            "b" * 64,
            "0.1234567890123456789012345678",
            1,
            421.875,
        )])

    def test_benchmark_and_calibration_modes_store_optional_content(self) -> None:
        for index, run_mode in enumerate(("benchmark", "calibration"), start=1):
            trace = complete_trace(f"trace-content-{index}", run_mode)
            result, output = self.write(trace)
            self.assertEqual(result.returncode, 0, output)
        stored = self.rows(
            "SELECT run_mode, prompt_content, response_content "
            "FROM routing_decisions ORDER BY run_mode"
        )
        self.assertEqual(stored, [
            (
                "benchmark",
                "Reproduce benchmark case; the word api_key here is ordinary prompt text.",
                "A reproducible benchmark output.",
            ),
            (
                "calibration",
                "Reproduce benchmark case; the word api_key here is ordinary prompt text.",
                "A reproducible benchmark output.",
            ),
        ])

    def test_normal_mode_rejects_full_content_and_inserts_nothing(self) -> None:
        trace = complete_trace()
        trace["prompt_content"] = "must not be stored"
        output = self.assert_invalid(trace)
        self.assertEqual(output["error"]["path"], "$.prompt_content")
        self.assertFalse(self.database_path.exists())

    def test_malformed_candidate_rolls_back_entire_trace(self) -> None:
        self.write(complete_trace("seed-trace"))
        malformed = complete_trace("malformed-trace")
        del malformed["candidate_evaluations"][1]["launcher"]
        self.assert_invalid(malformed)
        self.assertEqual(self.rows("SELECT trace_id FROM routing_decisions"), [("seed-trace",)])
        self.assertEqual(self.rows(
            "SELECT COUNT(*) FROM candidate_evaluations WHERE trace_id = ?",
            ("malformed-trace",),
        ), [(0,)])

    def test_duplicate_trace_sql_error_rolls_back_without_mutating_history(self) -> None:
        self.write(complete_trace())
        duplicate = complete_trace()
        duplicate["candidate_evaluations"] = duplicate["candidate_evaluations"][:1]
        result, output = self.write(duplicate)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output["error"]["code"], "storage_conflict")
        self.assertEqual(self.rows(
            "SELECT candidate_count FROM routing_decisions WHERE trace_id = 'trace-0001'"
        ), [(3,)])
        self.assertEqual(self.rows(
            "SELECT COUNT(*) FROM candidate_evaluations WHERE trace_id = 'trace-0001'"
        ), [(3,)])

    def test_rejects_non_object_multiple_objects_unknown_fields_and_duplicate_json_keys(self) -> None:
        cases = [
            (json.dumps([complete_trace()]), "root_must_be_object"),
            (json.dumps(complete_trace()) + json.dumps(complete_trace("trace-0002")), "invalid_json"),
            (json.dumps({**complete_trace(), "unexpected": True}), "unknown_field"),
            ('{"trace_id":"one","trace_id":"two"}', "duplicate_json_field"),
        ]
        for raw_input, expected_detail in cases:
            with self.subTest(expected_detail=expected_detail):
                result, output = self.run_raw(raw_input)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(output["ok"], False)
                self.assertEqual(output["error"]["detail"], expected_detail)

    def test_invalid_writer_arguments_return_only_structured_diagnostics(self) -> None:
        result = subprocess.run(
            [sys.executable, str(STORE_PATH), "--unsupported-argument"],
            input=json.dumps(complete_trace()),
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")
        output = json.loads(result.stdout)
        self.assertEqual(output["ok"], False)
        self.assertEqual(output["error"]["code"], "invalid_arguments")

    def test_rejects_duplicate_candidate_identity_and_inconsistent_selection(self) -> None:
        duplicate = complete_trace()
        duplicate["candidate_evaluations"][1]["candidate_identity"] = duplicate[
            "candidate_evaluations"
        ][0]["candidate_identity"]
        self.assert_invalid(duplicate)

        missing_selection = complete_trace("missing-selection")
        missing_selection["candidate_evaluations"][0]["selected"] = False
        self.assert_invalid(missing_selection)

        wrong_selection = complete_trace("wrong-selection")
        wrong_selection["selected_candidate"] = "agy|gemini-test__high"
        self.assert_invalid(wrong_selection)

    def test_eligible_candidate_requires_complete_passing_evaluations(self) -> None:
        cases = (
            ("requirements", None),
            ("quality", None),
            ("price", None),
        )
        for field_name, invalid_value in cases:
            with self.subTest(field_name=field_name):
                trace = complete_trace(f"incomplete-eligible-{field_name}")
                trace["candidate_evaluations"][0][field_name] = invalid_value
                self.assert_invalid(trace)

    def test_candidate_stage_transitions_are_accepted_in_order(self) -> None:
        for index, stage in enumerate(("requirements", "quality", "price"), start=1):
            with self.subTest(stage=stage):
                trace = failure_trace(
                    candidate(f"stage{index}|configuration", rejection_stage=stage),
                    f"valid-{stage}-rejection",
                )
                result, output = self.write(trace)
                self.assertEqual(result.returncode, 0, output)

    def test_requirements_failure_cannot_reject_at_a_later_stage(self) -> None:
        for index, later_stage in enumerate(("quality", "price"), start=1):
            with self.subTest(later_stage=later_stage):
                evaluation = candidate(
                    f"requirements-later-{index}|configuration",
                    rejection_stage=later_stage,
                )
                evaluation["requirements"]["passed"] = False
                evaluation["requirements"]["reason_codes"] = ["candidate_unavailable"]
                trace = failure_trace(evaluation, f"requirements-before-{later_stage}")
                self.assert_invalid(trace)

    def test_quality_failure_cannot_reject_at_price(self) -> None:
        evaluation = candidate("quality-before-price|configuration", rejection_stage="price")
        evaluation["quality"]["passed"] = False
        evaluation["quality"]["reason_code"] = "quality_floor_not_met"
        trace = failure_trace(evaluation, "quality-before-price")

        self.assert_invalid(trace)

    def test_null_earlier_stage_cannot_reach_price_rejection(self) -> None:
        for index, field_name in enumerate(("requirements", "quality"), start=1):
            with self.subTest(field_name=field_name):
                evaluation = candidate(
                    f"null-before-price-{index}|configuration",
                    rejection_stage="price",
                )
                evaluation[field_name] = None
                trace = failure_trace(evaluation, f"null-{field_name}-before-price")
                self.assert_invalid(trace)

    def test_unavailable_price_cannot_be_eligible_or_selected(self) -> None:
        trace = complete_trace("selected-without-price")
        selected = trace["candidate_evaluations"][0]
        selected["price"].update({
            "available": False,
            "reason_code": "pricing_snapshot_unavailable",
            "request_profile_group": None,
            "estimated_input_tokens": None,
            "estimated_visible_output_tokens": None,
            "estimated_reasoning_tokens": None,
            "estimated_billable_output_tokens": None,
            "input_usd_per_million_tokens": None,
            "output_usd_per_million_tokens": None,
            "price": None,
            "price_final": False,
        })

        self.assert_invalid(trace)

    def test_completed_winner_quality_must_match_selected_evaluation(self) -> None:
        cases = (
            ("effective_quality", "frontier"),
            ("quality_bottleneck", "domain.computer_science"),
        )
        for index, (field_name, value) in enumerate(cases, start=1):
            with self.subTest(field_name=field_name):
                trace = complete_trace(f"winner-quality-mismatch-{index}")
                trace[field_name] = value
                self.assert_invalid(trace)

    def test_completed_winner_price_and_finality_must_match_selected_evaluation(self) -> None:
        cases = (
            ("price", "0.1234567890123456789012345679"),
            ("price_final", False),
        )
        for index, (field_name, value) in enumerate(cases, start=1):
            with self.subTest(field_name=field_name):
                trace = complete_trace(f"winner-price-mismatch-{index}")
                trace[field_name] = value
                self.assert_invalid(trace)

    def test_failure_traces_have_no_winner_or_winner_quality(self) -> None:
        valid_failure = failure_trace(
            candidate("failed|configuration", rejection_stage="requirements"),
            "valid-failure",
        )
        result, output = self.write(valid_failure)
        self.assertEqual(result.returncode, 0, output)

        retained_winner = complete_trace("failure-retained-winner")
        retained_winner.update({
            "output_status": "execution_failed",
            "reason_code": "launcher_execution_failed",
            "response_hash": None,
        })
        self.assert_invalid(retained_winner)

        retained_quality = copy.deepcopy(valid_failure)
        retained_quality["trace_id"] = "failure-retained-quality"
        retained_quality["effective_quality"] = "strong"
        retained_quality["quality_bottleneck"] = "task_type.coding"
        self.assert_invalid(retained_quality)

    def test_hash_validation_and_normalization(self) -> None:
        trace = complete_trace()
        trace["prompt_hash"] = "ABC"
        output = self.assert_invalid(trace)
        self.assertEqual(output["error"]["path"], "$.prompt_hash")

    def test_forbidden_secret_or_environment_field_name_is_rejected_anywhere(self) -> None:
        trace = complete_trace()
        trace["candidate_evaluations"][0]["requirements"]["api_key"] = "not-stored"
        output = self.assert_invalid(trace, code="forbidden_field")
        self.assertEqual(output["error"]["path"], "$.candidate_evaluations[0].requirements.api_key")
        self.assertFalse(self.database_path.exists())

    def test_idempotent_schema_setup_allows_additional_immutable_traces(self) -> None:
        self.write(complete_trace("trace-one"))
        self.write(complete_trace("trace-two"))
        self.assertEqual(self.rows(
            "SELECT trace_id FROM routing_decisions ORDER BY trace_id"
        ), [("trace-one",), ("trace-two",)])

    def test_direct_writer_closes_the_database_connection(self) -> None:
        write_trace(self.database_path, validate_trace(complete_trace("direct-write")))

        try:
            self.database_path.unlink()
        except PermissionError:
            gc.collect()
            self.fail("write_trace returned while its SQLite connection was still open")
        self.assertFalse(self.database_path.exists())


if __name__ == "__main__":
    unittest.main()
