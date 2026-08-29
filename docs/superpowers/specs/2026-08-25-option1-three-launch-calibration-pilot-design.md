# Option 1 Three-Launch Calibration Pilot Design

## Status

Approved in conversation on 2026-08-25 for specification and implementation planning.

This approval does not authorize provider execution. The live three-launch acceptance run remains a separate explicit approval boundary after implementation and offline verification.

## Goal

Add one bounded calibration-pilot path that proves the candidate, deterministic grading, anonymized cross-family judging, failure recording, and launch-budget controls work together.

The path processes exactly one checked-in prompt against exactly one pinned model-and-effort configuration. A successful technical path starts exactly three provider processes:

1. one candidate;
2. one OpenAI-family judge; and
3. one Anthropic-family judge.

The pilot has no application retry, fallback, substitution, resume, or profile promotion.

## Non-goals

The pilot does not:

- rank multiple candidates;
- sample more than one prompt;
- estimate production quality categories;
- update any of the 1,890 checked-in `unknown` quality fields;
- execute the full 24-prompt calibration set;
- execute the 63-candidate model matrix;
- change production router eligibility or ranking;
- claim that one launcher process equals one provider-side request; or
- write a production routing-decision trace for a calibration-only pin.

## Preserved policy

Production routing remains unchanged:

- requirements, then quality floor, then price, then latency, then stable identity;
- the lowest relevant category is the quality bottleneck;
- unknown quality fails closed;
- exactly one model-and-effort configuration is selected during normal routing;
- no automatic retry or fallback; and
- execution failure returns `execution_failed`.

The pilot deliberately bypasses production quality eligibility by resolving an exact calibration-only pin. It must label this as `selection_mode: calibration_only_exact_pin` and must never describe the candidate as a router-selected winner.

## Fixed pilot sample

The checked-in pilot manifest freezes these identities:

| Role | Family | Launcher | Route ID | Configuration ID |
|---|---|---|---|---|
| Candidate | Google | `agy` | `agy__gemini_3_7_flash_low__low` | `gemini-3.7-flash-low__low` |
| Judge 1 | OpenAI | `codex` | `codex__gpt_5_6_sol__max` | `gpt-5.6-sol__max` |
| Judge 2 | Anthropic | `claude` | `claude__claude_opus_5__max` | `claude-opus-5__max` |

The prompt is `extraction-low-general-v1` from `calibration/calibration-set-v1.json`.

This prompt is suitable because it is fictional, synthetic, text-only, low complexity, non-sensitive, non-coding, and checked by the existing `exact_fields` deterministic grader. The grader requires one unambiguous JSON value with the exact schema, values, and no added fields. It executes locally and consumes no provider launch slot.

The fixed judge pair follows the existing cross-family judge policy for a Google-family candidate.

## Command contract

The existing calibration entry point gains a bounded pilot mode.

```powershell
# Offline plan and validation. Zero provider launches.
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot

# Live execution. Requires separate explicit operator approval.
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot -Run -RunId option1-example-001
```

`-Pilot` without `-Run` validates the complete source calibration set, the fixed manifest, exact identities, hashes, judge mapping, and budget. It returns a deterministic plan and performs zero provider launches and zero result-directory writes.

`-Pilot -Run` is the only live Option 1 form. It rejects `-Route`, arbitrary prompt selection, arbitrary candidate selection, missing or unsafe run IDs, or any manifest drift.

Existing dry-run, route-only, and full calibration modes remain behaviorally unchanged. The new pilot mode is opt-in.

## Manifest contract

The checked-in manifest has a strict, versioned schema and contains:

- manifest version and stable pilot ID;
- mode `option_1_workflow_validation`;
- exact prompt ID and version;
- exact candidate route and composite identity;
- exact ordered judge route and composite identities;
- deterministic grader type;
- total launch budget of three;
- family budgets of one Google, one OpenAI, and one Anthropic;
- application retries of zero;
- profile promotion allowed set to false; and
- raw-content policy restricted to the synthetic prompt and credential-sanitized model outputs.

Unknown or extra manifest fields fail validation. The manifest cannot name disabled candidates, special routes, duplicate routes, duplicate families, or identities that differ from `pilot/model_matrix.json` and the exact profile catalog.

The generated plan records SHA-256 hashes of the manifest, matrix, selected candidate profile, calibration set, selected prompt definition, rubric, and relevant response schema. The live path also records the exact clean Git commit. Any drift fails before creating a launch claim.

## Components and boundaries

### Pilot orchestrator

The pilot branch lives inside `calibration/run_calibration.ps1` and reuses:

- complete calibration-set and rubric validation;
- exact profile and matrix resolution;
- the existing deterministic grader;
- the existing anonymized judge payload;
- existing cross-family judge selection;
- existing credential-safe value copying; and
- bounded calibration result paths and exclusive run claims.

It processes only the selected prompt after validating the complete 24-prompt source set.

### Candidate execution

The orchestrator resolves the pinned candidate exactly, then calls the existing `Invoke-PilotCandidate` seam directly. It does not duplicate provider commands, parsers, timeout behavior, usage parsing, or response normalization.

Because this is a calibration-only pin rather than a router decision, the pilot does not write to `routing_decisions` or `candidate_evaluations`. Its canonical evidence is the dedicated pilot result artifact.

### Launch guard

`Invoke-PilotCandidate` receives an optional launch-guard callback. Existing callers behave exactly as before when the callback is absent.

Immediately before the native provider process starts, the callback:

1. verifies the expected role, ordinal, family, launcher, model, effort, and route ID;
2. verifies the run is still live and no stop condition exists;
3. verifies the total and family budgets;
4. atomically creates a non-refundable slot-claim file with create-new semantics; and
5. persists the reserved attempt state.

If any step fails, the guard vetoes process startup. Claim files are never deleted or reused.

## Data flow

The live sequence is fixed:

1. Validate the repository state, complete calibration source, fixed manifest, candidate, prompt, rubric, judge pair, and hashes.
2. Create an exclusive run directory and initial result artifact.
3. Reserve the Google candidate slot and launch the candidate once.
4. Normalize the candidate response and run the local `exact_fields` grader.
5. Create the anonymized judge payload.
6. Reserve the OpenAI judge slot and launch Judge 1 once.
7. Normalize and persist Judge 1's decision.
8. Reserve the Anthropic judge slot and launch Judge 2 once.
9. Normalize and persist Judge 2's decision.
10. Write the final technical and quality outcomes.

No later slot can be reserved until the preceding attempt and artifact update are safely persisted.

## Budget definitions

The result distinguishes three quantities:

- `slots_consumed`: non-refundable application budget reservations created before process startup;
- `launcher_processes_started`: provider CLI processes the operating system reports as started; and
- `provider_side_requests`: unobservable, because a provider CLI may make or retry downstream requests internally.

The artifact always records:

```json
{
  "limits": {
    "total": 3,
    "provider_family": {
      "google": 1,
      "openai": 1,
      "anthropic": 1
    },
    "application_retries": 0
  },
  "provider_side_requests": {
    "observable": false,
    "count": null
  }
}
```

The application never infers provider-side request count from process count.

## Run and attempt states

Run states are:

- `planned`;
- `preflight_passed`;
- `running`;
- `completed`;
- `stopped`; and
- `indeterminate`.

Attempt states are:

- `planned`;
- `slot_reserved`;
- `process_started`;
- `succeeded`;
- `failed`; and
- `skipped`.

Terminal states cannot transition again. A stopped or indeterminate run is never resumed. Repeating the pilot requires a new safe run ID and new explicit live authorization.

## Technical failures versus quality results

A technical failure means the measurement machinery did not complete safely. Examples include:

- source or identity drift;
- authentication or quota failure;
- unsupported model or effort;
- process-start failure;
- timeout;
- cleanup failure or a process that did not exit;
- nonzero exit;
- malformed provider envelope;
- candidate or judge response-contract failure;
- result-artifact persistence failure;
- sensitive-output detection;
- budget invariant violation; and
- manual abort.

A technical failure stops the run before the next slot is reserved. The failed slot remains consumed if it was already claimed.

A quality result means the machinery completed and produced a valid negative measurement. Examples include:

- the deterministic grader returns `fail`; or
- a judge returns a valid `decision: fail` with a non-empty sanitized rationale.

Quality failures are evidence, not technical failures. The remaining authorized judge calls continue so the final artifact contains both independent decisions.

If artifact durability becomes uncertain after a provider process may have started, the run becomes `indeterminate` and no later process starts.

## Result artifacts

Each live run writes beneath one fresh ignored directory:

```text
calibration/results/<run-id>/
  .run.claim
  plan.json
  result.json
  claims/
    01-google-candidate.claim
    02-openai-judge.claim
    03-anthropic-judge.claim
  raw/
    candidate-response.json
    judge-responses.json
```

`plan.json` is immutable after preflight. It records the exact identities, order, budgets, source hashes, commit, and `selection_mode`.

`result.json` records:

- run state and safe stop reason;
- start and finish timestamps;
- manifest and source hashes;
- exact role and composite identity for each attempt;
- slot, process-start, completion, timeout, cleanup, and exit facts;
- bounded duration and available usage metadata;
- normalized transport and response-contract status;
- deterministic grader checks;
- normalized judge decisions;
- budget limits and actual counters;
- `provider_side_requests.observable: false`;
- `profile_promotion_allowed: false`; and
- technical and quality outcomes as separate fields.

The raw directory contains only the synthetic candidate answer and normalized judge JSON after credential-safe sanitization. It does not contain provider command arguments, environment values, full stdout event streams, full stderr, or arbitrary exception text. Safe error codes are allowlisted; unbounded diagnostic text is excluded.

The checked-in prompt is referenced by ID, version, and hash rather than duplicated in the run directory.

## Quality and promotion behavior

The pilot may calculate the existing conservative review proposal for diagnostic compatibility, but it must also state:

- `external_category: unknown`;
- `profile_promotion_allowed: false`;
- `profile_mutated: false`; and
- `production_eligibility_changed: false`.

Even unanimous passing evidence cannot promote this sample beyond unknown. A technically completed run can therefore coexist with a negative or non-promoting quality outcome.

## Offline test design

All new behavior is written test-first with injected fake provider functions. Offline tests must prove:

### Admission and planning

- `-Pilot` returns one deterministic three-role plan and makes zero provider calls.
- The complete 24-prompt set is validated before selecting the fixed prompt.
- Unknown manifest fields, missing fields, altered budgets, unsafe paths, duplicate identities, disabled or special routes, judge-family errors, and source-hash drift fail before launch.
- `-Pilot` combinations with `-Route` or arbitrary selectors fail before writes or calls.

### Budget enforcement

- Slot reservation occurs before native process startup.
- A failed process start still consumes its slot.
- Slots cannot be refunded, reused, reordered, or claimed twice.
- A fourth total launch and a second same-family launch are impossible.
- A launch guard can veto native process startup.
- Existing callers without a launch guard retain their current behavior.

### Success and quality paths

- The successful fake-provider path makes exactly three invocations in candidate, Judge 1, Judge 2 order.
- Exactly one process starts for each provider family.
- The exact-fields grader runs locally and consumes no launch slot.
- A deterministic quality fail still collects both valid judge decisions.
- A valid Judge 1 `fail` decision still permits Judge 2.
- Three technically successful attempts produce `completed` with exact counters.

### Technical failure paths

- Preflight failure starts zero processes.
- Candidate technical failure skips both judges.
- Judge 1 technical failure skips Judge 2.
- Judge 2 technical failure stops after the third consumed slot.
- Authentication, quota, timeout, cleanup, parse, contract, artifact, sensitive-output, and budget failures use allowlisted stop codes.
- Artifact uncertainty produces `indeterminate` and prevents every later launch.
- Stopped and indeterminate runs cannot resume.

### Privacy and integrity

- Credentials, environment values, prompt echoes in diagnostics, provider arguments, arbitrary stderr, and raw exception text do not enter artifacts.
- Exact identities, hashes, safe statuses, normalized decisions, and bounded counters remain auditable.
- The pilot never mutates profiles, snapshots, the calibration set, or production quality.
- The pilot does not create a production routing-decision trace.

## Verification and acceptance

Offline acceptance requires:

1. all new RED tests fail for the intended missing behavior before implementation;
2. all new tests pass after the minimum implementation;
3. the five existing offline suites pass:
   - pilot runner;
   - router;
   - SQLite storage;
   - calibration; and
   - calibration security;
4. `-Pilot` produces the exact one-item, three-role plan with zero provider calls;
5. a full fake-provider run produces the expected files, order, counters, decisions, and terminal state; and
6. repository diff and secret-boundary review find no unintended behavior or sensitive content.

Live acceptance is intentionally separate. After offline acceptance, the operator receives the exact commit, plan hash, command, maximum launch count, and expected identities. No live command runs until the user explicitly approves those exact three subscription-backed launches.

A live acceptance claim requires observed evidence that:

- no more than three application launch slots were consumed;
- exactly the expected provider identities were attempted in order;
- no retry or fallback was initiated by this application;
- every started process exited or was safely terminated;
- artifacts were written and sanitized as designed; and
- the result makes no quality-promotion or provider-side-request-count claim.

## Expected implementation surface

The likely bounded change set is:

- `calibration/run_calibration.ps1`;
- a checked-in manifest and strict manifest schema under `calibration/pilots/`;
- `calibration/tests/calibration.tests.ps1`;
- `calibration/tests/calibration_security.tests.ps1`;
- `pilot/lib/runner.ps1`; and
- `pilot/tests/runner.tests.ps1`.

No provider-specific adapter is duplicated. No new external dependency is introduced.
