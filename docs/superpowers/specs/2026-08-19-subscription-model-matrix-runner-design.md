# Subscription Model-Matrix Runner Design

## Goal

Build a small, project-local PowerShell runner that executes one controlled task against every enabled subscription-backed model/effort combination exposed through `agy`, `codex`, and `claude`, then records comparable results.

## Decisions

- Each `tool + model + effort` combination is a separate experiment candidate.
- `agy`, `codex`, and `claude` are access tools. The underlying provider and model are recorded separately.
- The first experiment uses subscription-backed native CLIs only. It does not use paid API keys, local open-weight inference, web browsing, or agent tools.
- The runner performs fan-out evaluation, not intelligent routing. It will not select a winner yet.
- The full catalog is available through an explicit `-RunAll` switch. The default invocation is a dry run so a large subscription run cannot happen accidentally.
- Candidates run sequentially in the first version to simplify diagnosis and reduce simultaneous quota pressure.
- The runner preserves contract violations rather than silently coercing model output.

## Model catalog

### Antigravity (`agy`)

The authenticated `agy models` catalog currently exposes these 14 model IDs:

- `gemini-3.7-flash-high`
- `gemini-3.7-flash-medium`
- `gemini-3.7-flash-low`
- `gemini-3.6-flash-high`
- `gemini-3.6-flash-medium`
- `gemini-3.6-flash-low`
- `gemini-3.5-flash-high`
- `gemini-3.5-flash-medium`
- `gemini-3.5-flash-low`
- `gemini-3.1-pro-high`
- `gemini-3.1-pro-low`
- `claude-sonnet-4-6`
- `claude-opus-4-6-thinking`
- `gpt-oss-120b-medium`

For Gemini IDs whose names encode an effort tier, the runner passes the matching `--effort` value. The other three entries use the explicitly registered initial effort value until their supported effort variants are separately exposed.

### Codex

The authenticated `codex debug models` catalog currently exposes these normal model slugs and effort levels:

| Model | Effort levels |
|---|---|
| `gpt-5.6-sol` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-5.6-terra` | `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `gpt-5.6-luna` | `low`, `medium`, `high`, `xhigh`, `max` |
| `gpt-5.5` | `low`, `medium`, `high`, `xhigh` |
| `gpt-5.4` | `low`, `medium`, `high`, `xhigh` |
| `gpt-5.4-mini` | `low`, `medium`, `high`, `xhigh` |
| `gpt-5.3-codex-spark` | `low`, `medium`, `high`, `xhigh` |

The catalog also exposes `codex-auto-review`. It is recorded as a special route, not a normal model, and is disabled from the ordinary task matrix until its behavior is intentionally tested.

Codex effort is configured with the installed setting key `model_reasoning_effort`, passed as a CLI configuration override such as `model_reasoning_effort=\"medium\"`.

### Claude Code

The supplied native Claude Code catalog contains these concrete model IDs:

| Model | Effort levels |
|---|---|
| `claude-opus-5` | `low`, `medium`, `high`, `xhigh`, `max` |
| `claude-sonnet-5` | `low`, `medium`, `high`, `xhigh`, `max` |
| `claude-haiku-4-5` | no effort flag |
| `claude-fable-5` | `low`, `medium`, `high`, `xhigh`, `max` |

The `inherit` value is not included as a model candidate because it means “use the parent session model,” not a concrete model identity.

## Components

### 1. Model matrix

Create `pilot/model_matrix.json` as the checked-in experiment catalog. Each candidate has:

- stable `route_id`
- `tool`
- `provider`
- exact `model`
- optional `effort`
- `candidate_kind` (`model` or `special_route`)
- `enabled`
- wrapper instruction file
- launcher-specific arguments

The matrix is explicit and auditable. A later discovery command may refresh it, but the runner never silently changes the experiment population during a run.

### 2. Runner

Create `pilot/run_pilot.ps1` with these responsibilities:

1. Read the matrix, shared contract, task, and response schema.
2. Validate that every enabled candidate has a supported tool, model, effort combination, and instruction file.
3. With no run switch, print a candidate summary and exit without invoking models.
4. With `-RunAll`, execute enabled candidates sequentially.
5. Build a provider-specific command for each candidate.
6. Pass the same task and contract to every candidate.
7. Capture stdout, stderr, exit code, and duration.
8. Parse each tool’s output envelope.
9. Validate the candidate’s inner response against `pilot/shared/response_schema.json`.
10. Append one normalized JSON object per candidate to `pilot/results/test-run.jsonl`.

The first runner will not use shell tools, web search, files, or external agent tools inside the model task. The model receives the experiment task only.

### 3. Provider parsing

- Codex JSON output is parsed from its event stream, selecting the completed agent-message text.
- Claude JSON output is parsed from its `result` field.
- Antigravity JSON output prefers `structured_output`; if absent, it parses the returned response text.
- The parser records the outer CLI envelope separately from the inner experiment object where available.
- A model response with `answer: 4` is recorded as transport success but contract failure because the contract requires `answer: "4"`.

## Result record

Each JSONL record contains:

- `run_id`
- `route_id`
- `tool`
- `provider`
- `model`
- `effort`
- `transport_success`
- `contract_compliant`
- `status`
- `answer`
- `error`
- `exit_code`
- `duration_ms`
- `cli_reported_cost_usd` when a CLI supplies that field
- a short diagnostic note when parsing or contract validation fails

The runner does not interpret a CLI-reported cost as proof of an actual charge. It records the field for later billing analysis.

## Error handling

- Missing executable: record a failed transport result and continue.
- Authentication failure: record a failed transport result and continue.
- Unsupported model/effort combination: reject the matrix before starting model calls.
- Nonzero exit code: record stdout/stderr summary and continue.
- Invalid JSON envelope: record transport success if the process exited successfully, but mark parsing and contract compliance false.
- Valid envelope with invalid inner schema: record the returned fields and mark contract compliance false.
- A single candidate failure never stops the remaining candidates.

## Testing

Use test-first development for the runner logic.

Unit tests cover:

- matrix expansion and stable route IDs
- Codex event parsing
- Claude result parsing
- Antigravity structured-output parsing
- schema validation and type violations
- missing executable and nonzero exit handling
- dry-run output
- JSONL append format

Live verification then runs one low-risk smoke task through the authenticated CLIs. A full matrix run requires the explicit `-RunAll` switch.

## Out of scope for this phase

- automatic task classification
- ranking or winner selection
- retries and fallback policy
- API-key billing
- local model inference
- parallel execution
- database storage
- production service endpoints

