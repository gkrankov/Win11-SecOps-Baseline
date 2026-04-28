# Security Governance Runbook

This document defines minimum governance controls for safe automation changes in Win11-SecOps-Baseline.

## Branch Protection (main)

Configure repository branch protection on main with these requirements:

1. Require pull request before merging.
2. Require at least 1 approving review.
3. Require status checks to pass before merge.
4. Require branch to be up to date before merge.
5. Restrict direct pushes to main (except designated release maintainers).
6. Require signed commits if your organization policy mandates signed history.

Required status checks should include the SecDevOps CI workflow from [.github/workflows/secdevops-ci.yml](../.github/workflows/secdevops-ci.yml).

## CI Evidence Retention

Each CI run should retain evidence artifacts for audit traceability:

1. Gate summary text output.
2. Release governance files (README, changelog, controls, MITRE mapping).
3. Runtime security config files (baseline/settings/module hash manifest).

Current artifact retention is controlled in [.github/workflows/secdevops-ci.yml](../.github/workflows/secdevops-ci.yml).

## Release Control Policy

Use this sequence for every release:

1. Run `./scripts/Invoke-DevGate.ps1`.
2. Regenerate `config/module-hashes.json` via `New-ModuleHashManifest`.
3. Re-run `./scripts/Invoke-DevGate.ps1`.
4. Update [docs/CHANGELOG.md](CHANGELOG.md) with gate outcomes.
5. Create and push a release tag.

## Secret and Key Handling

1. Never store private keys in repository root or tracked paths.
2. Keep SSH private keys only in user SSH directories.
3. Ensure key-like filenames are ignored in `.gitignore`.
4. Rotate credentials immediately if accidental exposure is suspected.

## Incident and Rollback Procedure

1. Create a checkpoint before risky refactors with [scripts/New-RefactorCheckpoint.ps1](../scripts/New-RefactorCheckpoint.ps1).
2. If quality gates fail after change, restore via checkpoint rollback.
3. Record incident and remediation summary in [docs/CHANGELOG.md](CHANGELOG.md).
