# MITRE ATT&CK Mapping for Win11-SecOps-Baseline

This document maps key hardening actions in this project to relevant MITRE ATT&CK techniques.

| Hardening Action | ATT&CK Technique ID | Technique Name | Tactic |
| --- | --- | --- | --- |
| Disable SMBv1 protocol (`DisableSMBv1`) | T1021.002 | SMB/Windows Admin Shares | Lateral Movement |
| Enforce SMB signing (client/server) | T1557.001 | LLMNR/NBT-NS Poisoning and SMB relay-related abuse | Credential Access |
| Disable NetBIOS over TCP/IP (`DisableNetBIOS`) | T1557.001 | LLMNR/NBT-NS Poisoning and SMB relay-related abuse | Credential Access |
| Disable LLMNR (`DisableLLMNR`) | T1557.001 | LLMNR/NBT-NS Poisoning and SMB relay-related abuse | Credential Access |
| Enforce NTLMv2 / disable NTLMv1 (`LmCompatibilityLevel`) | T1557.001 | LLMNR/NBT-NS Poisoning and SMB relay-related abuse | Credential Access |
| Disable LM hash storage (`NoLMHash=1`) | T1003.001 | OS Credential Dumping: LSASS Memory | Credential Access |
| Enable ASR rule: Block credential stealing from LSASS | T1003.001 | OS Credential Dumping: LSASS Memory | Credential Access |
| Enable ASR rule: Block process creation from PSExec and WMI | T1569.002 | System Services: Service Execution | Execution |
| Enable ASR rule: Block process creation from PSExec and WMI | T1021.006 | Remote Services: Windows Remote Management | Lateral Movement |
| Disable built-in Administrator account (`DisableBuiltInAdministrator`) | T1078 | Valid Accounts | Defense Evasion |
| Disable built-in Guest account (`DisableBuiltInGuest`) | T1078 | Valid Accounts | Initial Access |
| Enforce account lockout threshold/duration | T1110 | Brute Force | Credential Access |
| Set firewall inbound default action to Block | T1021.001 | Remote Services: Remote Desktop Protocol | Lateral Movement |
| Set firewall inbound default action to Block | T1021.002 | SMB/Windows Admin Shares | Lateral Movement |
| Disable WPAD service (`WinHttpAutoProxySvc`) | T1557 | Adversary-in-the-Middle | Collection |
| Disable legacy TLS/SSL and RC4 | T1557 | Adversary-in-the-Middle | Collection |
| Enable Defender real-time protection | T1562.001 | Impair Defenses: Disable or Modify Security Tools | Defense Evasion |
| Enable Defender tamper protection | T1562.001 | Impair Defenses: Disable or Modify Security Tools | Defense Evasion |
| Remove PowerShell 2.0 feature | T1059.001 | Command and Scripting Interpreter: PowerShell | Execution |
| Enable audit policy categories (logon, account mgmt, process creation, policy change) | T1070 | Indicator Removal on Host | Defense Evasion |
| Enable controlled folder access and Defender ransomware protections | T1486 | Data Encrypted for Impact | Impact |
| Create baseline and drift detection workflow | T1112 | Modify Registry | Defense Evasion |
| Create baseline and drift detection workflow | T1562 | Impair Defenses | Defense Evasion |

> Notes:
> - These mappings are defensive-control oriented, showing where controls reduce likelihood, limit blast radius, or improve detection.
> - ATT&CK technique naming can evolve; review against the current ATT&CK matrix during periodic baseline updates.
