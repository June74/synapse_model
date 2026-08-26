# SB-20260826-175410-exact-fields-date-coercion: Exact-fields parsing coerces ISO timestamp strings

- **Status:** contained
- **First observed:** 2026-08-26T17:54:10.0746877Z
- **Last observed:** 2026-08-26T17:54:10.0746877Z
- **Phase/task:** Offline calibration JSON-rubric adjudication
- **Environment:** Windows PowerShell, isolated option1-calibration-pilot worktree
- **Version/commit:** `9135b8b44b324d4baff3386cb3932c4ce27b8ef8`

## Symptom

The exact expected direct JSON array for `extraction-high-engineering-v1` parses successfully but fails both the deterministic schema and exact-value checks.

## Impact

The high/engineering extraction prompt cannot currently receive a deterministic `exact_fields` pass when its ISO-8601 `timestamp_utc` values are represented as the required JSON strings. This did not affect the completed Option 1 live run, which selected the low/general extraction prompt and contains no timestamp field. No quality category or production profile changed.

## Reproduction conditions

Load the checked-in calibration set, serialize the high/engineering prompt's exact expected array as direct JSON, and pass that text to `Invoke-CalibrationDeterministicGrader`.

## Safe evidence

- The complete response is a directly parseable JSON array.
- The parser returns three objects in the correct order.
- Each `timestamp_utc` value is materialized as `System.DateTime`, while the checked-in grader schema requires `string`.
- Every individual field compares equal after the same conversion, but the schema check rejects the timestamp type and the overall outcome is `fail` with `deterministic_check_failed`.

## Attempts and outcomes

1. The initial adjudication case matrix expected the exact direct array to pass; it instead failed the schema check.
2. A focused type probe confirmed that both imported expected timestamps and parsed response timestamps are `System.DateTime` objects.
3. Source inspection found `ConvertFrom-Json` calls without `-DateKind String` in both `Import-CalibrationSet` and `Get-CalibrationJsonPayload`.

## Cause classification

- **Confirmed cause:** PowerShell `ConvertFrom-Json` automatically converts ISO-8601 JSON string values into `DateTime` objects when `-DateKind String` is omitted. The exact-fields schema correctly requires `timestamp_utc` to remain a JSON string.
- **Hypotheses:** None remaining for this reproduction.
- **Rejected hypotheses:** Array order, numeric values, property names, and the direct JSON shape are not the cause; each was verified independently.
- **Known exclusions:** The low/general Option 1 live prompt, provider envelopes, launcher identities, credentials, network behavior, and production routing are unaffected.

## Correction and prevention

- **Correction:** No product correction was made during adjudication. The defect is contained by keeping production quality unknown and not running the affected high/engineering prompt.
- **Prevention:** A future test-driven repair should preserve JSON date-looking strings during both calibration-set import and candidate-answer parsing, then prove the exact direct array passes while non-string timestamps fail.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** Decide whether to include date-kind preservation in the same repair as strict complete-response JSON parsing or in a separate bounded change.

## Verification and related work

The focused reproduction was offline and read-only. The completed live result retained its original SHA-256, and no provider, launcher, network request, result rewrite, quality promotion, or eligibility change occurred.
