param(
[Parameter(Mandatory=$true)]
[string] $server
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

$logfile = "$PSScriptRoot\Logs\PM_$($server).log"
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

$component = 'GatherData'
Write-Log $logfile "Gathering packages in root\SCCMDP:SMS_PackagesInContLib" $component 1
try{
    $WMIPkgList = Get-WMIObject -NameSpace Root\SCCMDP -Computername $server -Class SMS_PackagesInContLib | Select-Object -ExpandProperty PackageID | Sort-Object
} catch {
    write-log $logfile "Failed to gather package data from WMI. Cannot proceed" $component 3
    Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    exit -1
}

write-log $logfile "Searching registry for content library file path(s)" $component 1
try{
    $Reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $server)
    $RegKey= $Reg.OpenSubKey("SOFTWARE\\Microsoft\\SMS\\DP")
    $ContentLib = $RegKey.GetValue("ContentLibraryPath")
    $PkgLibPath = ($ContentLib) + "\PkgLib"
    $drive = $PkgLibPath.SubString(0,1)
    $PkgLibPath = $PkgLibPath.Replace(($drive+":\"),("\\"+$server+"\"+$drive+"$\"))
} catch {
    write-log $logfile "Failed to find a content library path in the registry. Cannot proceed" $component 3
    Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    exit -1
}

write-log $logfile "Gathering all package INI files in the local content library" $component 1
try{
    $PkgLibList = (Get-ChildItem $PkgLibPath | Select-Object -ExpandProperty Name | Sort-Object)
    $PkgLibList = ($PKgLibList | ForEach-Object {$_.replace(".INI","")})
} catch {
    write-log $logfile "Failed to recurse through the content library to locate package INI files. Cannot proceed" $component 3
    Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    exit -1
}

$component = "Compare"
write-log $logfile "Comparing data in WMI to data in the filesystem" $component 1
try{
    $PksinWMIButNotContentLib = Compare-Object -ReferenceObject $WMIPkgList -DifferenceObject $PKgLibList -PassThru | Where-Object { $_.SideIndicator -eq "<=" }
    $PksinContentLibButNotWMI = Compare-Object -ReferenceObject $WMIPkgList -DifferenceObject $PKgLibList -PassThru | Where-Object { $_.SideIndicator -eq "=>" }
} catch {
    write-log $logfile "Failed to run a compare of data in WMI and data in the filesystem. Cannot proceed" $component 3
    Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    exit -1
}

write-log $logfile "Total items in WMI: [$($WMIPkgList.count)]" $component 1
write-log $logfile "Total items in the filesystem: [$($PkgLibList.count)]" $component 1
write-log $logfile "Total items in WMI but not in the filesystem: [$($PksInWMIButNotContentLib.count)]" $component 1
write-log $logfile "Total items in the filesystem but not in WMI: [$($PksinContentLibButNotWMI.count)]" $component 1

If($PksinWMIButNotContentLib.count -gt 0){
    write-log $logfile "The following items were found in WMI but not in the filesystem. These will be deleted from WMI:" $component 1
    ForEach($Pkg in $PksInWMIButNotContentLib){
        write-log $logfile "$Pkg" $component 1
    }
}
If($PksinContentLibButNotWMI.count -gt 0){
    write-log $logfile "The following items were found in the filesystem but not in WMI. These will be deleted from the filesystem:" $component 1
    ForEach($Pkg in $PksinContentLibButNotWMI){
        write-log $logfile "$PkgLibPath\$Pkg.INI" $component 1
    }
}

$component = "Cleanup"
Foreach ($Pkg in $PksinWMIButNotContentLib){
    try{
        Get-WmiObject -Namespace Root\SCCMDP -computername $server -Class SMS_PackagesInContLib -Filter "PackageID = '$Pkg'" | Remove-WmiObject
    } catch {
        write-log $logfile "Failed to delete package from WMI: [$Pkg]" $component 3
        Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        write-log $logfile "Will continue trying to process other items queued for deletion" $component 2
        continue
    }
}

Foreach ($Pkg in $PksinContentLibButNotWMI){
    try{
        Remove-Item -Path "$PkgLibPath\$Pkg.INI"
    } catch {
        write-log $logfile "Failed to delete INI from filesystem: [$PkgLibPath\$Pkg.INI]" $component 3
        Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        write-log $logfile "Will continue trying to process other items queued for deletion" $component 2
        continue
    }
}

write-log $logfile "All items have been processed. Triggering content validation" $component 1

$component = "Validation"

Write-Log $logfile "Searching for smsdpmon.exe on the distribution point" $component 1
$found = $false
# Trying the content library drive first
$SMSDPMON_Path = $drive+":\SMS_DP$\sms\bin\smsdpmon.exe"
if(invoke-command -ComputerName $server -ScriptBlock {param($filepath) get-item $filepath -ea 0} -ArgumentList "$SMSDPMON_PATH"){
    $found = $true
} else {
    $OtherDrives = (Get-CimInstance win32_logicaldisk -computername $server | Where-Object{$_.DeviceID -ne $drive.Trim('\')}).DeviceID
    ForEach($d in $OtherDrives){
        $SMSDPMON_Path = $d+"\SMS_DP$\sms\bin\smsdpmon.exe"
        if(invoke-command -ComputerName $server -ScriptBlock {param($filepath) get-item $filepath -ea 0} -ArgumentList "$SMSDPMON_PATH"){
            $found = $true
            break
        }
    }
}

if($found){
    try{
        Invoke-Command -ComputerName $server -ScriptBlock {param($filepath) & $filepath} -ArgumentList $SMSDPMON_Path -AsJob
    } catch {        
        write-log $logfile "Failed to trigger a content validation job using path [$SMSDPMON_PATH]" $component 3
        Write-Log $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    }
} else {
    write-log $logfile "Unable to locate smsdpmon.exe on the distribution point" $component 3
}