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
- `calibration/rubrics/extraction-v1.json` requires that “The output is valid JSON with exactly the requested fields.”
- The saved candidate answer begins with a Markdown fence. Direct `System.Text.Json` parsing of the complete trimmed answer fails; parsing succeeds only after the fence is removed.
- `calibration/lib/grading.ps1` currently removes one surrounding `json` fence before parsing, so the local deterministic grader reported `pass`.
- `calibration/tests/calibration.tests.ps1` explicitly freezes that lenient behavior by expecting fenced exact JSON to pass.
- The OpenAI judge evaluated the complete answer and returned `fail`; the Anthropic judge treated the fence as presentation-only and returned `pass`.

## Root cause

The deterministic grader and its test implement a recoverable-payload rule, while the prompt and rubric specify a complete-response rule. The judge payload repeats “valid JSON” but does not explicitly say “the complete response after whitespace trimming,” leaving room for the Anthropic judge's more lenient interpretation.

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

The offline control matrix also uncovered a separate JSON-type defect in the high/engineering prompt: PowerShell converts ISO-8601 `timestamp_utc` strings into `DateTime` objects because the calibration-set importer and candidate parser omit `-DateKind String`. The prompt's schema correctly requires those values to remain strings, so its exact expected direct JSON array currently fails deterministic schema validation. This defect is recorded separately as `SB-20260826-175410-exact-fields-date-coercion`; it did not affect the low/general live run.

## Recommended repair boundary

If implementation is separately authorized, use test-driven development to:

1. Change the fenced exact-JSON regression from `pass` to the existing conservative malformed-output result, `review_required` with reason `malformed_output`.
2. Make `Get-CalibrationJsonPayload` parse only the complete whitespace-trimmed response and remove Markdown-fence extraction.
3. Preserve JSON date-looking strings during calibration-set import and candidate-answer parsing, and prove the high/engineering exact direct array passes without weakening its string schema.
4. Clarify the extraction rubric: the entire response must parse directly as the requested JSON value; Markdown fences and prose fail the format criterion.
5. Add cases for uppercase fence labels, unlabeled fences, leading/trailing prose, multiple JSON values, direct objects, direct arrays, and ISO timestamp strings.
6. Rerun the offline calibration functional and security suites, then all five offline suites before any future live packet.

This repair does not justify another provider call, a retry, or reuse of `option1-live-20260826-002`.
