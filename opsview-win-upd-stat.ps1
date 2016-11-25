#################################################################################
#
# NAME: 	opsview-win-upd-stat.ps1
#
# COMMENT:  Script to check for windows updates and send results to Opsview via REST-API
#           (Based on: https://exchange.nagios.org/directory/Plugins/Operating-Systems/Windows-NRPE/Check-Windows-Updates-using-Powershell/details)
#
#           Checks:
#           - how many critical and optional updates are available 
#           - whether the system is waiting for reboot after installed updates 
#
#           Features:
#           - properly handles NRPE's 1024b limitation in return packet
#           - configurable return states for pending reboot and optional updates
#           - performance data in return packet shows titles of available critical updates
#           - caches updates in file to reduce network traffic, also dramatically increases script execution speed
#
#			Return Values:
#			No updates available - OK (0)
#			Only Hidden Updates - OK (0)
#			Updates already installed, reboot required - WARNING (1)
#			Optional updates available - WARNING (1)
#			Critical updates available - CRITICAL (2)
#			Script errors - UNKNOWN (3)
#
#           Parameters:
#           -server (IP or hostname of Opsview master server)
#           -user (Opsview username)
#           -pass (Opsview password)
#           -hostname (name of host object in Opsview)
#           -service (name of service check for host object)
#
#           Example/Syntax:
#           .\opsview-win-upd-stat.ps1 -server opsview.domain.de -user winupdateuser -pass password -hostname myhost.domain.de -service WinUpdatePassive 
#			
#
# IMPORTANT: 	Please make absolutely sure that your Powershell ExecutionPolicy is set to Remotesigned.
#				Also note that there are two versions of powershell on a 64bit OS!
#
#
# CHANGELOG:
# 1.0  2016-11-25 - initial version
# Based on check_windows_updates.ps1 vers. 1.45 by Christian Kaufmann, ck@tupel7.de
#
#################################################################################
# Copyright (C) 2016 Daniel Schindler
# Copyright (C) 2011-2015 Christian Kaufmann, ck@tupel7.de
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

param (
    [string]$server = $args[0],
    [string]$user = $args[1],
    [string]$pass = $args[2],
    [string]$hostname = $args[3],
    [string]$service = $args[4]
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

### Functions
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

$updateCacheFile = "check_windows_updates-cache.xml"
$updateCacheExpireHours = "24"

$logFile = "check_windows_update.log"

function LogLine(	[String]$logFile = $(Throw 'LogLine:$logFile unspecified'), 
					[String]$row = $(Throw 'LogLine:$row unspecified')) {
	$logDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
	Add-Content -Encoding UTF8 $logFile ($logDateTime + " - " + $row) 
}

if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"){ 
	Write-Host "updates installed, reboot required"
    $pluginOutput = "updates installed, reboot required"
	if (Test-Path $logFile) {
		Remove-Item $logFile | Out-Null
	}
	if (Test-Path $updateCacheFile) {
		Remove-Item $updateCacheFile | Out-Null
	}
	$returnState = $returnStatePendingReboot
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '"}}'
    setservicestate ($servicestatus)
    exit $returnStatePendingReboot
}

if (-not (Test-Path $updateCacheFile)) {
	LogLine -logFile $logFile -row ("$updateCacheFile not found, creating....")
	$updateSession = new-object -com "Microsoft.Update.Session"
	$updates=$updateSession.CreateupdateSearcher().Search(("IsInstalled=0 and Type='Software'")).Updates
	Export-Clixml -InputObject $updates -Encoding UTF8 -Path $updateCacheFile
}

if ((Get-Date) -gt ((Get-Item $updateCacheFile).LastWriteTime.AddHours($updateCacheExpireHours))) {
	LogLine -logFile $logFile -row ("update cache expired, updating....")
	$updateSession = new-object -com "Microsoft.Update.Session"
	$updates=$updateSession.CreateupdateSearcher().Search(("IsInstalled=0 and Type='Software'")).Updates
	Export-Clixml -InputObject $updates -Encoding UTF8 -Path $updateCacheFile
} else {
	LogLine -logFile $logFile -row ("using valid cache file....")
	$updates = Import-Clixml $updateCacheFile
}

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

#if ($countCritical -gt 0 -or $countOptional -gt 0) {
#	Start-Process "wuauclt.exe" -ArgumentList "/detectnow" -WindowStyle Hidden
#}

if ($countCritical -gt 0) {
    $returnState = $returnStateCritical
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
	exit $returnStateCritical
}

if ($countOptional -gt 0) {
    $returnState = $returnStateOptionalUpdates
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
	exit $returnStateOptionalUpdates
}

if ($countHidden -gt 0) {
	Write-Host "OK - $countHidden hidden updates.|critical=$countCritical;optional=$countOptional;hidden=$countHidden"
    $pluginOutput = "OK - $countHidden hidden updates."
    $returnState = $returnStateOK
    $servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '","perfdata":"critical=' + $countCritical + ';optional=' + $countOptional + ';hidden=' + $countHidden + '"}}'
    setservicestate ($servicestatus)
    exit $returnStateOK
}

Write-Host "UNKNOWN script state"
$pluginOutput = "UNKNOWN script state"
$returnState = $returnStateUnknown
$servicestatus = '{"set_state":{"result":"' + $returnState + '","output":"' + $pluginOutput + '"}}'
setservicestate ($servicestatus)
exit $returnStateUnknown
