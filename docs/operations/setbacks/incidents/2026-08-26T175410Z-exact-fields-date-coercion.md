# SB-20260826-175410-exact-fields-date-coercion: Exact-fields parsing coerces ISO timestamp strings

- **Status:** closed
- **First observed:** 2026-08-26T17:54:10.0746877Z
- **Last observed:** 2026-08-27T03:21:35.9451106Z
- **Phase/task:** Offline calibration JSON-rubric adjudication
- **Environment:** Windows PowerShell, isolated option1-calibration-pilot worktree
- **Version/commit:** observed at `9135b8b44b324d4baff3386cb3932c4ce27b8ef8`; corrected by `f25a7937e629530eb24cc42c7335a093834ea32b`

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

- **Correction:** `f25a7937e629530eb24cc42c7335a093834ea32b` adds `-DateKind String` at the normal calibration-set importer, immutable pilot snapshot loader, and candidate-answer parser boundaries. The exact direct high/engineering array now passes the unchanged string schema and exact-value checks.
- **Prevention:** Functional regressions require both imported and immutable-snapshot timestamps to remain `System.String` and require the direct serialized expected array to pass. The companion complete-response repair in `7f0f2bc29f605e4d14dcc17d4d31f0e16162e123` keeps fenced or prose-wrapped JSON conservative without weakening the timestamp schema.
- **Owner:** Codex and project owner.
- **Next diagnostic step:** None for this closed offline defect. Any future live calibration requires separate authorization and a new acceptance packet.

## Verification and related work

- RED: the functional suite exited 1 while imported and immutable-snapshot `timestamp_utc` values were `System.DateTime`; the direct high/engineering array failed its required string schema.
- GREEN: after `f25a7937e629530eb24cc42c7335a093834ea32b`, both source paths preserve `System.String`, the direct array passes, and the complete final functional suite passed 68 assertions with exit code 0.
- Final offline gate: Pilot 127 PASS with one documented privilege-only symbolic-link skip; Router 355 PASS; SQLite 53 tests; Calibration 68 PASS; Calibration Security 42 PASS. Every command exited 0. The focused security run also passed 42 assertions.
- Scope: `git diff --check` exited 0, and no change from base `081c7351e7053703338b26f5b5a2db4a6aff0ac9` touched `profiles`, `pilot/model_matrix.json`, `router/lib/policy.ps1`, or `router/lib/quality.ps1`.
- Boundary: no provider, native launcher, network, live calibration, paid API, local model, or calibration `-Run` operation occurred. No production quality, eligibility, profile, or routing state changed.
- Immutable evidence: `calibration/results/option1-live-20260826-002/result.json` was not rewritten and retains SHA-256 `b8b4cbfbe5a4122f33716efd69e8aea4bf935e69b2bc850245a4422cb19a1a7b`.

The accepted interpretation remains that the complete whitespace-trimmed response must parse directly as the requested JSON value; fenced or prose-wrapped JSON is malformed for this contract even if an enclosed fragment is recoverable.
