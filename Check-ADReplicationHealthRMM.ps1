# RMM AD Sync Monitor
# Threshold: Alert if sync is older than this many days
$ThresholdDays = 1.0 

# Check TSL (Safety check, same as before)
try {
    $ADRoot = Get-ADRootDSE
    $Config = $ADRoot.ConfigurationNamingContext
    $TSLObj = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$Config" -Properties tombstoneLifetime
    $TSL = $TSLObj.tombstoneLifetime
    if (!$TSL) { $TSL = 60 }
} catch {
    $TSL = 60
}

# Get Data
$ReplicationData = Get-ADReplicationPartnerMetadata -Target * -Scope Server -ErrorAction SilentlyContinue
$FailureList = @()
$HealLog = @()

# Track which DCs we have already attempted to heal to avoid duplicate commands
$HealedDCs = @()

foreach ($Link in $ReplicationData) {
    $LastSuccess = $Link.LastReplicationSuccess
    
    # Check for "Never Synced" or Null
    if ($LastSuccess -eq $null -or $LastSuccess.Year -eq 1601) {
        $FailureList += "CRITICAL: $($Link.Server) has NEVER synced with $($Link.Partner)"
        $NeedsHealing = $true
        $TargetDC = $Link.Server
    } else {
        $TimeSpan = New-TimeSpan -Start $LastSuccess -End (Get-Date)
        $DaysSince = $TimeSpan.TotalDays

        # If lag exceeds threshold, add to failure list
        if ($DaysSince -gt $ThresholdDays) {
            # Clean up the name for the ticket
            try {
                $SourceClean = ($Link.Partner -split ",")[1].Replace("CN=","")
            } catch {
                $SourceClean = $Link.Partner
            }
            
            $RoundedDays = [math]::Round($DaysSince, 2)
            
            $FailureList += "LAG WARNING: Destination [$($Link.Server)] -> Source [$SourceClean] is behind by $RoundedDays days."
            $NeedsHealing = $true
            $TargetDC = $Link.Server
        } else {
            $NeedsHealing = $false
        }
    }

    # --- SELF HEALING ---
    if ($NeedsHealing -and ($TargetDC -notin $HealedDCs)) {
        $HealLog += "`n--- Attempting Self-Healing on $TargetDC ---"
        
        # Run Repadmin SyncAll (All partitions, Enterprise, Pull)
        try {
            # Capture both Output and Error streams
            $SyncOutput = repadmin /syncall $TargetDC /A /E 2>&1 | Out-String
            $HealLog += $SyncOutput
        } catch {
            $HealLog += "Error running repadmin: $_"
        }
        
        $HealedDCs += $TargetDC
    }
}

# --- RMM DECISION LOGIC ---

if ($FailureList.Count -gt 0) {
    # 1. Output the errors so they appear in the Ticket Body
    Write-Output "AD Replication Issues Detected:"
    $FailureList | ForEach-Object { Write-Output $_ }
    
    # 2. Output the Healing Log
    if ($HealLog.Count -gt 0) {
        Write-Output "`n================ SELF HEALING LOG ================"
        $HealLog | ForEach-Object { Write-Output $_ }
        Write-Output "=================================================="
    }

    # 3. Exit with Error Code 1 to trigger the RMM Alert
    Write-Error "Replication threshold exceeded. Self-healing attempted (see logs)."
    exit 1
} else {
    # Healthy - Exit cleanly
    Write-Output "Health Check Passed. All DCs syncing within $ThresholdDays days."
    exit 0
}