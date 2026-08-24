# Deterministic policy router V1

This router accepts one structured request, checks every enabled launcher/model/effort configuration, and deterministically chooses at most one complete configuration. Deterministic means that the same request and the same versioned catalog produce the same decision.

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
4. Latency: break an equal-price tie with lower measured end-to-end latency, except that `relaxed` skips this tie-break.
5. Stable identity: break any remaining tie by the ordinal `launcher|configuration_id` text identity.

Later factors never compensate for an earlier failure. A cheaper candidate cannot bypass requirements or quality, and a faster candidate cannot beat a cheaper eligible candidate.

## Price and `price_final`

V1 has no free tier. `price` is an API-equivalent, user-assigned policy price used to compare requests across subscription launchers. It is not a subscription fee, a claim about the user's provider bill, or production customer billing.

Before execution, `price` is calculated from estimated input, visible-output, and reasoning tokens, and `price_final` is `false`. After execution, complete trustworthy usage can replace the estimate and set `price_final` to `true`. If the launcher omits required usage details, the estimate remains and `price_final` stays `false`. A candidate without a defensible comparable price is rejected; it is never treated as free.

## Offline verification in PowerShell 7

Run commands from the repository root.

### 1. Structural checks

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

The complete structural suites are also provider-free:

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

With the checked-in snapshots used for this guide, all three requests are valid and evaluate 63 candidates in stable identity order. Repeating each complete decision is stable. Each request currently has no selected candidate: 59 candidates stop at `quality_evidence_unknown`, and four non-cost-comparable candidates stop at `price_unavailable` during requirements. Therefore no candidate reaches price or latency ranking. This is an expected conservative `no_eligible_configuration` outcome, not a fabricated successful route. The policy test suite separately exercises eligible fixtures and proves that raw price ranks before latency and stable identity.

### 4. Calibration route-only mode

Route-only mode applies the pure policy to the 24 calibration prompts and writes a bounded route-plan artifact under `calibration/results`. It executes no candidate and invokes no judge.

```powershell
pwsh -NoProfile -File .\calibration\run_calibration.ps1 -Route -RunId task10-route-only
```

Route-only can legitimately record `no_eligible_configuration` while relevant checked-in quality is unknown.

### 5. Live route-and-execute mode is gated

The following shape is intentionally not part of offline acceptance:

```powershell
# LIVE: may invoke one provider and write data/router.sqlite when a candidate is eligible.
pwsh -NoProfile -File .\router\run_router.ps1 `
  -RequestFile .\router\examples\standard-request.json
```

Run it only with explicit authorization, authenticated launchers, and approved provider spend. Calibration `-Run` is also live and gated. No live router command, calibration `-Run`, or provider smoke was performed for this documentation work.

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
