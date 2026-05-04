# Hardening Evidence

This directory contains before/after posture evidence
from validated VM hardening runs.

## Required Before Production Claim

- [ ] Run 01-hardening.ps1 as admin in isolated VM
- [ ] Capture before score from 02-posture-check.ps1
- [ ] Run hardening
- [ ] Capture after score from 02-posture-check.ps1
- [ ] Save HTML report from 05-dashboard-export.ps1
- [ ] Commit all three artifacts here

## Naming Convention

  YYYY-MM-DD_before-score.txt
  YYYY-MM-DD_after-score.txt
  YYYY-MM-DD_evidence-report.html
