# Calibration JSON Rubric Adjudication

**Date:** 2026-08-26  
**Run:** `option1-live-20260826-002`  
**Scope:** Offline interpretation only; no provider or launcher execution and no mutation of the immutable live result.

## Question

Does a response containing the exact requested JSON inside a Markdown `json` code fence satisfy the Option 1 extraction prompt, the `exact_fields` deterministic grader contract, and the extraction rubric?

## Ruling

No. For these extraction prompts, a response passes the JSON-format check only when, after removing surrounding whitespace, the complete response parses directly as exactly one JSON object or array. Markdown fences, explanatory prose, or any other wrapper make the response noncompliant even when the enclosed value has the correct fields and values.

In plain language: valid JSON inside a code fence is recoverable JSON, but the whole answer is not itself JSON. The calibration contract requires the latter.

## Authoritative mapping

The user-visible phrase “valid JSON” maps to the complete candidate answer string, not to a JSON fragment extracted from that string.

A deterministic `exact_fields` pass therefore requires all of the following:

1. Trim surrounding whitespace only.
2. Parse the complete remaining response directly as one JSON value.
3. Require the root type declared by the prompt's grader schema.
4. Require the exact case-sensitive property names with no additions or omissions.
5. Require the exact expected values and array order.
6. Reject Markdown fences, leading or trailing prose, ambiguous multiple values, duplicate properties, and malformed JSON.

## Evidence

- `pilot/shared/experiment_contract.md` explicitly says not to wrap the result in Markdown or a code fence and to return exactly one valid JSON object.
- `calibration/calibration-set-v1.json` asks the selected prompt to “Return JSON with exactly event, date, and room.”
- `calibration/rubrics/extraction-v1.json` now requires the complete whitespace-trimmed output to parse directly and states that Markdown fences and explanatory prose fail the format criterion.
- The saved candidate answer begins with a Markdown fence. Direct `System.Text.Json` parsing of the complete trimmed answer fails; parsing succeeds only after the fence is removed.
- Before repair, `calibration/lib/grading.ps1` removed one surrounding `json` fence before parsing, so the local deterministic grader reported `pass`.
- Before repair, `calibration/tests/calibration.tests.ps1` froze that lenient behavior by expecting fenced exact JSON to pass. The repaired regression now requires fenced, uppercase-fenced, unlabeled-fenced, and prose-wrapped answers to return `review_required` with `malformed_output`, while direct JSON remains the positive control.
- The OpenAI judge evaluated the complete answer and returned `fail`; the Anthropic judge treated the fence as presentation-only and returned `pass`.

## Root cause

Before repair, the deterministic grader and its test implemented a recoverable-payload rule, while the prompt and rubric specified a complete-response rule. The judge payload repeated “valid JSON” but did not explicitly say “the complete response after whitespace trimming,” leaving room for the Anthropic judge's more lenient interpretation. The repaired grader, rubric, and regressions now use the complete-response rule consistently.

## Live-run interpretation

- Technical execution remains `completed`: all three launchers exited successfully and all provider envelopes were valid.
- The candidate extracted the correct field values but did not follow the required output format.
- The OpenAI judge's `fail` decision matches this adjudication.
- The Anthropic judge's `pass` decision used the rejected recoverable-payload interpretation.
- The persisted `review_required` outcome remains correct because the recorded graders disagreed.
- The live artifact is immutable and must not be rewritten or retroactively regraded in place.
- No quality category may be promoted from this run; production quality remains `unknown`.

## Affected scope

`Get-CalibrationJsonPayload` is used only by the `exact_fields` deterministic grader. The calibration set currently assigns that grader and `extraction-v1.json` rubric to three extraction prompts: low/general, medium/finance, and high/engineering. The same format rule should apply consistently to all three.

The offline control matrix also uncovered a separate JSON-type defect in the high/engineering prompt: PowerShell converted ISO-8601 `timestamp_utc` strings into `DateTime` objects because the calibration-set importer and candidate parser omitted `-DateKind String`. The prompt's schema correctly requires those values to remain strings. That defect is recorded and closed as `SB-20260826-175410-exact-fields-date-coercion`; it did not affect the low/general live run.

## Repair closure

The accepted interpretation is now implemented without changing the live artifact or production routing:

- RED for complete-response parsing: the functional suite exited 1 because fenced and uppercase-fenced exact JSON still returned `pass`, and the rubric wording did not state the complete-response rule. Direct JSON remained green.
- GREEN in `7f0f2bc29f605e4d14dcc17d4d31f0e16162e123` (`fix: require direct calibration JSON output`): complete whitespace-trimmed parsing is required, all fenced/prose variants return `review_required` with `malformed_output`, and the rubric states the same rule.
- RED for JSON string preservation: the functional suite exited 1 because the normal importer and immutable pilot snapshot materialized `timestamp_utc` as `System.DateTime`, and the direct high/engineering array failed the required string schema.
- GREEN in `f25a7937e629530eb24cc42c7335a093834ea32b` (`fix: preserve calibration JSON string types`): the normal importer, pilot snapshot loader, and candidate-answer parser preserve date-looking JSON strings, and the exact direct high/engineering array passes without weakening the schema.

The final offline gate passed with exit code 0 for every suite: Pilot 127 PASS with one privilege-only skip (`real final-file symbolic-link regression: Administrator privilege required for this operation.`); Router 355 PASS; SQLite 53 tests; Calibration 68 PASS; and Calibration Security 42 PASS. The focused pre-gate security run also passed 42 assertions. `git diff --check` exited 0, and no change from base `081c7351e7053703338b26f5b5a2db4a6aff0ac9` through the verified implementation head touched `profiles`, `pilot/model_matrix.json`, `router/lib/policy.ps1`, or `router/lib/quality.ps1`.

No provider, native launcher, network, live calibration, paid API, local model, or calibration `-Run` operation was used. The immutable `calibration/results/option1-live-20260826-002/result.json` was not rewritten and retains SHA-256 `b8b4cbfbe5a4122f33716efd69e8aea4bf935e69b2bc850245a4422cb19a1a7b`. This closure does not authorize a retry, regrade in place, quality promotion, eligibility change, or production-routing mutation.
