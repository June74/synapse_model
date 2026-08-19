# Subscription-Agent Pilot Design

## Goal

Create a project-local, provider-neutral pilot scaffold that can send the same controlled task to subscription-backed agents and record normalized results without using paid APIs or local open-weight models.

## Architecture

The pilot separates four concerns:

1. `pilot/shared/experiment_contract.md` contains the common behavioral and output contract.
2. Provider instruction files point each native agent to that contract.
3. `pilot/providers.json` records provider, agent, model, effort, access mode, and launcher metadata.
4. `pilot/results/test-run.jsonl` stores one machine-readable result per execution.

The router will later read the registry, select a provider adapter, launch the provider's native agent, and append a normalized result. The initial OpenAI and Anthropic entries represent subscription-backed access verified by the user. Google is present but disabled until a supported local agent client is installed and authenticated.

## Scope and boundaries

- Project-local only; these files do not define global instructions for unrelated projects.
- No API keys, OAuth tokens, cookies, or other credentials are stored in the repository.
- The first task is a plumbing smoke test, not a quality benchmark.
- Model selection belongs in the registry or launcher configuration, not in the shared task contract.
- The initial Codex launcher may require `--skip-git-repo-check` until the local folder is initialized as a Git repository and connected to GitHub.

## Result shape

Each result record should include the run ID, provider, agent, requested model, reported model when available, requested effort, task ID, status, answer, error, and timing metadata. JSONL is used first because the router can append records easily; SQLite can be added later for querying and analysis.

## Acceptance criteria

- All planned directories and files exist under the router project.
- The shared contract is identical in intent across provider wrappers.
- The registry is valid JSON and contains no secrets.
- The smoke-test task is deterministic and does not require tools.
- The results file is ready to receive JSONL records.
