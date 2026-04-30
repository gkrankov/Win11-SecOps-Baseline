# MITRE ATT&CK Control Mapping

Technique IDs must use format Tdddd or Tdddd.ddd (for example: T1059 or T1059.001).

| Control ID | Control Name | ATT&CK Technique | Tactic | Mitigation Summary |
| --- | --- | --- | --- | --- |
| CTRL-001 | FirewallBaseline | T1046 | Discovery | Reduces externally exposed network service footprint using restrictive firewall defaults. |
| CTRL-002 | DefenderBaseline | T1562.001 | Defense Evasion | Strengthens endpoint protections and tamper resistance against defense impairment attempts. |
| CTRL-003 | AuditPolicies | T1112 | Defense Evasion | Improves visibility for policy and configuration manipulation events via audit telemetry. |

## NetworkHardening Controls

| Control ID | Description            | ATT&CK Technique | Tactic          |
|------------|------------------------|------------------|-----------------|
| CTRL-004   | Disable LLMNR          | T1557.001        | Credential Access / LLMNR Poisoning |
| CTRL-005   | Disable SMBv1          | T1210            | Lateral Movement / Exploitation of Remote Services |
| CTRL-006   | Disable NTLMv1         | T1557.001        | Credential Access / NTLM Relay |
| CTRL-007   | Disable WPAD           | T1557            | Credential Access / Adversary-in-the-Middle |
| CTRL-008   | Enforce TLS 1.2+       | T1040            | Credential Access / Network Sniffing |

## UserAccounts Controls

| Control ID | Description              | ATT&CK Technique | Tactic           |
|------------|--------------------------|------------------|------------------|
| CTRL-009   | Account lockout policy   | T1110            | Credential Access / Brute Force |
| CTRL-010   | Disable built-in Admin   | T1078.001        | Defense Evasion / Local Accounts |
| CTRL-011   | Password complexity      | T1110.002        | Credential Access / Password Cracking |
| CTRL-012   | Max password age         | T1078            | Persistence / Valid Accounts |
