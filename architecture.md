# Win11-SecOps-Baseline Architecture

## Purpose
This document explains how the five security control modules work together with the orchestration scripts, configuration files, reporting pipeline, and drift remediation loop.

The five security modules are:
- AuditPolicies
- Firewall
- UserAccounts
- WindowsDefender
- NetworkHardening

## High-Level Component Model
- Orchestrator: Invoke-SecBaseline.ps1
- Control modules: modules/*/Set-*.ps1
- State readers: modules/Common/SecOpsState.ps1
- Posture scoring: 02-posture-check.ps1
- Drift detection and optional remediation: 03-drift-detector.ps1
- Dashboard rendering: 05-dashboard-export.ps1
- Runtime configuration: config/settings.json
- Security baseline contract: config/baseline.json

## Text-Based Flow Diagram
```text
                    +--------------------------------+
                    |      config/baseline.json      |
                    |  (expected control settings)   |
                    +---------------+----------------+
                                    |
                                    v
                    +--------------------------------+
                    |      Invoke-SecBaseline.ps1    |
                    |  runs selected hardening mods  |
                    +---------------+----------------+
                                    |
                                    v
         +-------------------- Five Security Modules --------------------+
         |  AuditPolicies | Firewall | UserAccounts | Defender | Network |
         +--------------------+---------------------+--------------------+
                              |                     |
                              | writes remediation/report outputs
                              v
                    +--------------------------------+
                    |      reports/baseline-*.json   |
                    +--------------------------------+

                                    |
                                    | compare expected vs actual
                                    v
                    +--------------------------------+
                    |      03-drift-detector.ps1     |
                    |  reads live state via common   |
                    +---------------+----------------+
                                    |
                  +-----------------+-----------------+
                  |                                   |
                  v                                   v
      +-------------------------------+    +-------------------------------+
      | Drift report (drift-report.md)|    | Optional auto-remediation     |
      | with category/risk/details    |    | per settings.remediation.*    |
      +---------------+---------------+    +---------------+---------------+
                      |                                    |
                      +----------------+-------------------+
                                       |
                                       v
                    +--------------------------------+
                    |      02-posture-check.ps1      |
                    |   weighted score + findings    |
                    +---------------+----------------+
                                    |
                                    v
                    +--------------------------------+
                    | posture-report-*.md            |
                    | 05-dashboard-export.ps1 -> HTML|
                    +--------------------------------+
```

## Data Flow Between Modules
1. Baseline authoring
- config/baseline.json defines expected values for each of the five modules.
- The same baseline object is passed into module scripts during hardening.

2. Hardening execution path
- Invoke-SecBaseline.ps1 loads baseline.json.
- For each selected category, it resolves and executes modules/<Category>/Set-<Category>.ps1.
- Each module applies settings for its domain and returns execution details.
- The orchestrator emits a baseline run report (JSON).

3. State collection path
- 02-posture-check.ps1 and 03-drift-detector.ps1 dot-source modules/Common/SecOpsState.ps1.
- Shared getters collect actual endpoint state across audit, firewall, account, defender, and network surfaces.

4. Drift analysis path
- 03-drift-detector.ps1 compares current state to baseline.json values property by property.
- Detected differences become drift items with category, setting, expected/current values, timestamp, and risk level.
- Results are exported to markdown.

5. Optional remediation path
- If settings.json enables remediation globally and by module, drift-detector invokes the impacted module(s).
- Remediation outcomes are appended to drift report output.

6. Posture and dashboard path
- 02-posture-check.ps1 calculates weighted checks and produces posture markdown.
- 05-dashboard-export.ps1 reads posture output and renders an HTML dashboard.
- Renderer applies HTML escaping to report-derived content.

## How settings.json and baseline.json Connect Everything

### baseline.json: Security intent
baseline.json is the source of truth for what secure looks like.
- AuditPolicies.* defines expected audit policy states.
- Firewall.* defines expected profile behavior and logging.
- UserAccounts.* defines local account and password policy requirements.
- WindowsDefender.* defines Defender and protection settings.
- NetworkHardening.* defines protocol/service hardening expectations.

Every major execution path references this file:
- Invoke-SecBaseline.ps1 uses it to apply settings.
- 03-drift-detector.ps1 uses it as comparison target.
- 02-posture-check.ps1 uses it to score compliance.

### settings.json: Runtime behavior
settings.json controls how the system runs and reports.
- reporting.outputPath directs where posture/drift/dashboard artifacts are written.
- logging.logPath and verbosity settings control operational logs.
- notifications.* controls desktop/email alert behavior.
- remediation.* determines whether drift can trigger module remediation.
- schedule.* declares automation intent (task name, frequency, runAsSystem).

In short:
- baseline.json defines what to enforce.
- settings.json defines when/how to run and where/how to report.

## Scheduled Automation Flow (Task Scheduler Integration)
Current state in this repository:
- settings.json contains a schedule block with task metadata and cadence settings.
- There is currently no script that registers or updates a Windows Scheduled Task (no Register-ScheduledTask/schtasks integration found in code).

Intended automation flow based on existing configuration:
1. Read settings.schedule.taskName, frequency, runAtTime, and runAsSystem.
2. Trigger a periodic run of drift and/or posture scripts under elevated context.
3. Write reports/logs to settings.reporting.outputPath and settings.logging.logPath.
4. If enabled, run module remediation for drifted categories.
5. Notify via settings.notifications channels.

Recommended implementation hook:
- Add a dedicated script (for example, scripts/Register-SecOpsScheduledTask.ps1) that reads settings.json and creates/updates the task definition.

## Drift Detection Feedback Into Hardening
The feedback loop is implemented as follows:
1. 03-drift-detector.ps1 detects drift against baseline.json.
2. It groups drift by module category.
3. If settings.remediation.autoRemediationEnabled is true and category-level autoRemediate is true, it invokes that module's Set-*.ps1 script.
4. Remediation status (Applied/Skipped/Failed) is written to the drift report.
5. The next posture-check or drift run validates whether remediation returned the endpoint to baseline.

This creates an enforce -> verify -> detect -> remediate -> re-verify cycle.

## Practical Development Guidance
- Keep baseline.json as the contract for module expectations.
- Keep shared state access in modules/Common/SecOpsState.ps1 to avoid duplicate logic.
- Add new control categories only if they are wired through all three paths:
  - hardening (Invoke-SecBaseline + module)
  - drift detection (03-drift-detector)
  - posture scoring/reporting (02-posture-check + dashboard rendering)
- When adding scheduled automation, source settings.schedule from settings.json rather than hardcoding task details.
