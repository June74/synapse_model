"""Request-profile and candidate-evaluation coherence for V1 traces."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from router.storage.contract_support import (
    TraceInputError,
    decimal_text,
    nonnegative_integer,
    require_bool,
    require_enum,
    require_exact_fields,
    require_nullable_enum,
    require_nullable_string,
    require_string,
    require_string_list,
    sqlite_real,
)


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

REQUIREMENT_REASON_ORDER = (
    "candidate_disabled",
    "candidate_unavailable",
    "runtime_state_invalid",
    "runtime_identity_mismatch",
    "launcher_unavailable",
    "launcher_unauthenticated",
    "launcher_unhealthy",
    "quota_exhausted",
    "text_input_unsupported",
    "text_output_unsupported",
    "english_unsupported",
    "single_turn_unsupported",
    "context_window_exceeded",
    "output_window_exceeded",
    "price_unavailable",
    "required_function_unsupported",
    "required_capability_unavailable",
)
REQUIREMENT_REASON_CODES = set(REQUIREMENT_REASON_ORDER)
QUALITY_FAILURE_REASON_CODES = {
    "required_capability_unavailable",
    "quality_evidence_unknown",
    "quality_floor_not_met",
}
PRICE_FAILURE_REASON_CODES = {
    "request_profile_group_invalid",
    "pricing_snapshot_unavailable",
    "pricing_snapshot_invalid",
    "pricing_snapshot_mismatch",
    "pricing_date_invalid",
    "token_estimate_unavailable",
    "token_estimate_invalid",
    "pricing_schedule_unavailable",
    "pricing_period_unavailable",
    "pricing_rate_unavailable",
    "price_calculation_unavailable",
    "free_route_disallowed",
}

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


def validate_request_profile(
    value: Any, *, unsupported_reason: str | None = None
) -> dict[str, Any]:
    profile = require_exact_fields(
        value,
        REQUEST_REQUIRED_FIELDS,
        REQUEST_OPTIONAL_FIELDS,
        "$.request_profile",
    )

    def boundary_value(
        field_name: str, supported_value: str, matching_reason: str
    ) -> str:
        path = f"$.request_profile.{field_name}"
        if unsupported_reason == matching_reason:
            return require_string(profile[field_name], path)
        return require_enum(profile[field_name], {supported_value}, path)

    return {
        "task_type": require_enum(
            profile["task_type"],
            {
                "general",
                "coding",
                "math",
                "reasoning",
                "writing",
                "summarization",
                "extraction",
                "research_synthesis",
            },
            "$.request_profile.task_type",
        ),
        "domain": require_enum(
            profile["domain"],
            {
                "general",
                "computer_science",
                "mathematics",
                "physics",
                "chemistry",
                "biology",
                "medicine",
                "engineering",
                "social_science",
                "humanities",
                "business",
                "finance",
                "law",
            },
            "$.request_profile.domain",
        ),
        "complexity": require_enum(
            profile["complexity"], {"low", "medium", "high"}, "$.request_profile.complexity"
        ),
        "quality_floor": require_enum(
            profile["quality_floor"], QUALITY_CATEGORIES, "$.request_profile.quality_floor"
        ),
        "latency": require_enum(
            profile.get("latency", "normal"),
            {"fast", "normal", "relaxed"},
            "$.request_profile.latency",
        ),
        "privacy_level": boundary_value(
            "privacy_level", "standard", "sensitive_request_unsupported"
        ),
        "risk_level": boundary_value(
            "risk_level", "standard", "high_stakes_unsupported"
        ),
        "output_length": require_enum(
            profile.get("output_length", "normal"),
            {"short", "normal", "detailed"},
            "$.request_profile.output_length",
        ),
        "language": boundary_value("language", "english", "unsupported_language"),
        "additional_capabilities": require_string_list(
            profile.get("additional_capabilities", []),
            "$.request_profile.additional_capabilities",
            allowed=CAPABILITIES,
        ),
    }


def validate_requirements(value: Any, identity: str, path: str) -> dict[str, Any] | None:
    if value is None:
        return None
    requirements = require_exact_fields(value, REQUIREMENTS_FIELDS, set(), path)
    if require_string(requirements["candidate_identity"], f"{path}.candidate_identity") != identity:
        raise TraceInputError(
            "Nested candidate identity does not match.",
            path=f"{path}.candidate_identity",
        )
    passed = require_bool(requirements["passed"], f"{path}.passed")
    reason_codes = require_string_list(
        requirements["reason_codes"],
        f"{path}.reason_codes",
        allowed=REQUIREMENT_REASON_CODES,
    )
    if reason_codes != sorted(reason_codes, key=REQUIREMENT_REASON_ORDER.index):
        raise TraceInputError(
            "Requirement reasons must use canonical producer order.",
            path=f"{path}.reason_codes",
        )
    unavailable = require_string_list(
        requirements["unavailable_capabilities"],
        f"{path}.unavailable_capabilities",
        allowed=CAPABILITIES,
    )
    unsupported_value = requirements["unsupported_requirements"]
    if not isinstance(unsupported_value, list):
        raise TraceInputError(
            "Expected an array.",
            path=f"{path}.unsupported_requirements",
            detail="wrong_type",
        )
    unsupported: list[dict[str, str]] = []
    unsupported_dimensions: set[str] = set()
    profile_maps = {
        "task_type": "task_types",
        "domain": "domains",
        "complexity": "complexities",
    }
    for index, item in enumerate(unsupported_value):
        item_path = f"{path}.unsupported_requirements[{index}]"
        record = require_exact_fields(item, UNSUPPORTED_REQUIREMENT_FIELDS, set(), item_path)
        normalized = {
            name: require_string(record[name], f"{item_path}.{name}")
            for name in ("dimension", "value", "profile_path")
        }
        dimension = normalized["dimension"]
        if dimension not in profile_maps:
            raise TraceInputError(
                "Unsupported requirement dimension is not canonical.",
                path=f"{item_path}.dimension",
            )
        expected_path = f"quality.{profile_maps[dimension]}.{normalized['value']}"
        if normalized["profile_path"] != expected_path:
            raise TraceInputError(
                "Unsupported requirement profile path is inconsistent.",
                path=f"{item_path}.profile_path",
            )
        if dimension in unsupported_dimensions:
            raise TraceInputError(
                "Unsupported requirement dimensions must be unique.",
                path=f"{item_path}.dimension",
            )
        unsupported_dimensions.add(dimension)
        unsupported.append(normalized)
    if passed and (reason_codes or unavailable or unsupported):
        raise TraceInputError(
            "Passed requirements cannot retain failure reasons or details.",
            path=f"{path}.reason_codes",
        )
    if not passed and not reason_codes:
        raise TraceInputError("Failed requirements require a reason.", path=f"{path}.reason_codes")
    if ("required_capability_unavailable" in reason_codes) != bool(unavailable):
        raise TraceInputError(
            "Unavailable capabilities must match their requirement reason.",
            path=f"{path}.unavailable_capabilities",
        )
    if ("required_function_unsupported" in reason_codes) != bool(unsupported):
        raise TraceInputError(
            "Unsupported requirement details must match their requirement reason.",
            path=f"{path}.unsupported_requirements",
        )
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
        raise TraceInputError(
            "Nested candidate identity does not match.",
            path=f"{path}.candidate_identity",
        )
    passed = require_bool(quality["passed"], f"{path}.passed")
    reason_code = require_nullable_enum(
        quality["reason_code"], QUALITY_FAILURE_REASON_CODES, f"{path}.reason_code"
    )
    effective_quality = require_nullable_enum(
        quality["effective_quality"], QUALITY_CATEGORIES, f"{path}.effective_quality"
    )
    bottleneck = require_nullable_string(
        quality["quality_bottleneck"], f"{path}.quality_bottleneck"
    )
    categories_value = quality["relevant_categories"]
    if not isinstance(categories_value, list):
        raise TraceInputError(
            "Expected an array.", path=f"{path}.relevant_categories", detail="wrong_type"
        )
    categories: list[dict[str, str]] = []
    category_by_key: dict[str, str] = {}
    for index, item in enumerate(categories_value):
        item_path = f"{path}.relevant_categories[{index}]"
        record = require_exact_fields(item, RELEVANT_CATEGORY_FIELDS, set(), item_path)
        key = require_string(record["key"], f"{item_path}.key")
        if key in category_by_key:
            raise TraceInputError(
                "Relevant quality category keys must be unique.",
                path=f"{item_path}.key",
            )
        category = require_enum(
            record["category"], EVIDENCE_CATEGORIES, f"{item_path}.category"
        )
        category_by_key[key] = category
        categories.append({"key": key, "category": category})
    if not categories:
        raise TraceInputError(
            "Quality evaluation requires relevant categories.",
            path=f"{path}.relevant_categories",
        )

    if passed:
        if reason_code is not None or effective_quality is None or bottleneck is None:
            raise TraceInputError(
                "Passed quality requires a result and no failure reason.",
                path=f"{path}.reason_code",
            )
        if any(category not in QUALITY_CATEGORIES for category in category_by_key.values()):
            raise TraceInputError(
                "Passed quality cannot contain unknown or unsupported evidence.",
                path=f"{path}.relevant_categories",
            )
        if category_by_key.get(bottleneck) != effective_quality:
            raise TraceInputError(
                "Quality result must match its identified bottleneck category.",
                path=f"{path}.quality_bottleneck",
            )
    else:
        if reason_code is None:
            raise TraceInputError(
                "Failed quality requires a reason.", path=f"{path}.reason_code"
            )
        if reason_code == "required_capability_unavailable":
            expected_category = "unsupported"
            expect_effective = None
        elif reason_code == "quality_evidence_unknown":
            expected_category = "unknown"
            expect_effective = None
        else:
            expected_category = effective_quality
            expect_effective = effective_quality
        if bottleneck is None or category_by_key.get(bottleneck) != expected_category:
            raise TraceInputError(
                "Failed quality reason must match its bottleneck evidence.",
                path=f"{path}.quality_bottleneck",
            )
        if effective_quality != expect_effective:
            raise TraceInputError(
                "Failed quality result is inconsistent with its reason.",
                path=f"{path}.effective_quality",
            )
        if reason_code == "quality_floor_not_met" and any(
            category not in QUALITY_CATEGORIES for category in category_by_key.values()
        ):
            raise TraceInputError(
                "Quality-floor failure cannot contain unknown or unsupported evidence.",
                path=f"{path}.relevant_categories",
            )
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
        raise TraceInputError(
            "Nested candidate identity does not match.",
            path=f"{path}.candidate_identity",
        )
    available = require_bool(price["available"], f"{path}.available")
    reason_code = require_nullable_enum(
        price["reason_code"], PRICE_FAILURE_REASON_CODES, f"{path}.reason_code"
    )
    profile_group = require_nullable_string(
        price["request_profile_group"], f"{path}.request_profile_group"
    )
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
            raise TraceInputError(
                "Available price cannot have a failure reason.", path=f"{path}.reason_code"
            )
        for name in ("request_profile_group",) + token_fields + decimal_fields:
            if normalized[name] is None:
                raise TraceInputError(
                    "Available price is missing metadata.", path=f"{path}.{name}"
                )
        if Decimal(normalized["price"]) <= 0:
            raise TraceInputError("Available price must be positive.", path=f"{path}.price")
        expected_billable = (
            normalized["estimated_visible_output_tokens"]
            + normalized["estimated_reasoning_tokens"]
        )
        if normalized["estimated_billable_output_tokens"] != expected_billable:
            raise TraceInputError(
                "Billable output tokens must equal visible plus reasoning tokens.",
                path=f"{path}.estimated_billable_output_tokens",
            )
    else:
        if reason_code is None:
            raise TraceInputError(
                "Unavailable price requires a reason.", path=f"{path}.reason_code"
            )
        for name in token_fields + decimal_fields:
            if normalized[name] is not None:
                raise TraceInputError(
                    "Unavailable price cannot retain estimate, rate, or result values.",
                    path=f"{path}.{name}",
                )
        if normalized["price_final"]:
            raise TraceInputError(
                "Unavailable price cannot be final.", path=f"{path}.price_final"
            )
        if reason_code == "request_profile_group_invalid":
            if profile_group is not None:
                raise TraceInputError(
                    "Invalid profile group result cannot retain a group.",
                    path=f"{path}.request_profile_group",
                )
        elif profile_group is None:
            raise TraceInputError(
                "Unavailable price requires the resolved request profile group.",
                path=f"{path}.request_profile_group",
            )
    return normalized


def validate_candidate(value: Any, index: int) -> dict[str, Any]:
    path = f"$.candidate_evaluations[{index}]"
    candidate = require_exact_fields(value, CANDIDATE_FIELDS, set(), path)
    identity = require_string(candidate["candidate_identity"], f"{path}.candidate_identity")
    launcher = require_string(candidate["launcher"], f"{path}.launcher")
    configuration_id = require_string(
        candidate["configuration_id"], f"{path}.configuration_id"
    )
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
    if latency_available != (latency_ms is not None):
        raise TraceInputError(
            "Latency availability must match latency value presence.",
            path=f"{path}.latency_milliseconds",
        )

    def require_rejection(expected_stage: str, expected_reasons: list[str]) -> None:
        if eligible or selected:
            raise TraceInputError(
                "Rejected candidates cannot be eligible or selected.",
                path=f"{path}.selected" if selected else f"{path}.eligible",
            )
        if rejection_stage != expected_stage:
            raise TraceInputError(
                "Candidate rejection must identify the first failed stage.",
                path=f"{path}.rejection_stage",
            )
        if rejection_reasons != expected_reasons:
            raise TraceInputError(
                "Candidate rejection reasons must exactly match the first failed stage.",
                path=f"{path}.rejection_reason_codes",
            )
        if latency_available or latency_ms is not None:
            raise TraceInputError(
                "Pre-execution rejected candidates cannot have latency results.",
                path=f"{path}.latency_available",
            )

    if rejection_stage == "request_validation":
        require_rejection("request_validation", ["request_validation_failed"])
        if requirements is not None or quality is not None or price is not None:
            raise TraceInputError(
                "Request-validation rejection must skip candidate evaluation stages.",
                path=f"{path}.requirements",
            )
    elif requirements is None:
        raise TraceInputError(
            "Candidate requirements must be evaluated before quality or price.",
            path=f"{path}.requirements",
        )
    elif not requirements["passed"]:
        require_rejection("requirements", requirements["reason_codes"])
        if quality is not None or price is not None:
            raise TraceInputError(
                "Failed requirements must stop quality and price evaluation.",
                path=f"{path}.quality" if quality is not None else f"{path}.price",
            )
    elif quality is None:
        raise TraceInputError(
            "Passed requirements must be followed by quality evaluation.",
            path=f"{path}.quality",
        )
    elif not quality["passed"]:
        require_rejection("quality", [quality["reason_code"]])
        if price is not None:
            raise TraceInputError(
                "Failed quality must stop price evaluation.", path=f"{path}.price"
            )
    elif price is None:
        raise TraceInputError(
            "Passed quality must be followed by price evaluation.", path=f"{path}.price"
        )
    elif not price["available"]:
        require_rejection("price", [price["reason_code"]])
    else:
        if not eligible:
            raise TraceInputError(
                "Candidates passing requirements, quality, and price must be eligible.",
                path=f"{path}.eligible",
            )
        if rejection_stage is not None or rejection_reasons:
            raise TraceInputError(
                "Eligible candidates cannot have rejection metadata.",
                path=f"{path}.rejection_stage",
            )

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
