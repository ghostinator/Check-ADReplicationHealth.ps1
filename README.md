# Active Directory Replication Health Monitoring (Self-Healing)

## Overview

This repository contains two PowerShell scripts designed to audit Active Directory replication health. The primary goal is to track the **Days Since Last Sync** for every replication link to prevent "Tombstone" expiration and lingering objects.

**Key Feature: Self-Healing**
Both scripts include automated repair capabilities. If a Domain Controller (DC) is found to be lagging behind the defined threshold, the script automatically triggers a `repadmin /syncall` command on that specific DC to attempt an immediate force-sync.

## Scripts Included
<img width="894" height="339" alt="CleanShot 2025-12-23 at 10 53 38" src="https://github.com/user-attachments/assets/3f1b80b1-b85d-40b3-8469-de819cb76e8a" />

### 1. `Check-ADReplicationHealth.ps1` (Manual / Interactive)

* **Intended Use:** Manual troubleshooting by an engineer.
* **Output:** Displays a color-coded table sorting DCs by sync health.
* **Note:** If the **Type** column displays `Connection/All`, this indicates the script is verifying the main Connection Object between DCs (which aggregates all partitions).


* **Behavior:**
* Calculates days until Tombstone expiration.
* If critical errors are detected, it immediately runs replication repair commands and logs the attempt to the console.



### 2. `Check-ADReplicationHealthRMM.ps1` (Datto / Automated)

* **Intended Use:** Scheduled daily monitoring via RMM.
* **Behavior:**
* Checks if any link exceeds the `$ThresholdDays` (Default: 1.0).
* **Self-Healing:** If lag is detected, it runs `repadmin /syncall /A /E` on the affected DC.
* **Ticket Generation:** It captures the **full output** of the repair attempt (STDOUT/STDERR) and includes it in the RMM alert/ticket body for rapid triage.


* **Exit Codes:**
* `Exit 0`: Healthy (No alerts).
* `Exit 1`: Issues detected (Trigger RMM Alert).



---

## Datto RMM Configuration

To deploy the automated monitoring and alerting:

1. **Create Component**
* Upload `Check-ADReplicationHealthRMM.ps1` as a new PowerShell component.
* (Optional) Map `$ThresholdDays` to a variable if you wish to adjust sensitivity.


2. **Create Monitor**
* Add a **Component Monitor** to your Domain Controller Policy.
* **Schedule:** Run **Once Daily** (e.g., 6:00 AM).
* **Alert Condition:** Trigger if **Exit Code Not Equal To 0**.


3. **Ticket Configuration**
* Configure the monitor to create a ticket on alert.
* **Subject:** `AD Replication Critical - [DeviceName]`
* **Priority:** High.



### Reviewing Tickets

When a ticket is generated, review the **Command Output** section. You will see a log similar to this:

```text
AD Replication Issues Detected:
LAG WARNING: Destination [DC02] -> Source [DC01] is behind by 2.4 days.

================ SELF HEALING LOG ================
Syncing all NC's held on DC02...
Syncing partition: DC=ForestDnsZones,DC=ad,DC=domain,DC=com
CALLBACK MESSAGE: The following replication is in progress...
Sync was successful.
==================================================

```

* **"Sync was successful"**: The script likely fixed the issue; verify the next day.
* **"RPC Server Unavailable"**: The target DC is likely offline or blocked by a firewall; manual intervention is required.

---

## Troubleshooting & FAQ

### Why does the "Type" column say "Connection/All" or "Unknown"?

If a replication link exists but has never successfully synced specific partition metadata (or if the metadata is aggregated), the script labels this as `Connection/All`.

* **If Status is Healthy:** This is normal behavior for the main Connection Object.
* **If Status is CRITICAL / NEVER SYNCED:** This indicates a "Zombie" link in AD Sites and Services that should be deleted.

### How is Tombstone Lifetime (TSL) calculated?

The script queries the Forest Configuration partition.

* If found, it uses the explicit value (usually 180 days for newer forests).
* If the attribute is null, it defaults to **60 days** (legacy Windows default) to be safe.

### Prerequisite Checklist

* **User Context:** Must run as **Domain Admin** or Enterprise Admin.
* **Module:** The **Active Directory PowerShell module** must be installed on the target machine.
* **Network:** Ports TCP 389, 88, 135, and 445 (for RPC) must be open between DCs.
