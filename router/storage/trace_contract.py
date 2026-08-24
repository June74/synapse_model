"""Top-level V1 trace shape, safety, and internal-consistency admission."""

from __future__ import annotations

from typing import Any

from router.storage.candidate_contract import QUALITY_CATEGORIES, validate_candidate, validate_request_profile
from router.storage.contract_support import (
    TRACE_ID,
    TraceInputError,
    canonical_json,
    decimal_text,
    load_trace,
    reject_high_confidence_credential_content,
    require_bool,
    require_enum,
    require_exact_fields,
    require_hash,
    require_iso_date,
    require_nullable_enum,
    require_nullable_string,
    require_string,
    require_timestamp,
    scan_forbidden_fields,
    sha256_utf8,
    sqlite_real,
)


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
STATUS_REASON_CODES = {
    "invalid_request": {
        "unsupported_language",
        "unsupported_modality",
        "sensitive_request_unsupported",
        "high_stakes_unsupported",
    },
    "unsupported_request": {
        "unsupported_language",
        "unsupported_modality",
        "sensitive_request_unsupported",
        "high_stakes_unsupported",
        "context_too_large",
        "required_capability_unavailable",
        "quality_floor_not_met",
        "quality_evidence_unknown",
    },
    "no_eligible_configuration": {
        "context_too_large",
        "required_capability_unavailable",
        "quality_floor_not_met",
        "quality_evidence_unknown",
        "all_routes_unavailable",
    },
    "execution_failed": {"launcher_execution_failed"},
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


def validate_trace(value: dict[str, Any]) -> dict[str, Any]:
    scan_forbidden_fields(value)
    trace = require_exact_fields(value, TRACE_FIELDS, TRACE_OPTIONAL_FIELDS, "$")
    trace_id = require_string(trace["trace_id"], "$.trace_id")
    if TRACE_ID.fullmatch(trace_id) is None:
        raise TraceInputError("Trace ID has an unsupported format.", path="$.trace_id")
    unsupported_reason = (
        trace["reason_code"]
        if trace["output_status"] == "unsupported_request"
        and trace["reason_code"]
        in {
            "unsupported_language",
            "sensitive_request_unsupported",
            "high_stakes_unsupported",
        }
        else None
    )
    request_profile = validate_request_profile(
        trace["request_profile"], unsupported_reason=unsupported_reason
    )
    run_mode = require_enum(trace["run_mode"], RUN_MODES, "$.run_mode")

    prompt_content = trace.get("prompt_content")
    response_content = trace.get("response_content")
    for name, content in (("prompt_content", prompt_content), ("response_content", response_content)):
        if content is not None and not isinstance(content, str):
            raise TraceInputError(
                "Content must be a string or null.",
                path=f"$.{name}",
                detail="wrong_type",
            )
        if run_mode == "normal" and content is not None:
            raise TraceInputError(
                "Normal routing cannot store full content.", path=f"$.{name}"
            )
        if content is not None:
            reject_high_confidence_credential_content(content, f"$.{name}")

    prompt_hash = require_hash(trace["prompt_hash"], "$.prompt_hash")
    response_hash = require_hash(trace["response_hash"], "$.response_hash", nullable=True)
    if prompt_content is not None and sha256_utf8(prompt_content) != prompt_hash:
        raise TraceInputError(
            "Prompt content does not match its supplied SHA-256 hash.",
            path="$.prompt_hash",
            detail="content_hash_mismatch",
        )
    if response_content is not None:
        if response_hash is None or sha256_utf8(response_content) != response_hash:
            raise TraceInputError(
                "Response content does not match its supplied SHA-256 hash.",
                path="$.response_hash",
                detail="content_hash_mismatch",
            )

    evaluations_value = trace["candidate_evaluations"]
    if not isinstance(evaluations_value, list):
        raise TraceInputError(
            "Expected an array.",
            path="$.candidate_evaluations",
            detail="wrong_type",
        )
    evaluations = [
        validate_candidate(item, index)
        for index, item in enumerate(evaluations_value)
    ]
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
    reason_code = require_nullable_enum(
        trace["reason_code"], FAILURE_REASON_CODES, "$.reason_code"
    )
    selected_candidate = require_nullable_string(
        trace["selected_candidate"], "$.selected_candidate"
    )
    selected_evaluations = [item for item in evaluations if item["selected"]]
    winner_status = output_status in {"completed", "execution_failed"}
    if output_status == "completed":
        if reason_code is not None:
            raise TraceInputError(
                "Completed decisions cannot have a failure reason.", path="$.reason_code"
            )
    else:
        if reason_code is None:
            raise TraceInputError(
                "Failed decisions require a reason code.", path="$.reason_code"
            )
        if reason_code not in STATUS_REASON_CODES[output_status]:
            raise TraceInputError(
                "Failure reason is not approved for this output status.",
                path="$.reason_code",
            )

    selected_evaluation: dict[str, Any] | None = None
    if winner_status:
        if selected_candidate is None or len(selected_evaluations) != 1:
            raise TraceInputError(
                "Winner statuses require exactly one selected evaluation.",
                path="$.selected_candidate",
            )
        if selected_candidate not in identities:
            raise TraceInputError(
                "Selected candidate was not evaluated.", path="$.selected_candidate"
            )
        selected_evaluation = selected_evaluations[0]
        if selected_evaluation["candidate_identity"] != selected_candidate:
            raise TraceInputError(
                "Selected candidate does not match selected evaluation.",
                path="$.selected_candidate",
            )
        if not selected_evaluation["eligible"]:
            raise TraceInputError(
                "Selected evaluation must be eligible.", path="$.selected_candidate"
            )
    else:
        if selected_candidate is not None or selected_evaluations:
            raise TraceInputError(
                "Pre-execution failures cannot retain a selected candidate.",
                path="$.selected_candidate",
            )
        if any(item["eligible"] for item in evaluations):
            raise TraceInputError(
                "Pre-execution failure candidates must all be rejected.",
                path="$.candidate_evaluations",
            )

    effective_quality = require_nullable_enum(
        trace["effective_quality"], QUALITY_CATEGORIES, "$.effective_quality"
    )
    quality_bottleneck = require_nullable_string(
        trace["quality_bottleneck"], "$.quality_bottleneck"
    )
    top_price = decimal_text(trace["price"], "$.price", nullable=True)
    top_price_final = require_bool(trace["price_final"], "$.price_final")
    latency_ms = sqlite_real(trace["latency_ms"], "$.latency_ms", nullable=True)
    if winner_status:
        for item, path in (
            (effective_quality, "$.effective_quality"),
            (quality_bottleneck, "$.quality_bottleneck"),
            (top_price, "$.price"),
        ):
            if item is None:
                raise TraceInputError("Winner metadata cannot be null.", path=path)
        selected_quality = selected_evaluation["quality"]
        selected_price = selected_evaluation["price"]
        if effective_quality != selected_quality["effective_quality"]:
            raise TraceInputError(
                "Winner quality must match the selected evaluation.",
                path="$.effective_quality",
            )
        if quality_bottleneck != selected_quality["quality_bottleneck"]:
            raise TraceInputError(
                "Winner quality bottleneck must match the selected evaluation.",
                path="$.quality_bottleneck",
            )
        if top_price != selected_price["price"]:
            raise TraceInputError(
                "Winner price must match the selected evaluation exactly.", path="$.price"
            )
        if top_price_final != selected_price["price_final"]:
            raise TraceInputError(
                "Winner price finality must match the selected evaluation.",
                path="$.price_final",
            )
    if output_status == "completed":
        if latency_ms is None or response_hash is None:
            raise TraceInputError(
                "Completed decisions require latency and a response hash.",
                path="$.latency_ms" if latency_ms is None else "$.response_hash",
            )
        if not selected_evaluation["latency_available"]:
            raise TraceInputError(
                "Completed winner must have candidate latency.",
                path="$.candidate_evaluations",
            )
        if latency_ms != selected_evaluation["latency_ms"]:
            raise TraceInputError(
                "Completed latency must match the selected evaluation.", path="$.latency_ms"
            )
    elif output_status == "execution_failed":
        if response_hash is not None or response_content is not None:
            raise TraceInputError(
                "Execution failure cannot retain normalized response metadata.",
                path="$.response_hash" if response_hash is not None else "$.response_content",
            )
    else:
        if effective_quality is not None or quality_bottleneck is not None:
            raise TraceInputError(
                "Failed decisions cannot retain winner quality metadata.",
                path="$.effective_quality" if effective_quality is not None else "$.quality_bottleneck",
            )
        if top_price is not None or top_price_final:
            raise TraceInputError(
                "Failed decisions cannot retain winner price metadata.",
                path="$.price" if top_price is not None else "$.price_final",
            )
        if response_hash is not None or response_content is not None:
            raise TraceInputError(
                "Pre-execution failures cannot retain response metadata.",
                path="$.response_hash" if response_hash is not None else "$.response_content",
            )
        if latency_ms is not None:
            raise TraceInputError(
                "Pre-execution failures cannot retain top-level latency.", path="$.latency_ms"
            )

    return {
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
        "price_final": top_price_final,
        "latency_ms": latency_ms,
        "router_policy_version": require_string(
            trace["router_policy_version"], "$.router_policy_version"
        ),
        "profile_schema_version": require_string(
            trace["profile_schema_version"], "$.profile_schema_version"
        ),
        "model_profile_version": require_string(
            trace["model_profile_version"], "$.model_profile_version"
        ),
        "pricing_snapshot_date": require_iso_date(
            trace["pricing_snapshot_date"], "$.pricing_snapshot_date"
        ),
        "quality_snapshot_date": require_iso_date(
            trace["quality_snapshot_date"], "$.quality_snapshot_date"
        ),
        "calibration_set_version": require_string(
            trace["calibration_set_version"], "$.calibration_set_version"
        ),
        "prompt_hash": prompt_hash,
        "response_hash": response_hash,
        "prompt_content": prompt_content,
        "response_content": response_content,
        "candidate_evaluations": evaluations,
    }


__all__ = [
    "TraceInputError",
    "canonical_json",
    "load_trace",
    "validate_trace",
]
