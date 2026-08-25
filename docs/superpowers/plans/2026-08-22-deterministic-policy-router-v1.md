# Deterministic Policy Router V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` to execute this plan task-by-task. Use `test-driven-development` for every behavior change, `trace-live-call-path` before changing existing runner seams, and `verification-before-completion` before any completion claim.

**Goal:** Add a project-local deterministic policy router that selects exactly one complete launcher/model/effort configuration using requirements, categorical quality, estimated user price, latency, and stable identity, then executes it through the existing native CLI adapters and records an auditable SQLite trace.

**Architecture:** Preserve `pilot/model_matrix.json` and `pilot/lib/runner.ps1` as the source of candidate identities and provider-specific execution/parsing. Add a separate `router/` policy layer, checked-in `profiles/`, JSON Schemas, a Python-standard-library SQLite writer, and calibration assets. Keep policy functions pure where possible so routing tests never invoke provider CLIs.

**Tech stack:** PowerShell 7.6 for orchestration and policy, JSON and JSON Schema-style validation, Python standard-library `sqlite3` for project-local trace persistence, existing native `codex`/`claude`/`agy` CLIs, fixture-driven PowerShell tests, Python `unittest` for SQLite storage.

**Execution discipline:** A fresh subagent handles each task with a narrow write set. After every implementation subagent, run a specification review and then a code-quality review before advancing. Do not run the full model matrix as part of unit tests.

---

## Task 1: Confirm live seams and establish router test harness

**Files:**
- Read: `pilot/model_matrix.json`
- Read: `pilot/lib/runner.ps1`
- Read: `pilot/run_pilot.ps1`
- Read: `pilot/tests/runner.tests.ps1`
- Create: `router/tests/router.tests.ps1`
- Create: `router/tests/fixtures/minimal-profiles/`

- [ ] **Step 1: Trace the existing live execution path**

Identify the functions currently used to load candidates, validate model/effort combinations, construct provider commands, execute one candidate, normalize provider output, and build a result record. Record the reusable function names at the top of the router test file as comments. Do not infer relevance from names alone.

- [ ] **Step 2: Write the failing router test harness**

Create assertions for:

- request-schema rejection
- profile-schema rejection when any required quality key is absent
- exact composite identity `(launcher, configuration_id)`
- one selected candidate
- deterministic repeatability

The tests must fail because router production files do not exist yet.

- [ ] **Step 3: Verify RED**

```powershell
pwsh -NoProfile -File .\router\tests\router.tests.ps1
```

Expected: deterministic failure identifying the missing router module or schemas.

- [ ] **Step 4: Commit the tests only**

```powershell
git add router/tests docs/superpowers/specs/2026-08-22-deterministic-policy-router-v1-design.md docs/superpowers/plans/2026-08-22-deterministic-policy-router-v1.md
git commit -m "test: define deterministic router contract"
```

## Task 2: Add request, profile, and response schemas

**Files:**
- Create: `router/schemas/request-profile.schema.json`
- Create: `router/schemas/model-profile.schema.json`
- Create: `router/schemas/router-response.schema.json`
- Create: `router/lib/schema.ps1`
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Extend failing tests for every approved enum and required field**

Cover all task types, domains, complexity levels, quality floors, latency values, output lengths, capabilities, statuses, and reason codes. Assert that unsupported language, privacy, risk, and modality boundaries fail with the correct code.

- [ ] **Step 2: Define the JSON Schemas**

The model-profile schema must require explicit maps for every V1 task type, domain, complexity, and capability. Allowed category values are `unsupported`, `unknown`, `standard`, `strong`, and `frontier`. No omitted quality key may default silently.

- [ ] **Step 3: Implement minimal schema validation**

Follow the repository's existing validation style. Do not introduce a package dependency unless the existing code already has one. Return structured validation failures rather than throwing unhandled exceptions at the CLI boundary.

- [ ] **Step 4: Verify GREEN**

```powershell
pwsh -NoProfile -File .\router\tests\router.tests.ps1
```

- [ ] **Step 5: Commit**

```powershell
git add router/schemas router/lib/schema.ps1 router/tests
git commit -m "feat: add deterministic router schemas"
```

## Task 3: Build explicit configuration profiles and catalog validation

**Files:**
- Create: `profiles/codex/*.json`
- Create: `profiles/claude/*.json`
- Create: `profiles/agy/*.json`
- Create: `router/lib/profiles.ps1`
- Create: `router/data/pricing-snapshot-2026-08-22.json`
- Create: `router/data/quality-snapshot-2026-08-22.json`
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Write failing catalog tests**

Assert that:

- every enabled normal candidate in `pilot/model_matrix.json` maps to exactly one profile
- profile identity is unique by launcher plus configuration ID
- every model/effort combination remains separate
- all quality dimensions are explicit
- official pricing schedules have effective dates
- GPT-5.3 Codex Spark is marked non-cost-comparable while its public price is unknown

- [ ] **Step 2: Add the dated pricing snapshot**

Encode the approved official rates and effective periods from the design. Store unit rates as calculation inputs, not as reference/effective request-price fields.

- [ ] **Step 3: Add the dated quality snapshot**

Record Artificial Analysis source URLs, retrieval date, exact model/effort match, relevant benchmark slices, and provisional category. Use `unknown` whenever the exact configuration or relevant slice is unavailable or contradictory. Do not infer missing effort levels from a base-model score.

- [ ] **Step 4: Generate or author one explicit profile per candidate**

Profiles may be mechanically generated from reviewed snapshots, but generated files must be checked in and validated. Do not collapse effort variants into a base-model profile.

- [ ] **Step 5: Implement catalog loading and validation**

The loader returns validated profile objects and a structured list of errors. Startup fails before routing when profile coverage is incomplete.

- [ ] **Step 6: Verify and commit**

```powershell
pwsh -NoProfile -File .\router\tests\router.tests.ps1
git add profiles router/data router/lib/profiles.ps1 router/tests
git commit -m "feat: add versioned router model profiles"
```

## Task 4: Implement requirement validation and capability derivation

**Files:**
- Create: `router/lib/requirements.ps1`
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Write table-driven failing tests**

Cover:

- English text single-turn acceptance
- sensitive and high-stakes rejection
- context and output-window rejection
- every task-derived capability rule
- non-general-domain factual reliability
- explicit additional-capability union
- unavailable, disabled, unsupported, and quota-exhausted candidates

- [ ] **Step 2: Implement pure derivation functions**

Add functions that validate the request, estimate required context, derive the required-capability set, and evaluate candidate requirements. Return explicit reason codes for every failure.

- [ ] **Step 3: Keep latency out of requirements**

Tests must prove that a slow candidate can pass requirements. Latency is not evaluated until after price.

- [ ] **Step 4: Verify and commit**

```powershell
pwsh -NoProfile -File .\router\tests\router.tests.ps1
git add router/lib/requirements.ps1 router/tests
git commit -m "feat: add router requirement derivation"
```

## Task 5: Implement categorical quality eligibility

**Files:**
- Create: `router/lib/quality.ps1`
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Write failing quality tests**

Test the ordinal policy `standard < strong < frontier`, lowest-relevant-category behavior, bottleneck reporting, `unknown` ineligibility, `unsupported` requirement failure, and every quality floor.

- [ ] **Step 2: Implement effective quality**

Given a validated request, derived capabilities, and profile, collect only relevant task/domain/complexity/capability categories, return the minimum eligible category, and return the exact bottleneck key. Never average or select the maximum.

- [ ] **Step 3: Verify and commit**

```powershell
pwsh -NoProfile -File .\router\tests\router.tests.ps1
git add router/lib/quality.ps1 router/tests
git commit -m "feat: add categorical quality floor policy"
```

## Task 6: Implement token estimation, price, latency, and deterministic ranking

**Files:**
- Create: `router/lib/pricing.ps1`
- Create: `router/lib/policy.ps1`
- Create: `router/tests/fixtures/token-estimates.json`
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Write failing price tests**

Cover input rates, output rates, time-bounded promotional rates, Gemini >200K pricing, reasoning-token estimates, unavailable price, and decimal rounding only at the response boundary.

- [ ] **Step 2: Write failing ordering tests**

Prove:

- requirements run before quality
- quality floor runs before price
- a cheaper frontier candidate may beat a more expensive strong candidate after both pass the floor
- model and effort are ranked jointly
- price beats latency
- latency breaks equal-price ties
- stable identity breaks the final tie
- exactly one candidate is selected

- [ ] **Step 3: Implement price calculation**

Use profile rates and exact model/effort/profile token estimates. Keep full decimal precision internally. Produce one request-level `price` and `price_final` status.

- [ ] **Step 4: Implement pure deterministic policy**

The policy returns the winner plus one candidate-evaluation record per candidate. It must not invoke a CLI or write a database.

- [ ] **Step 5: Verify and commit**

```powershell
pwsh -NoProfile -File .\router\tests\router.tests.ps1
git add router/lib/pricing.ps1 router/lib/policy.ps1 router/tests
git commit -m "feat: add deterministic routing policy"
```

## Task 7: Add project-local SQLite trace storage

**Files:**
- Create: `router/storage/sqlite_store.py`
- Create: `router/storage/test_sqlite_store.py`
- Create: `router/lib/trace.ps1`
- Modify: `.gitignore`
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Write failing SQLite tests**

Using a temporary database, test schema creation, one `routing_decisions` transaction with many `candidate_evaluations`, version fields, prompt/response hash storage, optional benchmark content storage, and rollback on malformed input.

- [ ] **Step 2: Implement the Python standard-library writer**

Accept a complete trace JSON object through standard input. Use parameterized SQL exclusively. Create or migrate only the approved V1 tables and indexes. Never accept credentials or environment snapshots.

- [ ] **Step 3: Implement the PowerShell bridge**

`Write-RouterTrace` sends JSON through stdin to the helper and surfaces a structured storage error. Do not place prompt text or secrets on the process command line.

- [ ] **Step 4: Ignore runtime data**

Add:

```text
data/*.sqlite
data/*.sqlite-shm
data/*.sqlite-wal
```

Keep an optional `data/.gitkeep`, but never commit a runtime database.

- [ ] **Step 5: Verify and commit**

```powershell
python -m unittest router.storage.test_sqlite_store
pwsh -NoProfile -File .\router\tests\router.tests.ps1
git add router/storage router/lib/trace.ps1 router/tests .gitignore data/.gitkeep
git commit -m "feat: add SQLite routing decision traces"
```

## Task 8: Integrate selected-route execution and normalized responses

**Files:**
- Create: `router/run_router.ps1`
- Create: `router/lib/response.ps1`
- Modify: `pilot/lib/runner.ps1` only if a minimal reusable seam is absent
- Modify: `pilot/tests/runner.tests.ps1` only for any modified runner seam
- Modify: `router/tests/router.tests.ps1`

- [ ] **Step 1: Trace and test the execution seam before editing it**

Prefer calling an existing exported single-candidate function. If no safe seam exists, extract the smallest reusable function from the live runner under characterization tests. Do not duplicate provider command construction or parsing in the router.

- [ ] **Step 2: Write failing integration tests with a fake executor**

Test one selected invocation, no invocation for rejected requests, no second invocation after failure, normalized success, normalized failure, final price when complete usage exists, estimated price when usage is incomplete, final latency, and trace persistence.

- [ ] **Step 3: Implement `run_router.ps1`**

Accept a request JSON file or JSON on stdin. Load and validate profiles, derive requirements, run the pure policy, execute exactly one winner, normalize the result, write the trace, and emit one router-response JSON object.

- [ ] **Step 4: Implement structured failures**

Cover every approved top-level status and reason code. Return a trace ID whenever trace storage succeeded.

- [ ] **Step 5: Verify and commit**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
pwsh -NoProfile -File .\router\tests\router.tests.ps1
git add router pilot/lib/runner.ps1 pilot/tests
git commit -m "feat: execute deterministic selected routes"
```

## Task 9: Add the 24-prompt calibration framework

**Files:**
- Create: `calibration/calibration-set-v1.json`
- Create: `calibration/rubrics/*.json`
- Create: `calibration/run_calibration.ps1`
- Create: `calibration/tests/calibration.tests.ps1`
- Create: `calibration/results/.gitkeep`
- Modify: `.gitignore`

- [ ] **Step 1: Write failing calibration-schema and judge-selection tests**

Assert 24 prompts, all eight task types, all three complexity levels, domain distribution, deterministic graders where applicable, two cross-family judges, candidate anonymization, and no self-only judgment.

- [ ] **Step 2: Author prompts and rubrics**

Use reviewed, non-secret prompts with verified answers or explicit rubrics. Do not use high-stakes or sensitive content. Version every prompt and rubric.

- [ ] **Step 3: Implement calibration orchestration**

Default to dry-run. Require explicit route or run switch. Reuse the existing runner. Preserve raw outputs locally, anonymize candidate metadata before subjective judging, and record both judge decisions.

- [ ] **Step 4: Implement conservative category confirmation**

Both-pass retains the external category. Both-fail or disagreement changes the relevant category proposal to `unknown`. The calibration tool writes a review artifact; it must not silently rewrite checked-in profiles.

- [ ] **Step 5: Verify and commit**

```powershell
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
git add calibration .gitignore
git commit -m "feat: add router calibration framework"
```

## Task 10: End-to-end acceptance and documentation

**Files:**
- Create: `router/README.md`
- Create: `router/examples/*.json`
- Modify: relevant tests only when a verified live issue exposes a missing case

- [ ] **Step 1: Run all structural verification**

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
pwsh -NoProfile -File .\router\tests\router.tests.ps1
python -m unittest router.storage.test_sqlite_store
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

- [ ] **Step 2: Verify deterministic dry runs**

Run representative requests for standard, strong, and frontier quality floors without invoking models. Confirm exact winner stability, quality bottlenecks, price ordering, and candidate rejection reasons.

- [ ] **Step 3: Run one live smoke route per launcher**

Use harmless text-only requests. Confirm exactly one model call per request, provider normalization, trace creation, no secret capture, and no fallback after a simulated failure.

- [ ] **Step 4: Inspect the real SQLite artifact**

Query one successful route and one failure. Confirm the selected candidate, all candidate evaluations, version fields, content hashes, and absence of credentials or environment dumps.

- [ ] **Step 5: Write the user guide**

Explain request fields, category meanings, selection order, `price` versus `price_final`, decision trace lookup, dry-run behavior, and V1 boundaries in beginner-friendly language.

- [ ] **Step 6: Final review and branch completion**

Run a dedicated specification review and code-quality review. Resolve findings, rerun all tests, inspect the actual route output, and then use the branch-finishing workflow to offer PR/merge options. Do not push or merge unless the user authorizes that action for the exact branch and SHA.

## Parallelization map for subagent-driven execution

After Task 1 establishes live seams, these tasks can be delegated with disjoint write scopes:

- Task 2 schemas and validation
- Task 3 snapshots/profile generation
- Task 7 SQLite storage
- Task 9 calibration assets

Tasks 4, 5, and 6 are sequential because each builds the policy pipeline. Task 8 depends on Tasks 2 through 7. Task 10 is the final integrated acceptance pass.
