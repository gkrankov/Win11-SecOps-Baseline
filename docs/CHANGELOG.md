# Changelog

All notable changes to Win11-SecOps-Baseline will be documented here.

## [Unreleased]

## [0.2.0] - 2026-04-28

### Added
- src/core/InputSanitization.ps1 - Gap 1: config input sanitization
- src/core/IntegrityVerification.ps1 - Gap 2: module hash verification
- src/core/RunContext.ps1 - Gap 3: run identifier + orchestrator scope
- tests/unit/MitreMapping.Tests.ps1 - Gap 4: MITRE coverage assertions
- scripts/Invoke-DevGate.ps1 - Gap 5: unified developer gate
- scripts/New-RefactorCheckpoint.ps1 - pre-refactor snapshot utility
- Invoke-RollbackToCheckpoint function (in scripts/New-RefactorCheckpoint.ps1) - rollback utility
- config/module-hashes.json - integrity manifest (9 files)

### Gate Run - 2026-04-28 (clean baseline)
- Parse Check    : PASS - 25 files
- Test Suite     : PASS - 49/49
- Integrity Check: PASS - 9/9 files verified
- Exit code      : 0
- Note: Initial integrity violation (exit 3) resolved by regenerating manifest post-Copilot generation. Expected first-run behavior.

## [1.0.0] - Initial release
### Added
- AuditPolicies module — CIS 17.x controls
- Firewall module — CIS 9.x controls
- UserAccounts module — CIS 1.x controls
- WindowsDefender module — CIS 8.x controls
- NetworkHardening module — disables SMBv1, LLMNR, NetBIOS, legacy TLS
- JSON-based baseline.json configuration
- Timestamped JSON report output
- WhatIf / dry-run support across all modules
- Pester test stubs
