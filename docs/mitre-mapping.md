# MITRE ATT&CK Control Mapping

Technique IDs must use format Tdddd or Tdddd.ddd (for example: T1059 or T1059.001).

| Control ID | Control Name | ATT&CK Technique | Tactic | Mitigation Summary |
| --- | --- | --- | --- | --- |
| CTRL-001 | FirewallBaseline | T1046 | Discovery | Reduces externally exposed network service footprint using restrictive firewall defaults. |
| CTRL-002 | DefenderBaseline | T1562.001 | Defense Evasion | Strengthens endpoint protections and tamper resistance against defense impairment attempts. |
| CTRL-003 | AuditPolicies | T1112 | Defense Evasion | Improves visibility for policy and configuration manipulation events via audit telemetry. |

## NetworkHardening Controls

| Control ID | Control Name | ATT&CK Technique | Tactic | Mitigation Summary |
| --- | --- | --- | --- | --- |
| CTRL-004 | Disable LLMNR | T1557.001 | Credential Access | Prevents LLMNR-based credential interception by disabling the protocol entirely. |
| CTRL-005 | Disable SMBv1 | T1210 | Lateral Movement | Removes an exploitable legacy protocol that enables remote exploitation of network services. |
| CTRL-006 | Disable NTLMv1 | T1557.001 | Credential Access | Eliminates NTLMv1 relay attack surface by enforcing NTLMv2 or Kerberos only. |
| CTRL-007 | Disable WPAD | T1557 | Credential Access | Blocks adversary-in-the-middle attacks that abuse WPAD auto-proxy discovery. |
| CTRL-008 | Enforce TLS 1.2+ | T1040 | Credential Access | Mitigates network sniffing of credentials by deprecating weak cipher and protocol versions. |

## UserAccounts Controls

| Control ID | Control Name | ATT&CK Technique | Tactic | Mitigation Summary |
| --- | --- | --- | --- | --- |
| CTRL-009 | Account lockout policy | T1110 | Credential Access | Reduces brute-force credential attack effectiveness by enforcing lockout thresholds. |
| CTRL-010 | Disable built-in Admin | T1078.001 | Defense Evasion | Removes a commonly targeted local account used to evade detection via well-known credentials. |
| CTRL-011 | Password complexity | T1110.002 | Credential Access | Raises the cost of offline password cracking by enforcing minimum complexity requirements. |
| CTRL-012 | Max password age | T1078 | Persistence | Limits the useful lifetime of stolen credentials by requiring regular password rotation. |
