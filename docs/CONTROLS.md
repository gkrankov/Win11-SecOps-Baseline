# Control Reference — CIS / STIG Mapping

This document maps each module setting to the corresponding CIS Benchmark for
Windows 11 (v1.0) and/or DISA STIG control.

| Module | Setting | CIS Control | STIG ID | Notes |
|---|---|---|---|---|
| AuditPolicies | AuditLogonEvents | 17.5.1 | WN11-AU-000050 | |
| AuditPolicies | AuditAccountLogon | 17.1.1 | WN11-AU-000010 | |
| AuditPolicies | AuditPrivilegeUse | 17.9.1 | WN11-AU-000090 | |
| AuditPolicies | AuditPolicyChange | 17.7.1 | WN11-AU-000070 | |
| AuditPolicies | AuditAccountManagement | 17.2.1 | WN11-AU-000020 | |
| Firewall | DefaultInboundAction | 9.1.2 | WN11-NF-000010 | All profiles |
| Firewall | LogBlocked | 9.1.6 | WN11-NF-000040 | |
| UserAccounts | MaxPasswordAge | 1.1.2 | WN11-AC-000020 | 60 days max |
| UserAccounts | MinPasswordLength | 1.1.4 | WN11-AC-000040 | 14 chars min |
| UserAccounts | LockoutThreshold | 1.2.2 | WN11-AC-000100 | 5 attempts |
| UserAccounts | DisableBuiltInAdministrator | 2.3.1.2 | WN11-SO-000001 | |
| UserAccounts | DisableBuiltInGuest | 2.3.1.3 | WN11-SO-000002 | |
| WindowsDefender | EnableRealTimeMonitoring | 8.2.1 | WN11-AV-000010 | |
| WindowsDefender | EnableTamperProtection | 8.2.3 | WN11-AV-000030 | |
| WindowsDefender | EnableControlledFolderAccess | 8.3.1 | WN11-AV-000040 | |
| NetworkHardening | DisableSMBv1 | 18.3.3 | WN11-CC-000110 | |
| NetworkHardening | DisableLLMNR | 18.5.4.2 | WN11-CC-000200 | |
| NetworkHardening | MinimumTLSVersion | 18.9.85 | WN11-CC-000390 | TLS 1.2+ |

## Control Inventory

| Control ID | Name | Description | Module | Status |
| --- | --- | --- | --- | --- |
| CTRL-001 | FirewallBaseline | Enforces default inbound/outbound and firewall profile safeguards. | Firewall | Active |
| CTRL-002 | DefenderBaseline | Enforces core Microsoft Defender protective settings. | WindowsDefender | Active |
| CTRL-003 | AuditPolicies | Enforces security event auditing policy requirements. | AuditPolicies | Active |

Each control must have a corresponding entry in mitre-mapping.md
