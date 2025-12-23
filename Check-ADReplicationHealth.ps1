<#
.SYNOPSIS
    Audits AD replication health to prevent Tombstone expiration.
.DESCRIPTION
    1. Retrieves the Forest Tombstone Lifetime (TSL).
    2. Queries every DC for its inbound replication partners.
    3. Calculates "Days Since Last Sync" for every connection.
    4. Flags any connection approaching the TSL.
    5. AUTOMATICALLY attempts 'repadmin /syncall' on failing DCs.
.NOTES
    Requires the Active Directory PowerShell module.
    Run as Domain Admin or Enterprise Admin.
#>

# 1. Get the Forest's Tombstone Lifetime (TSL)
try {
    $ADRoot = Get-ADRootDSE
    $ConfigContext = $ADRoot.ConfigurationNamingContext
    $TSLObject = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$ConfigContext" -Properties tombstoneLifetime
    
    if ($null -ne $TSLObject.tombstoneLifetime) {
        $TSL = $TSLObject.tombstoneLifetime
    } else {
        $TSL = 60 
    }
    Write-Host "Current Forest Tombstone Lifetime is: $TSL days" -ForegroundColor Cyan
} catch {
    Write-Warning "Could not retrieve TSL. Assuming default of 60 days for calculation safety."
    $TSL = 60
}

# 2. Get All Replication Metadata
Write-Host "Querying all Domain Controllers... (This may take a moment)" -ForegroundColor Gray
$ReplicationData = Get-ADReplicationPartnerMetadata -Target * -Scope Server -ErrorAction SilentlyContinue

$Results = @()
$DCsToHeal = @()

foreach ($Link in $ReplicationData) {
    # 3. Calculate the "Number" (Days Since Sync)
    $LastSuccess = $Link.LastReplicationSuccess
    
    # --- SAFE CLEANUP FOR DISPLAY ---
    # 1. Clean Source Name
    if ($Link.Partner) {
        try {
            $SourceClean = ($Link.Partner -split ",")[1].Replace("CN=","")
        } catch {
            $SourceClean = $Link.Partner 
        }
    } else {
        $SourceClean = "Unknown/Deleted"
    }
    
    # 2. Clean Partition Name (Handle the "Unknown" issue)
    if ([string]::IsNullOrWhiteSpace($Link.NamingContext)) {
        # If NamingContext is empty but we have data, it's the Connection Object (All Partitions)
        $PartitionClean = "Connection/All"
    } else {
        try {
            $PartitionClean = ($Link.NamingContext -split ",")[0].Replace("DC=","").Replace("CN=","")
        } catch {
            $PartitionClean = $Link.NamingContext
        }
    }

    if ($LastSuccess -eq $null -or $LastSuccess.Year -eq 1601) {
        $DaysSinceSync = 9999
        $Status = "CRITICAL - NEVER SYNCED"
        if ($Link.Server -notin $DCsToHeal) { $DCsToHeal += $Link.Server }
    } else {
        $TimeSpan = New-TimeSpan -Start $LastSuccess -End (Get-Date)
        $DaysSinceSync = [math]::Round($TimeSpan.TotalDays, 2)
        
        # Determine Health Status
        if ($DaysSinceSync -gt ($TSL - 5)) {
            $Status = "CRITICAL - TOMBSTONE IMMINENT"
            if ($Link.Server -notin $DCsToHeal) { $DCsToHeal += $Link.Server }
        } elseif ($DaysSinceSync -gt 1) {
            $Status = "WARNING - Lagging"
            if ($Link.Server -notin $DCsToHeal) { $DCsToHeal += $Link.Server }
        } else {
            $Status = "Healthy"
        }
    }

    # 4. Create the Custom Object
    $Results += [PSCustomObject]@{
        'Dest'               = $Link.Server
        'Source'             = $SourceClean
        'Type'               = $PartitionClean
        'DaysSince'          = $DaysSinceSync
        'Status'             = $Status
        'TombstoneDaysLeft'  = if ($DaysSinceSync -lt 9999) { [math]::Round($TSL - $DaysSinceSync, 1) } else { 0 }
    }
}

# 5. Output Results
$Results | Sort-Object DaysSince -Descending | Format-Table -AutoSize

# 6. Self-Healing Execution
if ($DCsToHeal.Count -gt 0) {
    Write-Host "`nWARNING: Unhealthy DCs detected. Attempting Self-Healing..." -ForegroundColor Yellow
    foreach ($DC in $DCsToHeal) {
        if ($DC) {
            Write-Host "Running 'repadmin /syncall' on $DC..." -ForegroundColor Cyan
            # /A (All Partitions) /E (Enterprise)
            repadmin /syncall $DC /A /E 
            Write-Host "Sync command issued for $DC." -ForegroundColor Green
        }
    }
    Write-Host "`nPlease wait 15 minutes and run this script again to verify resolution." -ForegroundColor Gray
} else {
    Write-Host "All DCs are healthy. No repairs needed." -ForegroundColor Green
}