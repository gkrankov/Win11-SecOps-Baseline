# Win11-SecOps-Baseline

[![PowerShell](https://img.shields.io/badge/PowerShell-PLACEHOLDER-blue)](https://learn.microsoft.com/powershell/)
[![Windows 11](https://img.shields.io/badge/Windows%2011-PLACEHOLDER-0078D4)](https://www.microsoft.com/windows/windows-11)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Win11-SecOps-Baseline** is a PowerShell-driven security baseline toolkit for Windows 11 that helps teams harden endpoints, detect security drift, and measure posture with repeatable evidence.

## Current Version

- Version: **0.2.0**
- Release date: **2026-04-28**
- Baseline tag: **v0.2.0-baseline-locked**
- Latest gate baseline:
   - Parse Check: PASS (25 files)
   - Test Suite: PASS (49/49)
   - Integrity Check: PASS (9 files verified)
   - Exit code: 0

See [docs/CHANGELOG.md](docs/CHANGELOG.md) for full release details.

## Problem Statement

Security teams often face three recurring issues:
1. Hardening is applied inconsistently across endpoints.
2. Configuration drift reintroduces risk after initial rollout.
3. Leadership lacks concise, auditable proof of control effectiveness.

This project addresses those gaps by combining **baseline enforcement**, **drift detection**, and **posture scoring** into a single operational workflow suitable for both engineering execution and management reporting.

## Architecture (ASCII)

```text
                          +-----------------------+
                          |  config\baseline.json |
                          +-----------+-----------+
                                      |
                          +-----------v-----------+
                          |  Invoke-SecBaseline   |
                          |   01-hardening.ps1    |
                          +-----------+-----------+
                                      |
        +-----------------------------+-----------------------------+
        |                             |                             |
+-------v-------+             +-------v-------+             +-------v-------+
|  modules\     |             |  modules\     |             |  modules\     |
| AuditPolicies |             |   Firewall    |             | UserAccounts  |
+-------+-------+             +-------+-------+             +-------+-------+
        |                             |                             |
        +-----------------------------+-----------------------------+
                                      |
                          +-----------v-----------+
                          |  modules\WindowsDef.  |
                          |  modules\NetworkHard. |
                          +-----------+-----------+
                                      |
                    +-----------------+------------------+
                    |                                    |
          +---------v----------+               +---------v----------+
          | 03-drift-detector  |               | 02-posture-check   |
          | compares vs baseline|              | score + findings    |
          +---------+----------+               +---------+----------+
                    |                                    |
          +---------v----------+               +---------v----------+
          | reports\*.md/json  |               | reports\*.md/json  |
          +--------------------+               +--------------------+
```

## Prerequisites

| Requirement | Minimum |
| --- | --- |
| OS | Windows 11 (22H2+) |
| PowerShell | 5.1 (recommended for current scripts) |
| Privileges | Local Administrator |
| Policy | Execution policy allowing local scripts (`RemoteSigned` for process/session) |

Optional:
- Pester 5.x for tests
- PSScriptAnalyzer for script linting

## Quick Start

1. Clone the repository and open an elevated PowerShell console.
2. Review and tune `config\baseline.json` and `config\settings.json`.
3. Apply hardening:
   ```powershell
   .\01-hardening.ps1
   ```
4. Detect drift:
   ```powershell
   .\03-drift-detector.ps1
   ```
5. Run posture assessment:
   ```powershell
   .\02-posture-check.ps1
   ```
6. Review reports in the configured output path (default from `settings.json`).

## Module Descriptions

| Module | Script | Security Objective | Typical Output |
| --- | --- | --- | --- |
| Audit Policies | `modules\AuditPolicies\Set-AuditPolicies.ps1` | Ensure actionable security event logging | Audit policy application results |
| Firewall | `modules\Firewall\Set-FirewallBaseline.ps1` | Enforce profile state and inbound/outbound defaults | Firewall profile compliance state |
| User Accounts | `modules\UserAccounts\Set-UserAccounts.ps1` | Reduce local account abuse and weak password policy risk | Account and policy hardening results |
| Windows Defender | `modules\WindowsDefender\Set-DefenderBaseline.ps1` | Strengthen endpoint prevention and anti-malware controls | Defender preference and tamper status |
| Network Hardening | `modules\NetworkHardening\Set-NetworkHardening.ps1` | Disable legacy protocols and weak network surfaces | Protocol/service hardening results |

## Example Output Screenshots

> Placeholder: Add screenshots for:
> - Hardening console run (`01-hardening.ps1`)
> - Drift report markdown (`drift-report-YYYY-MM-DD.md`)
> - Posture score report (`posture-report-YYYY-MM-DD-HH-mm-ss.md`)

## MITRE ATT&CK Coverage (Defensive Focus)

This project is defensive and control-oriented; mappings below are representative mitigations and detections the baseline supports.

| ATT&CK Technique | Name | Defensive Relevance |
| --- | --- | --- |
| T1021.002 | SMB/Windows Admin Shares | SMBv1 disable + SMB signing reduce lateral movement abuse |
| T1557.001 | LLMNR/NBT-NS Poisoning | LLMNR/NetBIOS hardening lowers spoofing opportunities |
| T1112 | Modify Registry | Drift detection highlights unauthorized security-setting changes |
| T1562.001 | Impair Defenses | Defender and tamper-protection baselines resist defense evasion |
| T1059.001 | PowerShell | PowerShell 2.0 removal limits legacy downgrade abuse |
| T1078 | Valid Accounts | User account hardening and lockout policy reduce account misuse risk |
| T1046 | Network Service Discovery | Firewall baseline reduces exposed service surface |

## Contributing

1. Fork the repository and create a focused branch.
2. Keep changes scoped (hardening logic, drift detection, or reporting).
3. Add or update tests when behavior changes.
4. Run local checks before opening a PR.
5. Open a pull request with:
   - Problem being solved
   - Security impact
   - Validation evidence (logs/reports/screenshots as applicable)

For major changes, open an issue first to align on scope and control intent.

## Development Gates

Use the developer gate script before and after changes:

```powershell
.\scripts\Invoke-DevGate.ps1
```

Optional flags:

```powershell
.\scripts\Invoke-DevGate.ps1 -SkipTests
.\scripts\Invoke-DevGate.ps1 -SkipIntegrity
.\scripts\Invoke-DevGate.ps1 -TestPath tests\smoke
```

Checkpoint workflow:

```powershell
.\scripts\New-RefactorCheckpoint.ps1 -PhaseName Phase1
.\scripts\New-RefactorCheckpoint.ps1 -Rollback -TagName refactor/Phase1-pre-20260428 -Confirmation CONFIRM-ROLLBACK
```

### Release Checklist

1. Run `./scripts/Invoke-DevGate.ps1` and confirm all gates pass.
2. Regenerate integrity manifest: dot-source `src/core/IntegrityVerification.ps1` then run `New-ModuleHashManifest -ProjectRoot $PWD -OutputPath .\config\module-hashes.json`.
3. Re-run `./scripts/Invoke-DevGate.ps1` to validate the refreshed manifest.
4. Update [docs/CHANGELOG.md](docs/CHANGELOG.md) with gate evidence and release notes.
5. Create release tag and push (`git tag <version-tag>`; `git push origin main --tags`).
6. Verify CI artifacts are retained for audit evidence.

### Before You Refactor

1. Run Invoke-DevGate.ps1 - all gates green.
2. Run New-RefactorCheckpoint.ps1 -PhaseName Phase1.
3. Make changes.
4. Run Invoke-DevGate.ps1 again - all gates still green.
5. If broken: run Invoke-RollbackToCheckpoint.

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE).
