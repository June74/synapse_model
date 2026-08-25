# SB-20260823-015506-test-json-numeric-precision: Test-Json loses numeric precision at contract boundaries

- **Status:** closed
- **First observed:** 2026-08-23
- **Last observed:** 2026-08-23
- **Phase/task:** Deterministic router V1, Task 2 schema validation hardening
- **Environment:** PowerShell 7.6.4, project-local deterministic-router worktree
- **Version or commit:** Observed before Task 2 simplification; corrected by `dd8469ba4307585e9757a1748c1c95318220dcc0`
- **Symptom:** PowerShell `Test-Json` accepted tiny nonzero values as numeric zero, rejected two mathematically distinct large values as duplicates under `uniqueItems`, and accepted tiny negative values such as `-1e-100` and `-5e-324` against `minimum: 0`.
- **Impact:** Treating the built-in validator as the sole numeric authority would create false-positive `const`/`enum` matches, false-negative `uniqueItems` results, and false acceptance of negative prices, rates, and latency values.
- **Reproduction conditions:** Against `enum: [0]`, validate zero, the smallest positive `Double`, and `1e-100`; all return true. Against `uniqueItems: true`, validate `Decimal.MaxValue` and its rounded `Double`, whose exact integer values differ by one; the pair returns false. Against `minimum: 0`, validate `-1e-100` and negative `Double.Epsilon`; both return true.
- **Safe evidence:** The bounded local probe used only synthetic numeric values and a temporary schema, which was removed.
- **Confirmed cause:** The built-in validator performs lossy numeric comparison at tiny magnitudes and lossy numeric equality at large cross-representation boundaries.
- **Hypotheses:** None open.
- **Rejected hypotheses:** The project wrapper was not responsible; the behavior reproduced by calling `Test-Json` directly.
- **Correction:** V1 rejects numeric `const`, numeric `enum`, and numeric or nested `uniqueItems` schema forms as `schema_invalid`. The only audited numeric exception is for the checked-in `minimum` forms: schema structure permits exact integer `0` or `1`, and a focused finite-number guard reports `number_below_minimum` at the candidate path before accepting a built-in result. No schema clone or exact-rational equality engine remains.
- **Prevention:** Keep numeric-equality schema forms outside the audited V1 subset unless a future contract explicitly requires them and supplies an authority with verified exact semantics. Permit only the observed `minimum: 0` and `minimum: 1` forms, retain their tiny-negative regressions, and leave every other semantic keyword under `Test-Json` authority.
- **Owner:** Implementer
- **Next diagnostic step:** None; rerun the retained adversarial suite when PowerShell or its JSON Schema engine changes.
- **Related verification:** Router suites passed normally and under inherited StrictMode Latest with warnings treated as errors. Structural regressions verify that numeric/composite equality forms fail closed, unsupported minimum values fail at `$.minimum`, tiny negatives fail at their exact price/latency/rate paths, both checked-in model profiles pass, and no temporary schemas remain. A direct probe reproduced built-in acceptance for both tiny negatives while the wrapper rejected the same value.
