param(
    [string]$Server,
    [string]$SiteCode,
    [string]$DBServer,
    [string]$DB
)

Function Write-Log {
    ##########################################################################################################
    <#
    .SYNOPSIS
       Log to a file in a format that can be read by Trace32.exe / CMTrace.exe 
    
    .DESCRIPTION
       Write a line of data to a script log file in a format that can be parsed by Trace32.exe / CMTrace.exe
    
       The severity of the logged line can be set as:
    
            1 - Information
            2 - Warning
            3 - Error
    
       Warnings will be highlighted in yellow. Errors are highlighted in red.
    
       The tools to view the log:
    
       CM Trace - Installation directory on Configuration Manager 2012 Site Server - <Install Directory>\tools\
    
    .EXAMPLE
       Write-Log c:\output\update.log "Application of MS15-031 failed" Apply_Patch 3
    
       This will write a line to the update.log file in c:\output stating that "Application of MS15-031 failed".
       The source component will be Apply_Patch and the line will be highlighted in red as it is an error 
       (severity - 3).
    
    #>
    ##########################################################################################################
    
    #Define and validate parameters
    [CmdletBinding()]
    Param(
          #Path to the log file
          [parameter(Mandatory=$True)]
          [String]$LogFile,
    
          #The information to log
          [parameter(Mandatory=$True)]
          [String]$Value,
    
          #The source of the error
          [parameter(Mandatory=$True)]
          [String]$Component,
    
          #The severity (1 - Information, 2- Warning, 3 - Error)
          [parameter(Mandatory=$True)]
          [ValidateRange(1,3)]
          [Single]$Severity
          )
    
    #Obtain UTC offset
    $DateTime = New-Object -ComObject WbemScripting.SWbemDateTime 
    $DateTime.SetVarDate($(Get-Date))
    $UtcValue = $DateTime.Value
    $UtcOffset = $UtcValue.Substring(21, $UtcValue.Length - 21)
    
    #Create the line to be logged
    $LogLine =  "<![LOG[$Value]LOG]!>" +`
                "<time=`"$(Get-Date -Format HH:mm:ss.fff)$($UtcOffset)`" " +`
                "date=`"$(Get-Date -Format M-d-yyyy)`" " +`
                "component=`"$Component`" " +`
                "context=`"$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " +`
                "type=`"$Severity`" " +`
                "thread=`"$($pid)`" " +`
                "file=`"`">"
    
    #Write the line to the passed log file
    Out-File -InputObject $LogLine -Append -NoClobber -Encoding Default -FilePath $LogFile -WhatIf:$False
    
}

$logfile = "$PSSCriptRoot\Logs\PR_$Server.log"
$MaxLogSize = 2621440
If(!(Test-Path $logfile)){
    New-Item -Path $logfile -ItemType File -Force | Out-Null
} else {
    if((Get-Item $logfile).length -gt $MaxLogSize){
        if(Test-Path ($logfile -replace ".log",".lo_")){
            Remove-Item ($logfile -replace ".log",".lo_") -force | out-null
        }
        Move-Item -Force $logfile ($logfile -replace ".log",".lo_")
    }
}

$MissingPkgQuery = @"
select PkgID
from	v_ContentDistribution content JOIN
		vDistributionPoints dp ON content.DPID=dp.DPID
where dp.ServerName = '$Server' AND PkgId NOT IN (
	select InsString1
	from v_StatMsgWithInsStrings
	where MachineName = '$Server' and 
			MessageID = '2384' and
			Time > DATEADD(day,-1,(
				SELECT TOP 1 Time 
				FROM v_StatMsgWithInsStrings 
				WHERE MessageID='2386' 
				AND MachineName='$Server' ORDER BY Time DESC
			)
		)
) AND PkgID IN (
	select distinct PkgId
	from vSMS_Content
)
order by PkgID
"@

Write-Log $logfile "Gathering missing content packages from [$DB]" "ContentReconciliation" 1
[System.Collections.ArrayList]$MissingPkgs = @()
$MissingPkgs += Invoke-SqlCmd -Database $DB -ServerInstance $DBServer -Query $MissingPkgQuery

if($MissingPkgs){
    $total = $MissingPkgs.count
    $failed = @()
    Write-Log $logfile "[$total] Missing packages were found. Triggering redistribution for missing packages" "ContentReconciliation" 1

    # Found missing packages. Redistribute them
    foreach ($pkg in $MissingPkgs) { 
        $PackageID = $pkg.PkgID 
        Write-Log $logfile "Processing: $PackageID" "ContentReconciliation" 1
        
        try{
            $pkgquery = "SELECT * FROM SMS_DistributionPoint WHERE ServerNalPath LIKE '%$Server%' AND PackageID = '$PackageID'"
            $DP = Get-WMIObject -Namespace root\sms\site_$SiteCode -Query $pkgquery
            $DP.RefreshNow = $true 
            $DP.put() | out-null
            write-Log $logfile "Successfully triggered refresh of PackageID: $PackageID" "ContentReconciliation" 1
        } catch {
            write-Log $logfile "Unable to refresh PackageID: $PackageID" "ContentReconciliation" 3
            $failed += $PackageID
        }
    }

    if($failed){
        Write-Log $logfile "Some packages failed to refresh. Recommend to investigate" "ContentReconciliation" 2
        ForEach($f in $failed){
            Write-Log $logfile "Failed Package: $f" "ContentReconciliation" 2
        }
    } else {
        Write-Log $logfile "All packages successfully refreshed. Ending script execution" "ContentReconciliation" 1
    }
}
