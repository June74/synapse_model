"""Shared strict-JSON and scalar helpers for the V1 trace contract.

Stored-content screening is an admission defense for a narrow set of
high-confidence credential forms. It is not proof that arbitrary content is
secret-free, and it deliberately does not reject ordinary security prose.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from typing import Any, NoReturn


HEX_HASH = re.compile(r"^[0-9a-fA-F]{64}$")
TRACE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")

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

CONTENT_CREDENTIAL_PATTERNS = (
    re.compile(
        r"(?im)\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{32,}"
    ),
    re.compile(
        r"(?im)\bauthorization\s*:\s*basic\s+[A-Za-z0-9+/]{24,}={0,2}"
    ),
    re.compile(
        r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:sk-(?:ant-)?|gh[pousr]_|AIza|sk_live_)[A-Za-z0-9_-]{24,}\b"
    ),
    re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    re.compile(
        r"(?im)\baws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{40}"
    ),
    re.compile(
        r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{16,}\."
        r"[A-Za-z0-9_-]{24,}(?![A-Za-z0-9_-])"
    ),
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


def reject_high_confidence_credential_content(value: str, path: str) -> None:
    if any(pattern.search(value) is not None for pattern in CONTENT_CREDENTIAL_PATTERNS):
        raise TraceInputError(
            "Stored content matches a high-confidence credential pattern.",
            path=path,
            detail="credential_pattern_detected",
            code="forbidden_content",
        )


def sha256_utf8(value: str) -> str:
    """Return SHA-256 of the exact UTF-8 bytes, with no BOM added."""

    return hashlib.sha256(value.encode("utf-8")).hexdigest()


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


def require_string_list(
    value: Any,
    path: str,
    *,
    allowed: set[str] | None = None,
) -> list[str]:
    if not isinstance(value, list):
        raise TraceInputError("Expected an array.", path=path, detail="wrong_type")
    result: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        text = require_string(item, f"{path}[{index}]")
        if allowed is not None and text not in allowed:
            raise TraceInputError(
                "Array entry is not in the approved allowlist.",
                path=f"{path}[{index}]",
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
    if isinstance(value, bool) or not isinstance(value, (int, Decimal)):
        raise TraceInputError("Expected a nonnegative integer.", path=path, detail="wrong_type")
    number = Decimal(value)
    if not number.is_finite() or number < 0 or number != number.to_integral_value():
        raise TraceInputError("Expected a nonnegative integer.", path=path, detail="wrong_type")
    return int(number)


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

    return json.dumps(
        normalize(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
