# Deterministic Policy Router V1 Design

## Goal

Build a project-local deterministic router that accepts one structured, text-only request, evaluates every enabled launcher/model/effort configuration as a complete candidate, selects exactly one candidate, executes it through the existing native CLI adapters, and records an auditable decision trace.

The V1 router is a policy layer on top of the existing subscription model-matrix runner. It does not use a learned classifier, paid API keys, local open-weight inference, tools, fallback routing, or multi-model answer generation.

## Core decisions

- A candidate is the complete combination of launcher, exact model, and effort level.
- The router ranks model and effort jointly. It never chooses a model first and effort second.
- `configuration_id` contains only model and effort, for example `gpt-5.6-sol__high`. Launcher and provider are separate fields.
- The router selects exactly one candidate.
- The strict decision order is requirements, quality floor, price, latency, then stable identity.
- Quality uses provisional categorical estimates in V1: `unknown`, `standard`, `strong`, and `frontier`.
- The lowest relevant quality category is the effective quality.
- V1 has no free-tier routes. The response contains one `price`, representing the amount charged for the request under the V1 API-equivalent pricing policy.
- V1 remains project-local under `C:\Users\2006i\projects\router_model`.

## V1 scope

V1 supports:

- text input and text output
- English only
- single-turn requests
- standard privacy requests
- standard-risk requests
- OpenAI, Anthropic, and Google model families exposed through `codex`, `claude`, and `agy`
- one selected model/effort configuration

V1 does not support:

- images, audio, video, or other modalities
- multilingual requests
- multi-turn conversation state
- tools or web browsing inside the selected model task
- sensitive requests
- high-stakes requests
- retries or automatic fallback to another model
- paid API execution
- local open-weight inference
- production customer billing

High-stakes requests remain unsupported in V1. A later version may support them with a clear professional-advice disclaimer and additional safeguards.

## Structured request profile

The router accepts a validated request object with these fields:

```json
{
  "request_text": "Explain why this algorithm fails on an empty list.",
  "task_type": "coding",
  "domain": "computer_science",
  "complexity": "medium",
  "quality_floor": "strong",
  "latency": "normal",
  "privacy_level": "standard",
  "risk_level": "standard",
  "output_length": "normal",
  "language": "english",
  "additional_capabilities": []
}
```

Allowed `task_type` values:

- `general`
- `coding`
- `math`
- `reasoning`
- `writing`
- `summarization`
- `extraction`
- `research_synthesis`

Allowed `domain` values:

- `general`
- `computer_science`
- `mathematics`
- `physics`
- `chemistry`
- `biology`
- `medicine`
- `engineering`
- `social_science`
- `humanities`
- `business`
- `finance`
- `law`

Other enums:

- `complexity`: `low`, `medium`, `high`
- `quality_floor`: `standard`, `strong`, `frontier`
- `latency`: `fast`, `normal`, `relaxed`; default `normal`
- `privacy_level`: V1 accepts only `standard`
- `risk_level`: V1 accepts only `standard`
- `output_length`: `short`, `normal`, `detailed`; default `normal`
- `language`: V1 accepts only the full lowercase name `english`

The router calculates required context size from the complete prompt, project instructions supplied to the selected launcher, and output reserve. The caller does not provide a context-size classification.

## Derived capabilities

The V1 capability vocabulary is:

- `instruction_following`
- `reasoning`
- `structured_output`
- `factual_reliability`
- `source_grounded_synthesis`
- `long_context`

Initial derivation rules:

| Request characteristic | Added capability |
|---|---|
| Every request | `instruction_following` |
| `task_type` is `math` or `reasoning` | `reasoning` |
| Coding with medium or high complexity | `reasoning` |
| `task_type` is `extraction` | `structured_output` |
| `task_type` is `summarization` | `factual_reliability` |
| `task_type` is `research_synthesis` | `factual_reliability`, `source_grounded_synthesis` |
| Any non-general domain | `factual_reliability` |
| Calculated context exceeds the calibrated long-context threshold | `long_context` |

Explicit `additional_capabilities` are unioned with the derived set. Tools, modalities, and languages are not represented as V1 capabilities because they are outside V1 scope.

## Candidate identity and profiles

Profiles are checked-in JSON files under launcher-specific directories:

```text
profiles/
  codex/
    gpt-5.6-sol__max.json
  claude/
    claude-opus-5__max.json
  agy/
    gemini-3.7-flash__high.json
```

The composite runtime identity is `(launcher, configuration_id)`. This allows the same model/effort pair to be evaluated separately through different launchers without adding access mode to `configuration_id`.

Every profile must explicitly cover every V1 task type, domain, complexity level, and capability. Omitted coverage is a schema error; unknown evidence must be written explicitly as `unknown`.

A profile contains:

- schema and profile versions
- `configuration_id`, `launcher`, `provider`, exact invocation model, and effort
- enabled state
- supported text behavior, language, context window, and maximum output
- explicit categorical quality maps
- input and output token rates used to calculate request price
- latency and token-consumption observations
- Artificial Analysis and provider evidence
- calibration status and version

`unsupported` is distinct from `unknown`:

- `unsupported` means the configuration is known not to provide a required function and fails requirements.
- `unknown` means evidence is insufficient and fails quality eligibility for any request that needs that category.

## Hard requirements

Requirements are pass/fail and cannot be compensated for by quality, price, or latency.

The request must:

- satisfy the request JSON Schema
- remain within the V1 text, English, and single-turn boundary
- use standard privacy and standard risk
- use supported task, domain, complexity, output-length, and capability values

The candidate must:

- be enabled
- identify an exact available launcher/model/effort combination
- have a working authenticated launcher at execution time
- support text input and output, English, and single-turn operation
- fit the calculated context and requested output reserve
- support every derived and explicitly requested capability
- have a defensible price rate for automatic price comparison
- not be unavailable or quota-exhausted at execution time

If no candidate passes, the router returns a structured failure. It never relaxes a hard requirement silently.

## Provisional quality policy

V1 uses these ordered categories:

```text
standard < strong < frontier
```

`unknown` is not a lower quality score. It means the candidate is not eligible for a request requiring that evidence.

For a request, relevant categories include:

- the request task type
- the request domain
- the request complexity
- every required capability

The effective quality is the lowest relevant category. The router also records the category that caused this minimum as `quality_bottleneck`.

Example:

```text
coding: strong
computer_science: strong
medium complexity: standard
reasoning: frontier

effective quality: standard
quality bottleneck: complexity.medium
```

The candidate passes only if its effective quality is at least the requested quality floor.

### External evidence

Artificial Analysis is the primary external benchmark source for V1 provisional quality, token-use, and latency evidence. Provider documentation is used for technical capabilities and official token rates, not as the sole evidence of model quality.

Artificial Analysis results are mapped provisionally as follows:

- `frontier`: part of the top-performing cluster in the relevant benchmark
- `strong`: clearly above the median of the enabled V1 pool
- `standard`: measured and internally confirmed as adequate
- `unknown`: exact evidence is missing, mismatched, or contradictory

The router must use relevant evaluation slices rather than applying the overall Intelligence Index to every task. Artificial Analysis explicitly describes its current Intelligence Index as a weighted combination of Agents, Coding, Scientific Reasoning, and General categories and warns that a composite metric may not apply directly to every use case: https://artificialanalysis.ai/methodology/intelligence-benchmarking

The near-free V1 uses dated public snapshots. Artificial Analysis's machine-readable data API is treated as a future commercial integration, not a current dependency: https://artificialanalysis.ai/data-api

### Internal calibration

The calibration set contains 24 shared prompts:

```text
8 task types x 3 complexity levels = 24 prompts
```

The 13 domains are distributed across these prompts. Calibration is a reality check, not the full benchmark and not every task/domain cross-product.

Objective outputs use deterministic graders where possible:

- coding: executable tests
- mathematics and science: verified answers and required reasoning steps
- extraction: schema and exact-field checks
- summarization: required facts, omissions, and unsupported-claim checks
- writing and research synthesis: explicit rubrics

Subjective outputs use two anonymized cross-family judges:

- OpenAI judge: `gpt-5.6-sol__max`
- Anthropic judge: `claude-opus-5__max`
- Google judge: `gemini-3.7-flash-high`

Candidate-family judge pairs:

| Candidate family | Judges |
|---|---|
| OpenAI or GPT-OSS | Anthropic and Google |
| Anthropic | OpenAI and Google |
| Google | OpenAI and Anthropic |

The candidate model name, provider, effort, price, and latency are hidden from judges.

Calibration result policy:

- both judges pass: retain the external category
- both judges fail: set the relevant category to `unknown`
- judges disagree: set the relevant category to `unknown` pending review

Calibration may confirm a category or make it unknown. It cannot upgrade a category beyond the external evidence. A calibration failure never means `unsupported`.

## Price policy

The response exposes one request-level field:

```json
"price": 0.0137
```

V1 has no free-tier candidates. Subscription launchers are treated as if they incurred their API-equivalent token prices so the policy can compare economic efficiency. The per-request `price` is the amount assigned to the user under this V1 policy; it is not a second reference/effective price pair.

The internal profile still stores input and output unit rates because they are required to calculate the single request price.

Before execution:

```text
estimated price =
  (estimated input tokens x input rate
   + estimated billable output tokens x output rate)
  / 1,000,000
```

Estimated billable output includes expected visible output and reasoning/thinking tokens. Token-consumption estimates are maintained separately for every exact model/effort and request-profile grouping. Initial estimates come from Artificial Analysis and calibration observations; the full benchmark later replaces them.

After execution:

- complete usage metadata: calculate actual price and set `price_final: true`
- incomplete usage metadata: retain the benchmark-based estimate and set `price_final: false`

V1 does not claim an exact price when a launcher omits hidden reasoning-token usage.

### Price catalog snapshot

V1 uses official standard, synchronous, uncached text rates and time-bounded schedules. The approved August 22, 2026 snapshot includes:

| Model | Input / 1M | Output / 1M | Notes |
|---|---:|---:|---|
| GPT-5.6 Luna | $0.20 | $1.20 | Official OpenAI rate |
| GPT-5.4 Mini | $0.75 | $4.50 | Official OpenAI rate |
| GPT-5.6 Terra | $2.00 | $12.00 | Official OpenAI rate |
| GPT-5.4 | $2.50 | $15.00 | Official OpenAI rate |
| GPT-5.6 Sol | $4.00 | $20.00 | Official OpenAI rate |
| GPT-5.5 | $5.00 | $30.00 | Official OpenAI rate |
| GPT-5.3 Codex Spark | unknown | unknown | No public Spark API price; not cost-comparable |
| Claude Haiku 4.5 | $1.00 | $5.00 | Official Anthropic rate |
| Claude Sonnet 5 | $2.00 | $10.00 | Promotional through 2026-08-31; then $3/$15 |
| Claude Sonnet 4.6 | $3.00 | $15.00 | Official Anthropic rate |
| Claude Opus 5 | $5.00 | $25.00 | Official Anthropic rate |
| Claude Opus 4.6 | $5.00 | $25.00 | Official Anthropic rate |
| Claude Fable 5 | $10.00 | $50.00 | Official Anthropic rate |
| Gemini 3.7 Flash | $0.75 | $3.75 | Promotional through 2026-12-31; then $1.50/$7.50 |
| Gemini 3.6 Flash | $0.75 | $3.75 | Promotional through 2026-12-31; then $1.50/$7.50 |
| Gemini 3.5 Flash | $1.50 | $9.00 | Official Google rate |
| Gemini 3.1 Pro <=200K input | $2.00 | $12.00 | $4/$18 above 200K input |
| GPT-OSS 120B | $0.15 | $0.60 | Hosted API equivalent corroborated by Groq, Together, and Fireworks |

Different effort levels share the model's per-token rate but receive separate expected token consumption and therefore separate request-price estimates.

## Deterministic selection algorithm

The exact order is:

```text
1. Validate the request and derive requirements.
2. Remove candidates that fail any hard requirement.
3. Remove candidates whose effective quality is unknown or below quality_floor.
4. Calculate price for each surviving complete model/effort candidate.
5. Select the lowest-price candidate.
6. Break equal-price ties with lower measured end-to-end latency.
7. Break any remaining tie with stable composite identity.
```

Latency is not a hard V1 limit. It is evaluated after price. A cheaper eligible relaxed-latency candidate beats a more expensive fast candidate. The request's `latency` value is recorded for future policy refinement; V1 always prefers lower measured latency at the latency tie-break. `relaxed` may skip that tie-break and proceed to stable identity.

The stable final tie-break must make identical inputs against identical versioned profiles produce the same selected configuration.

## Output contract

Successful route-and-execute response:

```json
{
  "status": "completed",
  "configuration_id": "gpt-5.6-luna__max",
  "provider": "openai",
  "launcher": "codex",
  "model": "gpt-5.6-luna",
  "effort": "max",
  "output": "Normalized model response",
  "quality_floor": "strong",
  "effective_quality": "strong",
  "quality_bottleneck": "reasoning",
  "price": 0.0137,
  "price_final": false,
  "latency": 12.4,
  "decision_trace_id": "route_123"
}
```

`latency` is measured in seconds in the public response. The internal trace may retain millisecond precision.

Supported top-level failure statuses:

- `invalid_request`
- `unsupported_request`
- `no_eligible_configuration`
- `execution_failed`

Supported reason codes include:

- `unsupported_language`
- `unsupported_modality`
- `sensitive_request_unsupported`
- `high_stakes_unsupported`
- `context_too_large`
- `required_capability_unavailable`
- `quality_floor_not_met`
- `quality_evidence_unknown`
- `all_routes_unavailable`
- `launcher_execution_failed`

A concise response includes `decision_trace_id`; detailed candidate evaluations remain in local trace storage.

## Execution handoff

```text
Structured request
  -> deterministic router
  -> one selected launcher/model/effort candidate
  -> existing provider-specific launcher adapter
  -> normalized response
  -> finalize price and latency where telemetry permits
  -> write decision trace
  -> return response
```

Only the selected candidate runs. If its launcher fails, V1 returns `execution_failed` and records the failure. It does not select a second candidate.

The existing provider parser behavior remains authoritative:

- Codex: completed agent-message text from the JSON event stream
- Claude: inner `result` from the JSON envelope
- Antigravity: `structured_output` when available, otherwise parsed response text

## Decision trace storage

Runtime traces are stored project-locally at:

```text
data/router.sqlite
```

The database is excluded from Git. Versioned profiles and schemas are committed.

Primary tables:

- `routing_decisions`: validated request profile, winner, output status, quality, price, latency, versions, and trace metadata
- `candidate_evaluations`: one row per considered candidate with requirement result, quality result, price, latency, and rejection reason

Normal routing stores structured metadata and hashes of request/response content, not full text. Calibration and benchmark runs may store full prompts and outputs because grading and reproducibility require them. Credentials, authentication codes, and environment variables are never stored.

## Versioning and reproducibility

Every decision records:

- `router_policy_version`
- `profile_schema_version`
- `model_profile_version`
- `pricing_snapshot_date`
- `quality_snapshot_date`
- `calibration_set_version`

Historical traces are not silently recalculated when profiles or prices change.

## Acceptance criteria

V1 is accepted when:

- all request and profile schemas reject malformed or incomplete records
- every checked-in profile explicitly covers all V1 quality dimensions
- model and effort are evaluated jointly
- identical inputs and versions produce the same selected candidate
- requirements, quality, price, latency, and identity are applied in the approved order
- unknown quality cannot cross any quality floor
- one and only one eligible candidate is selected
- no fallback occurs after execution failure
- normalized responses and structured failures conform to schema
- SQLite records the winner and every considered candidate without storing credentials
- full unit tests and one live smoke route through each authenticated launcher pass
