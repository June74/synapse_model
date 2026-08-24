"""Validate and atomically persist one deterministic-router V1 trace."""

from __future__ import annotations

import argparse
import json
import math
import re
import sqlite3
import sys
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, NoReturn


SCHEMA_VERSION = 1
HEX_HASH = re.compile(r"^[0-9a-fA-F]{64}$")
TRACE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")

RUN_MODES = {"normal", "benchmark", "calibration"}
OUTPUT_STATUSES = {
    "completed",
    "invalid_request",
    "unsupported_request",
    "no_eligible_configuration",
    "execution_failed",
}
FAILURE_REASON_CODES = {
    "unsupported_language",
    "unsupported_modality",
    "sensitive_request_unsupported",
    "high_stakes_unsupported",
    "context_too_large",
    "required_capability_unavailable",
    "quality_floor_not_met",
    "quality_evidence_unknown",
    "all_routes_unavailable",
    "launcher_execution_failed",
}
QUALITY_CATEGORIES = {"standard", "strong", "frontier"}
EVIDENCE_CATEGORIES = QUALITY_CATEGORIES | {"unknown", "unsupported"}
REJECTION_STAGES = {"request_validation", "requirements", "quality", "price"}
CAPABILITIES = {
    "instruction_following",
    "reasoning",
    "structured_output",
    "factual_reliability",
    "source_grounded_synthesis",
    "long_context",
}

FORBIDDEN_FIELD_NAMES = {
    "access_token",
    "api_key",
    "apikey",
    "auth",
    "auth_code",
    "authentication",
    "authentication_code",
    "authorization",
    "authorization_code",
    "bearer_token",
    "cookie",
    "cookies",
    "credential",
    "credentials",
    "env",
    "env_vars",
    "environment",
    "environment_snapshot",
    "environment_variables",
    "password",
    "passphrase",
    "refresh_token",
    "secret",
    "secrets",
    "token",
}

TRACE_FIELDS = {
    "trace_id",
    "created_at",
    "run_mode",
    "request_profile",
    "selected_candidate",
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
    "candidate_evaluations",
}
TRACE_OPTIONAL_FIELDS = {"prompt_content", "response_content"}

REQUEST_REQUIRED_FIELDS = {
    "task_type",
    "domain",
    "complexity",
    "quality_floor",
    "privacy_level",
    "risk_level",
    "language",
}
REQUEST_OPTIONAL_FIELDS = {"latency", "output_length", "additional_capabilities"}

CANDIDATE_FIELDS = {
    "candidate_identity",
    "launcher",
    "configuration_id",
    "provider",
    "model",
    "effort",
    "eligible",
    "selected",
    "rejection_stage",
    "rejection_reason_codes",
    "requirements",
    "quality",
    "price",
    "latency_available",
    "latency_milliseconds",
}

REQUIREMENTS_FIELDS = {
    "candidate_identity",
    "passed",
    "reason_codes",
    "unavailable_capabilities",
    "unsupported_requirements",
}
UNSUPPORTED_REQUIREMENT_FIELDS = {"dimension", "value", "profile_path"}
QUALITY_FIELDS = {
    "candidate_identity",
    "passed",
    "reason_code",
    "effective_quality",
    "quality_bottleneck",
    "relevant_categories",
}
RELEVANT_CATEGORY_FIELDS = {"key", "category"}
PRICE_FIELDS = {
    "candidate_identity",
    "available",
    "reason_code",
    "request_profile_group",
    "estimated_input_tokens",
    "estimated_visible_output_tokens",
    "estimated_reasoning_tokens",
    "estimated_billable_output_tokens",
    "input_usd_per_million_tokens",
    "output_usd_per_million_tokens",
    "price",
    "price_final",
}


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


class TraceInputError(Exception):
    def __init__(
        self,
        message: str,
        *,
        path: str = "$",
        detail: str = "invalid_value",
        code: str = "invalid_trace",
    ) -> None:
        super().__init__(message)
        self.message = message
        self.path = path
        self.detail = detail
        self.code = code


class DuplicateJsonField(ValueError):
    def __init__(self, field_name: str) -> None:
        super().__init__(field_name)
        self.field_name = field_name


class StorageVersionError(Exception):
    pass


class StructuredArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise TraceInputError(
            "The trace writer received unsupported command arguments.",
            detail="invalid_arguments",
            code="invalid_arguments",
        )


def duplicate_safe_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJsonField(key)
        result[key] = value
    return result


def reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"unsupported JSON constant: {value}")


def load_trace(raw_input: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw_input,
            parse_float=Decimal,
            parse_int=int,
            parse_constant=reject_json_constant,
            object_pairs_hook=duplicate_safe_object,
        )
    except DuplicateJsonField as error:
        raise TraceInputError(
            "Duplicate JSON field names are not allowed.",
            path=f"$.{error.field_name}",
            detail="duplicate_json_field",
        ) from None
    except (json.JSONDecodeError, ValueError):
        raise TraceInputError(
            "Standard input must contain exactly one valid JSON value.",
            detail="invalid_json",
        ) from None
    if not isinstance(value, dict):
        raise TraceInputError(
            "The trace input must be one JSON object.",
            detail="root_must_be_object",
        )
    return value


def scan_forbidden_fields(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if key.casefold() in FORBIDDEN_FIELD_NAMES:
                raise TraceInputError(
                    "Secret-bearing, authentication, and environment fields are forbidden.",
                    path=child_path,
                    detail="forbidden_field_name",
                    code="forbidden_field",
                )
            scan_forbidden_fields(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            scan_forbidden_fields(child, f"{path}[{index}]")


def require_exact_fields(
    value: Any,
    required: set[str],
    optional: set[str],
    path: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise TraceInputError("Expected an object.", path=path, detail="wrong_type")
    unknown = sorted(set(value) - required - optional)
    if unknown:
        raise TraceInputError(
            "The object contains an unapproved field.",
            path=f"{path}.{unknown[0]}",
            detail="unknown_field",
        )
    missing = sorted(required - set(value))
    if missing:
        raise TraceInputError(
            "The object is missing a required field.",
            path=f"{path}.{missing[0]}",
            detail="missing_field",
        )
    return value


def require_string(value: Any, path: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise TraceInputError("Expected a non-empty string.", path=path, detail="wrong_type")
    return value


def require_nullable_string(value: Any, path: str) -> str | None:
    if value is None:
        return None
    return require_string(value, path)


def require_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise TraceInputError("Expected a boolean.", path=path, detail="wrong_type")
    return value


def require_enum(value: Any, allowed: set[str], path: str) -> str:
    text = require_string(value, path)
    if text not in allowed:
        raise TraceInputError("Value is not in the approved allowlist.", path=path)
    return text


def require_nullable_enum(value: Any, allowed: set[str], path: str) -> str | None:
    if value is None:
        return None
    return require_enum(value, allowed, path)


def require_string_list(value: Any, path: str, *, allowed: set[str] | None = None) -> list[str]:
    if not isinstance(value, list):
        raise TraceInputError("Expected an array.", path=path, detail="wrong_type")
    result: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        text = require_string(item, f"{path}[{index}]")
        if allowed is not None and text not in allowed:
            raise TraceInputError(
                "Array entry is not in the approved allowlist.", path=f"{path}[{index}]"
            )
        if text in seen:
            raise TraceInputError("Array entries must be unique.", path=f"{path}[{index}]")
        seen.add(text)
        result.append(text)
    return result


def decimal_text(value: Any, path: str, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, (str, int, Decimal)):
        raise TraceInputError(
            "Expected an exact nonnegative decimal number or decimal string.",
            path=path,
            detail="wrong_type",
        )
    if isinstance(value, str) and (not value or value != value.strip()):
        raise TraceInputError("Invalid decimal representation.", path=path)
    try:
        result = Decimal(value)
    except (InvalidOperation, ValueError):
        raise TraceInputError("Invalid decimal representation.", path=path) from None
    if not result.is_finite() or result < 0:
        raise TraceInputError("Decimal values must be finite and nonnegative.", path=path)
    return format(result, "f")


def sqlite_real(value: Any, path: str, *, nullable: bool = False) -> float | None:
    text = decimal_text(value, path, nullable=nullable)
    if text is None:
        return None
    result = float(Decimal(text))
    if not math.isfinite(result):
        raise TraceInputError("Value exceeds SQLite REAL range.", path=path)
    return result


def nonnegative_integer(value: Any, path: str, *, nullable: bool = False) -> int | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise TraceInputError("Expected a nonnegative integer.", path=path, detail="wrong_type")
    return value


def require_hash(value: Any, path: str, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    text = require_string(value, path)
    if HEX_HASH.fullmatch(text) is None:
        raise TraceInputError("Expected a 64-character hexadecimal SHA-256 hash.", path=path)
    return text.lower()


def require_iso_date(value: Any, path: str) -> str:
    text = require_string(value, path)
    try:
        parsed = date.fromisoformat(text)
    except ValueError:
        raise TraceInputError("Expected an ISO calendar date.", path=path) from None
    if parsed.isoformat() != text:
        raise TraceInputError("Expected an exact ISO calendar date.", path=path)
    return text


def require_timestamp(value: Any, path: str) -> str:
    text = require_string(value, path)
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        raise TraceInputError("Expected an RFC 3339 timestamp.", path=path) from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise TraceInputError("Timestamp must include a UTC offset.", path=path)
    return text


def canonical_json(value: Any) -> str:
    def normalize(child: Any) -> Any:
        if isinstance(child, Decimal):
            return format(child, "f")
        if isinstance(child, dict):
            return {key: normalize(item) for key, item in child.items()}
        if isinstance(child, list):
            return [normalize(item) for item in child]
        return child

    return json.dumps(normalize(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def validate_request_profile(value: Any) -> dict[str, Any]:
    profile = require_exact_fields(
        value,
        REQUEST_REQUIRED_FIELDS,
        REQUEST_OPTIONAL_FIELDS,
        "$.request_profile",
    )
    normalized = {
        "task_type": require_enum(
            profile["task_type"],
            {"general", "coding", "math", "reasoning", "writing", "summarization", "extraction", "research_synthesis"},
            "$.request_profile.task_type",
        ),
        "domain": require_enum(
            profile["domain"],
            {"general", "computer_science", "mathematics", "physics", "chemistry", "biology", "medicine", "engineering", "social_science", "humanities", "business", "finance", "law"},
            "$.request_profile.domain",
        ),
        "complexity": require_enum(profile["complexity"], {"low", "medium", "high"}, "$.request_profile.complexity"),
        "quality_floor": require_enum(profile["quality_floor"], QUALITY_CATEGORIES, "$.request_profile.quality_floor"),
        "latency": require_enum(profile.get("latency", "normal"), {"fast", "normal", "relaxed"}, "$.request_profile.latency"),
        "privacy_level": require_enum(profile["privacy_level"], {"standard"}, "$.request_profile.privacy_level"),
        "risk_level": require_enum(profile["risk_level"], {"standard"}, "$.request_profile.risk_level"),
        "output_length": require_enum(profile.get("output_length", "normal"), {"short", "normal", "detailed"}, "$.request_profile.output_length"),
        "language": require_enum(profile["language"], {"english"}, "$.request_profile.language"),
        "additional_capabilities": require_string_list(
            profile.get("additional_capabilities", []),
            "$.request_profile.additional_capabilities",
            allowed=CAPABILITIES,
        ),
    }
    return normalized


def validate_requirements(value: Any, identity: str, path: str) -> dict[str, Any] | None:
    if value is None:
        return None
    requirements = require_exact_fields(value, REQUIREMENTS_FIELDS, set(), path)
    if require_string(requirements["candidate_identity"], f"{path}.candidate_identity") != identity:
        raise TraceInputError("Nested candidate identity does not match.", path=f"{path}.candidate_identity")
    passed = require_bool(requirements["passed"], f"{path}.passed")
    reason_codes = require_string_list(requirements["reason_codes"], f"{path}.reason_codes")
    unavailable = require_string_list(
        requirements["unavailable_capabilities"], f"{path}.unavailable_capabilities"
    )
    unsupported_value = requirements["unsupported_requirements"]
    if not isinstance(unsupported_value, list):
        raise TraceInputError("Expected an array.", path=f"{path}.unsupported_requirements", detail="wrong_type")
    unsupported: list[dict[str, str]] = []
    for index, item in enumerate(unsupported_value):
        item_path = f"{path}.unsupported_requirements[{index}]"
        record = require_exact_fields(item, UNSUPPORTED_REQUIREMENT_FIELDS, set(), item_path)
        unsupported.append({
            name: require_string(record[name], f"{item_path}.{name}")
            for name in ("dimension", "value", "profile_path")
        })
    if passed and reason_codes:
        raise TraceInputError("Passed requirements cannot have failure reasons.", path=f"{path}.reason_codes")
    if not passed and not reason_codes:
        raise TraceInputError("Failed requirements require a reason.", path=f"{path}.reason_codes")
    return {
        "candidate_identity": identity,
        "passed": passed,
        "reason_codes": reason_codes,
        "unavailable_capabilities": unavailable,
        "unsupported_requirements": unsupported,
    }


def validate_quality(value: Any, identity: str, path: str) -> dict[str, Any] | None:
    if value is None:
        return None
    quality = require_exact_fields(value, QUALITY_FIELDS, set(), path)
    if require_string(quality["candidate_identity"], f"{path}.candidate_identity") != identity:
        raise TraceInputError("Nested candidate identity does not match.", path=f"{path}.candidate_identity")
    passed = require_bool(quality["passed"], f"{path}.passed")
    reason_code = require_nullable_string(quality["reason_code"], f"{path}.reason_code")
    effective_quality = require_nullable_enum(
        quality["effective_quality"], QUALITY_CATEGORIES, f"{path}.effective_quality"
    )
    bottleneck = require_nullable_string(quality["quality_bottleneck"], f"{path}.quality_bottleneck")
    categories_value = quality["relevant_categories"]
    if not isinstance(categories_value, list):
        raise TraceInputError("Expected an array.", path=f"{path}.relevant_categories", detail="wrong_type")
    categories: list[dict[str, str]] = []
    for index, item in enumerate(categories_value):
        item_path = f"{path}.relevant_categories[{index}]"
        record = require_exact_fields(item, RELEVANT_CATEGORY_FIELDS, set(), item_path)
        categories.append({
            "key": require_string(record["key"], f"{item_path}.key"),
            "category": require_enum(record["category"], EVIDENCE_CATEGORIES, f"{item_path}.category"),
        })
    if passed and reason_code is not None:
        raise TraceInputError("Passed quality cannot have a failure reason.", path=f"{path}.reason_code")
    if not passed and reason_code is None:
        raise TraceInputError("Failed quality requires a reason.", path=f"{path}.reason_code")
    return {
        "candidate_identity": identity,
        "passed": passed,
        "reason_code": reason_code,
        "effective_quality": effective_quality,
        "quality_bottleneck": bottleneck,
        "relevant_categories": categories,
    }


def validate_price(value: Any, identity: str, path: str) -> dict[str, Any] | None:
    if value is None:
        return None
    price = require_exact_fields(value, PRICE_FIELDS, set(), path)
    if require_string(price["candidate_identity"], f"{path}.candidate_identity") != identity:
        raise TraceInputError("Nested candidate identity does not match.", path=f"{path}.candidate_identity")
    available = require_bool(price["available"], f"{path}.available")
    reason_code = require_nullable_string(price["reason_code"], f"{path}.reason_code")
    profile_group = require_nullable_string(price["request_profile_group"], f"{path}.request_profile_group")
    token_fields = (
        "estimated_input_tokens",
        "estimated_visible_output_tokens",
        "estimated_reasoning_tokens",
        "estimated_billable_output_tokens",
    )
    decimal_fields = (
        "input_usd_per_million_tokens",
        "output_usd_per_million_tokens",
        "price",
    )
    normalized: dict[str, Any] = {
        "candidate_identity": identity,
        "available": available,
        "reason_code": reason_code,
        "request_profile_group": profile_group,
    }
    for name in token_fields:
        normalized[name] = nonnegative_integer(price[name], f"{path}.{name}", nullable=True)
    for name in decimal_fields:
        normalized[name] = decimal_text(price[name], f"{path}.{name}", nullable=True)
    normalized["price_final"] = require_bool(price["price_final"], f"{path}.price_final")
    if available:
        if reason_code is not None:
            raise TraceInputError("Available price cannot have a failure reason.", path=f"{path}.reason_code")
        required_available = ("request_profile_group",) + token_fields + decimal_fields
        for name in required_available:
            if normalized[name] is None:
                raise TraceInputError("Available price is missing metadata.", path=f"{path}.{name}")
    elif reason_code is None:
        raise TraceInputError("Unavailable price requires a reason.", path=f"{path}.reason_code")
    return normalized


def validate_candidate(value: Any, index: int) -> dict[str, Any]:
    path = f"$.candidate_evaluations[{index}]"
    candidate = require_exact_fields(value, CANDIDATE_FIELDS, set(), path)
    identity = require_string(candidate["candidate_identity"], f"{path}.candidate_identity")
    launcher = require_string(candidate["launcher"], f"{path}.launcher")
    configuration_id = require_string(candidate["configuration_id"], f"{path}.configuration_id")
    if identity != f"{launcher}|{configuration_id}":
        raise TraceInputError(
            "Candidate identity must equal launcher|configuration_id.",
            path=f"{path}.candidate_identity",
        )
    eligible = require_bool(candidate["eligible"], f"{path}.eligible")
    selected = require_bool(candidate["selected"], f"{path}.selected")
    rejection_stage = require_nullable_enum(
        candidate["rejection_stage"], REJECTION_STAGES, f"{path}.rejection_stage"
    )
    rejection_reasons = require_string_list(
        candidate["rejection_reason_codes"], f"{path}.rejection_reason_codes"
    )
    requirements = validate_requirements(candidate["requirements"], identity, f"{path}.requirements")
    quality = validate_quality(candidate["quality"], identity, f"{path}.quality")
    price = validate_price(candidate["price"], identity, f"{path}.price")
    latency_available = require_bool(candidate["latency_available"], f"{path}.latency_available")
    latency_ms = sqlite_real(
        candidate["latency_milliseconds"], f"{path}.latency_milliseconds", nullable=True
    )

    if selected and not eligible:
        raise TraceInputError("A selected candidate must be eligible.", path=f"{path}.selected")
    if eligible and (rejection_stage is not None or rejection_reasons):
        raise TraceInputError("Eligible candidates cannot be rejected.", path=f"{path}.rejection_stage")
    if not eligible and (rejection_stage is None or not rejection_reasons):
        raise TraceInputError("Rejected candidates require a stage and reason.", path=f"{path}.rejection_stage")
    if eligible and (requirements is None or not requirements["passed"]):
        raise TraceInputError("Eligible candidates require passed requirements.", path=f"{path}.requirements")
    if eligible and (quality is None or not quality["passed"]):
        raise TraceInputError("Eligible candidates require passed quality.", path=f"{path}.quality")
    if eligible and (price is None or not price["available"]):
        raise TraceInputError("Eligible candidates require an available price.", path=f"{path}.price")
    if latency_available != (latency_ms is not None):
        raise TraceInputError(
            "Latency availability must match latency value presence.",
            path=f"{path}.latency_milliseconds",
        )
    if rejection_stage == "request_validation" and requirements is not None:
        raise TraceInputError("Request-validation rejection must skip requirements.", path=f"{path}.requirements")
    if rejection_stage == "requirements" and (requirements is None or requirements["passed"]):
        raise TraceInputError("Requirements rejection requires a failed evaluation.", path=f"{path}.requirements")
    if rejection_stage == "quality" and (quality is None or quality["passed"]):
        raise TraceInputError("Quality rejection requires a failed evaluation.", path=f"{path}.quality")
    if rejection_stage == "price" and (price is None or price["available"]):
        raise TraceInputError("Price rejection requires an unavailable price.", path=f"{path}.price")

    return {
        "candidate_identity": identity,
        "launcher": launcher,
        "configuration_id": configuration_id,
        "provider": require_string(candidate["provider"], f"{path}.provider"),
        "model": require_string(candidate["model"], f"{path}.model"),
        "effort": require_string(candidate["effort"], f"{path}.effort"),
        "eligible": eligible,
        "selected": selected,
        "rejection_stage": rejection_stage,
        "rejection_reason_codes": rejection_reasons,
        "requirements": requirements,
        "quality": quality,
        "price": price,
        "latency_available": latency_available,
        "latency_ms": latency_ms,
    }


def validate_trace(value: dict[str, Any]) -> dict[str, Any]:
    scan_forbidden_fields(value)
    trace = require_exact_fields(value, TRACE_FIELDS, TRACE_OPTIONAL_FIELDS, "$")
    trace_id = require_string(trace["trace_id"], "$.trace_id")
    if TRACE_ID.fullmatch(trace_id) is None:
        raise TraceInputError("Trace ID has an unsupported format.", path="$.trace_id")
    request_profile = validate_request_profile(trace["request_profile"])
    run_mode = require_enum(trace["run_mode"], RUN_MODES, "$.run_mode")
    prompt_content = trace.get("prompt_content")
    response_content = trace.get("response_content")
    for name, content in (("prompt_content", prompt_content), ("response_content", response_content)):
        if content is not None and not isinstance(content, str):
            raise TraceInputError("Content must be a string or null.", path=f"$.{name}", detail="wrong_type")
        if run_mode == "normal" and content is not None:
            raise TraceInputError("Normal routing cannot store full content.", path=f"$.{name}")

    evaluations_value = trace["candidate_evaluations"]
    if not isinstance(evaluations_value, list):
        raise TraceInputError("Expected an array.", path="$.candidate_evaluations", detail="wrong_type")
    evaluations = [validate_candidate(item, index) for index, item in enumerate(evaluations_value)]
    identities: set[str] = set()
    for index, evaluation in enumerate(evaluations):
        identity = evaluation["candidate_identity"]
        if identity in identities:
            raise TraceInputError(
                "Candidate identities must be unique within a trace.",
                path=f"$.candidate_evaluations[{index}].candidate_identity",
            )
        identities.add(identity)

    output_status = require_enum(trace["output_status"], OUTPUT_STATUSES, "$.output_status")
    reason_code = require_nullable_enum(trace["reason_code"], FAILURE_REASON_CODES, "$.reason_code")
    selected_candidate = require_nullable_string(trace["selected_candidate"], "$.selected_candidate")
    selected_evaluations = [item for item in evaluations if item["selected"]]
    if output_status == "completed":
        if reason_code is not None:
            raise TraceInputError("Completed decisions cannot have a failure reason.", path="$.reason_code")
        if selected_candidate is None or len(selected_evaluations) != 1:
            raise TraceInputError("Completed decisions require exactly one selected evaluation.", path="$.selected_candidate")
    elif reason_code is None:
        raise TraceInputError("Failed decisions require a reason code.", path="$.reason_code")

    if output_status == "execution_failed":
        if selected_candidate is None and selected_evaluations:
            raise TraceInputError("Selected evaluation requires selected_candidate.", path="$.selected_candidate")
        if selected_candidate is not None and len(selected_evaluations) != 1:
            raise TraceInputError("Execution failure selection must be singular.", path="$.selected_candidate")
    elif output_status != "completed" and (selected_candidate is not None or selected_evaluations):
        raise TraceInputError("Pre-selection failures cannot retain a selected candidate.", path="$.selected_candidate")

    if selected_candidate is not None:
        if selected_candidate not in identities:
            raise TraceInputError("Selected candidate was not evaluated.", path="$.selected_candidate")
        if len(selected_evaluations) != 1 or selected_evaluations[0]["candidate_identity"] != selected_candidate:
            raise TraceInputError("Selected candidate does not match selected evaluation.", path="$.selected_candidate")

    effective_quality = require_nullable_enum(
        trace["effective_quality"], QUALITY_CATEGORIES, "$.effective_quality"
    )
    quality_bottleneck = require_nullable_string(trace["quality_bottleneck"], "$.quality_bottleneck")
    top_price = decimal_text(trace["price"], "$.price", nullable=True)
    latency_ms = sqlite_real(trace["latency_ms"], "$.latency_ms", nullable=True)
    response_hash = require_hash(trace["response_hash"], "$.response_hash", nullable=True)
    if output_status == "completed":
        completed_required = (
            (effective_quality, "$.effective_quality"),
            (quality_bottleneck, "$.quality_bottleneck"),
            (top_price, "$.price"),
            (latency_ms, "$.latency_ms"),
            (response_hash, "$.response_hash"),
        )
        for item, path in completed_required:
            if item is None:
                raise TraceInputError("Completed decision metadata cannot be null.", path=path)

    normalized = {
        "trace_id": trace_id,
        "created_at": require_timestamp(trace["created_at"], "$.created_at"),
        "run_mode": run_mode,
        "request_profile": request_profile,
        "selected_candidate": selected_candidate,
        "output_status": output_status,
        "reason_code": reason_code,
        "effective_quality": effective_quality,
        "quality_bottleneck": quality_bottleneck,
        "price": top_price,
        "price_final": require_bool(trace["price_final"], "$.price_final"),
        "latency_ms": latency_ms,
        "router_policy_version": require_string(trace["router_policy_version"], "$.router_policy_version"),
        "profile_schema_version": require_string(trace["profile_schema_version"], "$.profile_schema_version"),
        "model_profile_version": require_string(trace["model_profile_version"], "$.model_profile_version"),
        "pricing_snapshot_date": require_iso_date(trace["pricing_snapshot_date"], "$.pricing_snapshot_date"),
        "quality_snapshot_date": require_iso_date(trace["quality_snapshot_date"], "$.quality_snapshot_date"),
        "calibration_set_version": require_string(trace["calibration_set_version"], "$.calibration_set_version"),
        "prompt_hash": require_hash(trace["prompt_hash"], "$.prompt_hash"),
        "response_hash": response_hash,
        "prompt_content": prompt_content,
        "response_content": response_content,
        "candidate_evaluations": evaluations,
    }
    return normalized


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


def setup_schema(connection: sqlite3.Connection) -> None:
    current_version = connection.execute("PRAGMA user_version").fetchone()[0]
    if current_version not in (0, SCHEMA_VERSION):
        raise StorageVersionError("Unsupported SQLite trace schema version.")
    with connection:
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")


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
        setup_schema(connection)
        with connection:
            connection.execute(DECISION_INSERT, decision_parameters(trace))
            rows = [
                candidate_parameters(trace["trace_id"], candidate)
                for candidate in trace["candidate_evaluations"]
            ]
            connection.executemany(CANDIDATE_INSERT, rows)
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
    parser = StructuredArgumentParser(description="Persist one router V1 trace from standard input.")
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
    except (sqlite3.Error, OSError, StorageVersionError):
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
