<# 
    .SYNOPSIS 
        A script to check for windows updates and send results to Opsview via REST-API. 
    .DESCRIPTION 
        This script should be run via Windows Task Scheduler every X hours.
        
        Checks:
        - how many critical and optional updates are available 
        - whether the system is waiting for reboot after installed updates 

        Features:
        - properly handles NRPE's 1024b limitation in return packet
        - configurable return states for pending reboot and optional updates
        - performance data in return packet shows titles of available critical updates
        - sends results via HTTPS to Opsview REST-API (hostname of Opsview host object is auto-determined via DNS resolution)
        - logfile is located under C:\Windows\System32\check_windows_update.log
    .PARAMETER server 
        Set Opsview hostname to register at. 
         
        The default value is "opsview.domain.de". 
    .PARAMETER user
        Set Opsview username to use for registration.
        
        The default value is "winupdateuser".
    .PARAMETER pass 
        Set Opsview username's password to use for registration. 
         
        The default value is "password".
    .PARAMETER hostname 
        Set name of host object in Opsview. 
         
        The default value is the auto-detected FQDN from DNS resolution via a .Net class in the format HOSTNAME.DOMAIN.TLD.
     .PARAMETER service 
        Set name of passive service check where results should be inserted. 
         
        The default value is "WinUpdatePassive".
    .EXAMPLE 
        .\opsview-win-upd-stat.ps1 -server opsview.domain.de -user winupdateuser -pass password -hostname winserver.domain.de -service WinUpdatePassive 
         
        Description 
        ----------- 
        This example shows how to run the script with all parameters set.
    .EXAMPLE 
        powershell.exe -noprofile -executionpolicy bypass -file C:\Temp\opsview-win-upd-stat.ps1 
         
        Description 
        ----------- 
        This example shows how to bypass PowerShell execution policy and run script with default parameters. 
    .NOTES 
        ScriptName : opsview-win-upd-stat.ps1 
        Created By : Daniel Schindler 
        Date Coded : 2016-11-25
        
        Return Values:
	No updates available - OK (0)
	Only Hidden Updates - OK (0)
	Updates already installed, reboot required - WARNING (1)
	Optional updates available - WARNING (1)
	Critical updates available - CRITICAL (2)
	Script errors - UNKNOWN (3)
    .LINK 
        https://exchange.nagios.org/directory/Plugins/Operating-Systems/Windows-NRPE/Check-Windows-Updates-using-Powershell/details 
    .LINK 
        https://github.com/schindlerd/opsview-win-upd-stat 
#> 
#requires -version 2.0
	
# CHANGELOG:
# 1.4  2016-12-06 - added Get-Help header information
# 1.3  2016-11-29 - remove logfile if size threshold reached (500kb)
# 1.2  2016-11-28 - remove caching feature of updates in XML file and always perform a fresh search for updates
#                 - add plugin output to logging
# 1.1  2016-11-27 - set default params
#                 - determine Opsview-Object-Hostname (FQDN via .Net class)
# 1.0  2016-11-25 - initial version
#
#################################################################################
# Copyright (C) 2016 Daniel Schindler, daniel.schindler@steag.com
#
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation; either version 3 of the License, or (at your option) any later 
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT 
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS 
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
#################################################################################

### Set param default values to your environment if not set via arguments.
### Hostname e.g. is set to FQDN from DNS if not set because our Opsview hosts are named like their FQDN names.
param (
    [string]$server = "opsview.domain.de",
    [string]$user = "winupdateuser",
    [string]$pass = "password",
    [string]$hostname = [System.Net.Dns]::GetHostEntry([string]$env:computername).HostName,
    [string]$service = "WinUpdatePassive"
)

### URLs for authentication and config
$urlauth = "https://$server/rest/login"
$urlservice = "https://$server/rest/detail?hostname=$hostname&servicename=$service"

### JSON formated body string with credentials
$creds = '{"username":"' + $user + '","password":"' + $pass + '"}'

### Get auth token
$bytes1 = [System.Text.Encoding]::ASCII.GetBytes($creds)
$web1 = [System.Net.WebRequest]::Create($urlauth)
$web1.Method = "POST"
$web1.ContentLength = $bytes1.Length
$web1.ContentType = "application/json"
$web1.ServicePoint.Expect100Continue = $false
$stream1 = $web1.GetRequestStream()
$stream1.Write($bytes1,0,$bytes1.Length)
$stream1.Close()

$reader1 = New-Object System.IO.Streamreader -ArgumentList $web1.GetResponse().GetResponseStream()
$token1 = $reader1.ReadToEnd()
$reader1.Close()

### Parse Token for follwoing sessions
$token1=$token1.Replace("{`"token`":`"", "")
$token1=$token1.Replace("`"}", "")

### Function to set state of service check
function setservicestate ($jsonstring) {
    $bytes2 = [System.Text.Encoding]::ASCII.GetBytes($jsonstring)
    $web2 = [System.Net.WebRequest]::Create($urlservice)
    $web2.Method = "POST"
    $web2.ContentLength = $bytes2.Length
    $web2.ContentType = "application/json"
    $web2.ServicePoint.Expect100Continue = $false
    $web2.Headers.Add("X-Opsview-Username","$user")
    $web2.Headers.Add("X-Opsview-Token",$token1);
    $stream2 = $web2.GetRequestStream()
    $stream2.Write($bytes2,0,$bytes2.Length)
    $stream2.Close()

    $reader2 = New-Object System.IO.Streamreader -ArgumentList $web2.GetResponse().GetResponseStream()
    $output2 = $reader2.ReadToEnd()
    $reader2.Close()
    
    Write-Host $output2
}

### Replace german vowel mutation
$htReplace = New-Object hashtable
foreach ($letter in (Write-Output ä ae ö oe ü ue Ä Ae Ö Oe Ü Ue ß ss)) {
    $foreach.MoveNext() | Out-Null
    $htReplace.$letter = $foreach.Current
}
$pattern = "[$(-join $htReplace.Keys)]"

$returnStateOK = 0
$returnStateWarning = 1
$returnStateCritical = 2
$returnStateUnknown = 3
$returnStatePendingReboot = $returnStateWarning
$returnStateOptionalUpdates = $returnStateWarning

$logFile = "check_windows_update.log"
$logFileSizeMax = 500kb
if (Test-Path $logFile) {
    if ((Get-Item $logFile).length -gt $logFileSizeMax) {
        Remove-Item $logFile | Out-Null
    }
}

function LogLine(	[String]$logFile = $(Throw 'LogLine:$logFile unspecified'), 
					[String]$row = $(Throw 'LogLine:$row unspecified')) {
	$logDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
	Add-Content -Encoding UTF8 $logFile ($logDateTime + " - " + $row) 
}

if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"){ 
	Write-Host "updates installed, reboot required"
    $pluginOutput = "updates installed, reboot required"
    $returnState = $returnStatePendingReboot
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '"}}'
    setservicestate ($servicestatus)
    LogLine -logFile $logFile -row ($pluginOutput)
	exit $returnStatePendingReboot
}

### Establish WSUS connection and look for updates
LogLine -logFile $logFile -row ("Establishing update session....")
$updateSession = new-object -com "Microsoft.Update.Session"
$updates=$updateSession.CreateupdateSearcher().Search(("IsInstalled=0 and Type='Software'")).Updates
LogLine -logFile $logFile -row ("Search for updates finished....")

$criticalTitles = "";
$countCritical = 0;
$countOptional = 0;
$countHidden = 0;

if ($updates.Count -eq 0) {
	Write-Host "OK - no pending updates.|critical=$countCritical;optional=$countOptional;hidden=$countHidden"
    $pluginOutput = "OK - no pending updates."
    $returnState = $returnStateOK
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
    LogLine -logFile $logFile -row ($pluginOutput)
	exit $returnStateOK
}

foreach ($update in $updates) {
	if ($update.IsHidden) {
		$countHidden++
	}
	elseif ($update.AutoSelectOnWebSites) {
		$criticalTitles += "[" + $update.Title + "] "
		$countCritical++
	} else {
		$countOptional++
	}
}

if (($countCritical + $countOptional) -gt 0) {
	$returnString = "Updates: $countCritical critical, $countOptional optional - $criticalTitles"
	$returnString = [regex]::Replace($returnString, $pattern, { $htReplace[$args[0].value] })
	
	# 1024 chars max, reserving 48 chars for performance data -> 
	if ($returnString.length -gt 976) {
        Write-Host ($returnString.SubString(0,975) + "|critical=$countCritical;optional=$countOptional;hidden=$countHidden")
        $pluginOutput = $returnString.SubString(0,975)        
    } else {
        Write-Host ($returnString + "|critical=$countCritical;optional=$countOptional;hidden=$countHidden")
        $pluginOutput = $returnString
    }   
}

if ($countCritical -gt 0) {
    $returnState = $returnStateCritical
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
    LogLine -logFile $logFile -row ($pluginOutput)
	exit $returnStateCritical
}

if ($countOptional -gt 0) {
    $returnState = $returnStateOptionalUpdates
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
    LogLine -logFile $logFile -row ($pluginOutput)
	exit $returnStateOptionalUpdates
}

if ($countHidden -gt 0) {
	Write-Host "OK - $countHidden hidden updates.|critical=$countCritical;optional=$countOptional;hidden=$countHidden"
    $pluginOutput = "OK - $countHidden hidden updates."
    $returnState = $returnStateOK
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
    LogLine -logFile $logFile -row ($pluginOutput)
    exit $returnStateOK
}

Write-Host "UNKNOWN script state"
$pluginOutput = "UNKNOWN script state"
$returnState = $returnStateUnknown
$servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '"}}'
setservicestate ($servicestatus)
LogLine -logFile $logFile -row ($pluginOutput)
exit $returnStateUnknown
