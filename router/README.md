# Deterministic policy router V1

This router accepts one structured request, checks every enabled launcher/model/effort configuration, and deterministically chooses at most one complete configuration. Deterministic means that the same complete decision inputs and versions produce the same decision. Those inputs include the request, catalog and profile data, pricing and token estimates, runtime availability state, project instructions and context settings, and the effective pricing date. Changing any of them may legitimately change the result.

The safe offline interface is the pure `Invoke-RouterPolicy` function. It evaluates policy only: it does not invoke a provider and does not write SQLite. By contrast, running `router/run_router.ps1` directly is a live route-and-execute command when an eligible candidate exists.

## V1 boundaries

V1 supports only:

- text input and text output;
- the full lowercase language name `english`;
- one self-contained turn, with no stored conversation state;
- `low`, `medium`, or `high` complexity;
- `short`, `normal`, or `detailed` output length;
- `fast`, `normal`, or `relaxed` latency preference, with `normal` as the default;
- standard privacy and standard risk; and
- one selected model plus effort configuration.

The router calculates context size from the complete request text, project instructions, framing, and output reserve. The caller does not submit a context-size class.

V1 does not support tools, browsing, images, audio, video, multilingual input, multi-turn state, retries, or automatic fallback. If the selected launcher fails, the router returns `execution_failed`; it does not try another model. Sensitive and high-stakes requests are unsupported. In particular, do not represent a high-stakes request as `risk_level: "standard"` merely to pass validation.

## Request format

Complete examples are in [`router/examples`](examples). Every example spells out optional defaults so its behavior is visible.

| Field | Meaning and accepted values |
|---|---|
| `request_text` | The non-empty, single-turn English text to handle. |
| `task_type` | The kind of work: `general`, `coding`, `math`, `reasoning`, `writing`, `summarization`, `extraction`, or `research_synthesis`. |
| `domain` | The subject: `general`, `computer_science`, `mathematics`, `physics`, `chemistry`, `biology`, `medicine`, `engineering`, `social_science`, `humanities`, `business`, `finance`, or `law`. A domain name classifies subject matter; it does not make a high-stakes request supported. |
| `complexity` | Expected difficulty: `low`, `medium`, or `high`. |
| `quality_floor` | Minimum accepted evidence category: `standard`, `strong`, or `frontier`. |
| `latency` | Preference recorded for routing: `fast`, `normal`, or `relaxed`; defaults to `normal`. Price still ranks before latency in V1. |
| `privacy_level` | V1 accepts only `standard`. |
| `risk_level` | V1 accepts only `standard`; high-stakes work is unsupported. |
| `output_length` | Requested answer size: `short`, `normal`, or `detailed`; defaults to `normal`. |
| `language` | V1 accepts only `english`, written exactly this way. |
| `additional_capabilities` | Optional extra requirements. Allowed values are `instruction_following`, `reasoning`, `structured_output`, `factual_reliability`, `source_grounded_synthesis`, and `long_context`; defaults to `[]`. |

The router also derives capabilities from the request. For example, medium- or high-complexity coding adds `reasoning`, and a non-general domain adds `factual_reliability`.

## Quality categories

Quality is categorical rather than a numeric score:

- `unsupported`: the configuration is known not to provide the required function, so it fails requirements.
- `unknown`: evidence for an exact model/effort and relevant quality area is insufficient. Unknown is not a low score; it fails every requested quality floor.
- `standard`: measured and confirmed as adequate for the relevant area.
- `strong`: above standard for the relevant area.
- `frontier`: in the top-performing relevant evidence group.

The order is `standard < strong < frontier`. The router checks the task type, domain, complexity, and every required capability. The lowest relevant category becomes the effective quality. The `quality_bottleneck` is the exact area that produced that lowest category, such as `complexity.medium`.

Current route-only calibration may legitimately return `no_eligible_configuration`. The checked-in quality evidence can remain `unknown` until exact external evidence and internal calibration support a category. The router must fail closed instead of inventing quality.

## Selection order

Every model and effort pair is one complete candidate. The router does not choose a model first and effort second. It applies this order:

1. Requirements: reject unsupported boundaries, unavailable configurations, insufficient context/output windows, missing capabilities, and non-comparable prices.
2. Quality floor: reject unknown evidence or an effective quality below the requested floor.
3. Price: choose the lowest estimated request price among survivors.
4. Latency: break an equal-price tie with lower measured end-to-end latency. V1 treats `fast` and `normal` identically: both use this tie-break. `relaxed` skips it.
5. Stable identity: break any remaining tie by the ordinal `launcher|configuration_id` text identity.

Later factors never compensate for an earlier failure. A cheaper candidate cannot bypass requirements or quality, and a faster candidate cannot beat a cheaper eligible candidate.

## Price and `price_final`

V1 has no free tier. `price` is an API-equivalent, user-assigned policy price used to compare requests across subscription launchers. It is not a subscription fee, a claim about the user's provider bill, or production customer billing.

Before execution, `price` is calculated from estimated input, visible-output, and reasoning tokens, and `price_final` is `false`. After execution, complete trustworthy usage can replace the estimate and set `price_final` to `true`. If the launcher omits required usage details, the estimate remains and `price_final` stays `false`. A candidate without a defensible comparable price is rejected; it is never treated as free.

## Offline verification in PowerShell 7

Run commands from the repository root.

### 1. Schema-only structural validation

Structural checks parse files and validate schemas. They do not route or invoke a provider.

```powershell
$schema = Join-Path $PWD 'router/schemas/request-profile.schema.json'
. (Join-Path $PWD 'router/lib/schema.ps1')
Get-ChildItem -LiteralPath (Join-Path $PWD 'router/examples') -Filter '*.json' |
  Sort-Object Name |
  ForEach-Object {
    $request = Get-Content -Raw -LiteralPath $_.FullName |
      ConvertFrom-Json -Depth 100 -NoEnumerate
    $validation = Test-RouterSchema -Value $request -SchemaPath $schema
    if (-not $validation.valid) {
      $validation.errors | ConvertTo-Json -Depth 20
      throw "Schema validation failed: $($_.Name)"
    }
    "PASS $($_.Name)"
  }
```

The broader offline behavioral suites are also provider-free. Unlike the schema-only check above, these suites exercise policy, storage, calibration, and fake-executor behavior:

```powershell
pwsh -NoProfile -File .\pilot\tests\runner.tests.ps1
pwsh -NoProfile -File .\router\tests\router.tests.ps1
. .\router\lib\trace.ps1
$python = Resolve-RouterPythonExecutable
if ([string]::IsNullOrWhiteSpace($python)) { throw 'Python runtime not found.' }
& $python -m unittest router.storage.test_sqlite_store
pwsh -NoProfile -File .\calibration\tests\calibration.tests.ps1
```

### 2. Calibration dry run

With no switch, calibration prints a deterministic plan. It invokes neither the router nor a judge model.

```powershell
pwsh -NoProfile -File .\calibration\run_calibration.ps1
```

### 3. Request policy dry run

This command runs the three example requests twice through the pure policy. It compares the full normalized decisions, inspects candidate order and rejection details, and confirms whether price or latency was reached. It invokes zero providers and writes no trace database.

```powershell
. .\router\run_router.ps1

$catalog = Import-RouterProfileCatalog `
  -ProfilesRoot .\profiles `
  -MatrixPath .\pilot\model_matrix.json `
  -ProfileSchemaPath .\router\schemas\model-profile.schema.json `
  -PricingSnapshotPath .\router\data\pricing-snapshot-2026-08-22.json `
  -QualitySnapshotPath .\router\data\quality-snapshot-2026-08-22.json
if (-not $catalog.valid) {
  $catalog.errors | ConvertTo-Json -Depth 20
  throw 'Profile catalog validation failed.'
}

$pricing = Get-Content -Raw -LiteralPath .\router\data\pricing-snapshot-2026-08-22.json |
  ConvertFrom-Json -Depth 100
$tokenEstimates = New-RouterTokenEstimateDocument -Profiles @($catalog.profiles)

Get-ChildItem -LiteralPath .\router\examples -Filter '*-request.json' |
  Sort-Object Name |
  ForEach-Object {
    $request = Get-Content -Raw -LiteralPath $_.FullName |
      ConvertFrom-Json -Depth 100 -NoEnumerate
    $policyArguments = @{
      Request = $request
      Profiles = @($catalog.profiles)
      PricingSnapshot = $pricing
      TokenEstimates = $tokenEstimates
      AsOfDate = [string]$pricing.snapshot_date
    }
    $first = Invoke-RouterPolicy @policyArguments
    $second = Invoke-RouterPolicy @policyArguments
    $stable = (($first | ConvertTo-Json -Depth 100 -Compress) -ceq
      ($second | ConvertTo-Json -Depth 100 -Compress))
    if (-not $stable) { throw "Unstable policy result: $($_.Name)" }

    $evaluations = @($first.candidate_evaluations)
    $identities = @($evaluations.candidate_identity)
    $sortedIdentities = @($identities)
    [Array]::Sort($sortedIdentities, [StringComparer]::Ordinal)

    [pscustomobject][ordered]@{
      example = $_.Name
      request_valid = $first.request_validation.valid
      selected_candidate = if ($null -eq $first.selected_candidate) {
        $null
      } else {
        '{0}|{1}' -f $first.selected_candidate.launcher,
          $first.selected_candidate.configuration_id
      }
      repeated_decision_stable = $stable
      candidate_count = $evaluations.Count
      candidate_order_stable = ([string]::Join("`n", $identities) -ceq
        [string]::Join("`n", $sortedIdentities))
      rejection_reasons = @($evaluations |
        ForEach-Object { $_.rejection_reason_codes } |
        Group-Object | Sort-Object Name |
        ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join '; '
      quality_bottlenecks = @($evaluations |
        Where-Object { $null -ne $_.quality } |
        Group-Object { $_.quality.quality_bottleneck } | Sort-Object Name |
        ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join '; '
      candidates_reaching_price = @($evaluations |
        Where-Object { $null -ne $_.price }).Count
      candidates_reaching_latency = @($evaluations |
        Where-Object { $_.latency_available }).Count
    }
  } | Format-List
```

Task 10 used two complementary offline checks. First, at commit `d588f07`, the checked-in production snapshots made all three requests valid and produced 63 candidate evaluations in stable identity order. Repeating each complete decision was stable. Each request had no selected candidate: 59 candidates stopped at `quality_evidence_unknown`, and four non-cost-comparable candidates stopped at `price_unavailable` during requirements. Therefore no candidate reached price or latency ranking. These `63/59/4` counts are a snapshot-specific observation at that commit and may change when profiles or snapshots change. The conservative `no_eligible_configuration` result was expected, not a fabricated successful route.

Second, an eligible-fixture acceptance check exercised ranking after requirements and quality. For each `standard`, `strong`, and `frontier` quality floor, it ran 20 repeated pure-policy decisions across both forward and reverse candidate input orders:

- `standard` always selected `agy|shared-model__medium` and demonstrated that its price `0.00384` ranked ahead of `0.00618` for `codex|shared-model__medium`.
- `strong` always selected `codex|shared-model__medium` with strong effective quality; the agy fixture was rejected with `quality_floor_not_met`.
- `frontier` always selected `codex|shared-model__medium` with frontier effective quality; the strong agy fixture was rejected with `quality_floor_not_met`.
- Every winner reported `task_type.coding` as its quality bottleneck, and the complete acceptance made zero provider calls.

The `shared-model` identities and prices are synthetic acceptance fixtures—small controlled examples used to prove policy behavior—not claims about production models or current provider prices. Together, the checked-in snapshot check proves conservative production rejection when evidence is unknown, while the eligible-fixture check proves stable winner selection, quality-floor enforcement, price ordering, and input-order independence when candidates can reach ranking.

The 20-decision matrix was an ad hoc Task 10 acceptance run; the maintained suite does not claim to repeat that historical matrix exactly. Future maintainers can reproduce its core guarantees with the already documented command `pwsh -NoProfile -File .\router\tests\router.tests.ps1`. The relevant named tests are:

- Quality-floor category ordering across all three floors and all three candidate categories:
  - `quality floor standard evaluates category standard by standard less than strong less than frontier`
  - `quality floor standard evaluates category strong by standard less than strong less than frontier`
  - `quality floor standard evaluates category frontier by standard less than strong less than frontier`
  - `quality floor strong evaluates category standard by standard less than strong less than frontier`
  - `quality floor strong evaluates category strong by standard less than strong less than frontier`
  - `quality floor strong evaluates category frontier by standard less than strong less than frontier`
  - `quality floor frontier evaluates category standard by standard less than strong less than frontier`
  - `quality floor frontier evaluates category strong by standard less than strong less than frontier`
  - `quality floor frontier evaluates category frontier by standard less than strong less than frontier`
- Price and quality ordering: `cheaper frontier beats more expensive strong after both pass the quality floor`.
- Price before latency: `price strictly outranks latency`.
- Forward/reverse input-order stability: `policy selection is invariant to forward and reverse tied input order`.
- Exactly one winner: `policy selects exactly one candidate`.

### 4. Calibration route-only mode

Route-only mode applies the pure policy to the 24 calibration prompts and writes a bounded route-plan artifact under `calibration/results`. It executes no candidate and invokes no judge. When `-RunId` is omitted, the script generates a unique run ID and a corresponding unique artifact directory, so the command can be repeated without reusing a fixed result path.

```powershell
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Route
```

Route-only can legitimately record `no_eligible_configuration` while relevant checked-in quality is unknown.

### 5. Live route-and-execute mode is gated

The following shape is intentionally not part of offline acceptance:

```powershell
# LIVE: may invoke one provider and write data/router.sqlite when a candidate is eligible.
pwsh -NoProfile -File .\router\run_router.ps1 `
  -RequestFile .\router\examples\standard-request.json
```

Run it only with explicit authorization, authenticated launchers, and approved provider spend. Calibration `-Run` is also live and gated.

On 2026-08-25, Task 10 performed an explicitly authorized subscription-backed smoke test through the real router execution and normalization path. Because the production quality snapshot still conservatively marks candidates `unknown`, the acceptance harness injected temporary in-memory `standard` quality and small synthetic token estimates; it did not modify production profiles or snapshots. The harness restricted each run to one candidate and used a temporary SQLite database:

- Agy selected `agy|gemini-3.7-flash-low__low` and completed one call.
- Codex selected `codex|gpt-5.6-luna__low` and completed one call.
- Claude selected `claude|claude-haiku-4-5__default` and completed one call with effort omitted at the launcher boundary.

All three runs stored one selected candidate evaluation, a completed status, version fields, and 64-character prompt and response hashes with no storage error. Inspection found three decisions and three candidate evaluations, null prompt/response content, and no raw prompt, credential, authorization-header, or environment-dump markers. Agy and Codex supplied complete trustworthy usage and produced `price_final: true`; Claude did not supply a complete reasoning split, so its estimate correctly remained `price_final: false`. No fallback, calibration `-Run`, paid API, local model, push, PR, or merge occurred. The temporary harness and database were removed after inspection.

## Option 1 three-launch calibration pilot

Option 1 is a small, fixed calibration pilot. Its purpose is to collect bounded technical and quality evidence without changing production routing. Start with the offline command:

```powershell
# Offline validation and deterministic plan: zero provider launches and zero result writes
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot
```

The offline plan validates the frozen sources, hashes them, and prints the exact ordered roles. It starts no provider process, consumes no launcher slot, and writes no result directory.

The live command is frozen as follows, but it must not be run merely because it is documented:

```powershell
# Live only after explicit approval of the exact commit and exact ordered identities
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Pilot -Run -RunId option1-live-20260825-001
```

Running that exact command requires separate explicit approval of the exact commit and exact ordered identities in the final acceptance packet. Approval of development or offline tests is not approval to execute the live command.

The fixed pipeline performs candidate execution, a local deterministic grader, and two independent cross-family judges in this order:

1. Google candidate: `agy__gemini_3_7_flash_low__low`.
2. Local exact-fields grading. This local deterministic grader does not consume a launcher slot.
3. OpenAI Judge 1: `codex__gpt_5_6_sol__max`.
4. Anthropic Judge 2: `claude__claude_opus_5__max`.

The local grade runs between the candidate and the judges but is not a provider launch. Therefore, a technically successful run consumes a maximum of three non-refundable application launch slots: one candidate slot and one slot for each judge. A slot is durably claimed before its application process starts. If launch or execution later fails, the claim remains consumed; it is never refunded or reused.

Application launch slots are a local safety ceiling, not a claim about provider-internal behavior. The pilot records `provider_side_requests.observable: false` and `provider_side_requests.count: null` because a launcher does not reveal how many provider-side requests or internal retries it may make.

No retry, fallback, or resume is allowed. The pilot never substitutes another model, repeats a role, adds a fourth launch, or continues after a technical stop. A stopped or indeterminate run requires a new RunId and new explicit approval; the same run ID cannot be resumed. The current build accepts only `option1-live-20260825-001`. Do not edit the command to invent a replacement RunId. A replacement RunId requires a new reviewed build that accepts it and a revised acceptance packet that freezes and authorizes the exact replacement command, followed by new explicit approval.

On a technically completed run, the complete persistent shape of the bounded safe artifacts is:

- `.run.claim`: the exclusive run claim;
- `plan.json`: the immutable source, budget, identity, and commit plan;
- `result.json`: the durable technical-state and separate quality ledger;
- `claims/01-google-candidate.claim`, `claims/02-openai-judge.claim`, and `claims/03-anthropic-judge.claim`: the three ordered, non-refundable slot claims;
- `raw/candidate-response.json`: only `item_id`, `status`, credential-sanitized `output`, and bounded `error_code`; and
- `raw/judge-responses.json`: only `item_id`, the anonymized judge payload, and accumulated normalized decisions.

A stopped or indeterminate run may contain only the prefix of that shape that was durably written before the stop; missing later claims or raw files do not refund a consumed slot. The safe artifacts omit credentials, command arguments, environment dumps, raw provider event streams, arbitrary standard output or error text, exception text, and prompt-echo diagnostics. Cleanup-indeterminate exceptional residue may include an owned `.result-*.tmp` or `.raw-*.tmp` file. The operator must not delete that residue, resume or retry the run, or reuse its RunId automatically. Preserve the complete run directory for review; a later replacement still requires the new reviewed build, revised acceptance packet, and new explicit approval described above.

Pilot evidence is observational only. Results never promote production quality, never mutate model profiles, and never change production eligibility. External quality remains `unknown` unless a later, separately designed evidence-promotion process is approved and implemented.

## Decision trace lookup

A live route returns `decision_trace_id` only when trace storage succeeds. Normal traces are stored in `data/router.sqlite`; they retain structured metadata and content hashes, not request or response text. Policy dry runs do not create SQLite traces, and calibration route-only mode writes its separate JSON route-plan artifact.

After an authorized live route has created the database, inspect recent decisions with the repository's resolved Python runtime:

```powershell
. .\router\lib\trace.ps1
$python = Resolve-RouterPythonExecutable
$database = (Resolve-Path .\data\router.sqlite).Path
& $python -c 'import json, sqlite3, sys; db = sqlite3.connect(sys.argv[1]); db.row_factory = sqlite3.Row; rows = db.execute("SELECT trace_id, created_at, output_status, reason_code, selected_candidate_identity, effective_quality, quality_bottleneck, price, price_final, latency_ms, candidate_count FROM routing_decisions ORDER BY created_at DESC LIMIT 10").fetchall(); print(json.dumps([dict(row) for row in rows], indent=2))' $database
```

Use one returned trace ID to inspect every candidate considered for that decision:

```powershell
$traceId = 'route_replace_with_a_real_trace_id'
& $python -c 'import json, sqlite3, sys; db = sqlite3.connect(sys.argv[1]); db.row_factory = sqlite3.Row; rows = db.execute("SELECT candidate_identity, eligible, selected, rejection_stage, rejection_reason_codes_json, requirements_passed, quality_passed, effective_quality, quality_bottleneck, price, price_final, latency_available, latency_ms FROM candidate_evaluations WHERE trace_id = ? ORDER BY candidate_identity", (sys.argv[2],)).fetchall(); print(json.dumps([dict(row) for row in rows], indent=2))' $database $traceId
```
