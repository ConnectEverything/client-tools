# Copyright 2022 The NATS Authors
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ConfFile = "synadia-nats-channels.conf"
$ConfFileUrl = "https://get-nats.io/$ConfFile"
$CurrentNightlyUrl = "https://get-nats.io/current-nightly"
$OSInfo = "windows-amd64"
$Stable = "stable"
$StableLtr = "s"
$Nightly = "nightly"
$NightlyLtr = "n"
$NscApp = "nsc"
$CliApp = "nats"
$NscExe = "nsc.exe"
$CliExe = "nats.exe"
$NscZip = "nsc.zip"
$CliZip = "nats.zip"
$NatsDir = "NATS"
$CliZipFolder = "nats-%VERSIONNOV%-$OSInfo"

# ----------------------------------------------------------------------------------------------------
# Functions
# ----------------------------------------------------------------------------------------------------
Function Get-Property($RawConf, $Pattern) {
	$p = [string]($RawConf -split "`r?`n" | Select-String -Pattern $Pattern -CaseSensitive -SimpleMatch)
	$i = $p.IndexOf("=")
	return $p.Substring($i + 1)
}

$_currentNightly = "" # lazy loaded
Function Get-Version($RawConf, $Kind, $App) {
	if ($kind -eq $Nightly) {
		$temp = [string](Invoke-WebRequest -Uri $CurrentNightlyUrl)
		$_currentNightly = $temp.Substring(0, 8)
		return $_currentNightly
	}
	else
	{
		return Get-Property $RawConf "VERSION_${Kind}_${App}"
	}
}

Function Get-NoVVersion($Ver) {
	if ( $Ver.StartsWith("v") ) {
		return $ver.Substring(1)
	}
	return $Ver
}

Function Get-ZipUrl($RawConf, $Kind, $App, $Ver, $VerNoV) {
	$UrlDir = Get-Property $RawConf "URLDIR_${Kind}_${App}"
	$Zip = Get-Property $RawConf "ZIPFILE_${Kind}_${App}"
	$Zip = $Zip.Replace("%OSNAME%-%GOARCH%", $OSInfo).Replace("%VERSIONNOV%", $VerNoV)
	return $UrlDir.Replace("%VERSIONTAG%", $Ver) + $Zip
}

Function Get-EnsureEndsWithBackslash($s) {
	if ($s.EndsWith("\")){
		return $s
	}
	return $s + "\"
}

Function Get-EnsureDoesntEndWithBackslash($s) {
	if ($s.EndsWith("\")){
		return $s.Substring(0, $s.Length - 1)
	}
	return $s
}

Function Get-Folder() {
	[void] [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
	$FolderBrowserDialog = New-Object System.Windows.Forms.FolderBrowserDialog
	$FolderBrowserDialog.RootFolder = 'MyComputer'
	[void] $FolderBrowserDialog.ShowDialog()
	return $FolderBrowserDialog.SelectedPath
}

Function Invoke-Backup($BinDir, $App, $ExePath) {
	if ( Test-Path $ExePath )
	{
		Write-Host "Backing up existing $App executable..."
		for($i = 1; $i -lt 100; $i++) # I give up after 99 tries
		{
			$nn = "$BinDir$App-" + (Get-Date -Format "yyyyMMdd") + "-backup$i.exe"
			if (!(Test-Path $nn))
			{
				Rename-Item -Path $ExePath -NewName $nn
				return
			}
		}
		Write-Host "Cannot backup $ExePath, all backups exist."
		Exit -2
	}
}

# ----------------------------------------------------------------------------------------------------
# Execution
# ----------------------------------------------------------------------------------------------------
# They get to pick the folder given a default
$tempDir = (Get-EnsureEndsWithBackslash $Env:ProgramFiles) + $NatsDir
$opt0 = New-Object System.Management.Automation.Host.ChoiceDescription "&Default Location","Default Location is $tempDir"
$opt1 = New-Object System.Management.Automation.Host.ChoiceDescription "&Choose Location","Choose your location."
$options = [System.Management.Automation.Host.ChoiceDescription[]]($opt0, $opt1)
$result = $host.ui.PromptForChoice("Installation Location", "Where will the programs be installed? Default Location is $tempDir", $options, 0)
if ($result -eq 1) {
	$tempDir = Get-Folder
	if (!$tempDir) {
		Write-Host "You must pick a directory. Exiting"
		Exit -1
	}
}
$binDir = Get-EnsureEndsWithBackslash $tempDir
$binDirNoSlash = Get-EnsureDoesntEndWithBackslash $binDir
if ( !(Test-Path $binDirNoSlash) ) {
	New-Item $binDirNoSlash -ItemType Directory | Out-Null
}

# Add bin dir to path if not already in path
Write-Host "Ensuring $binDirNoSlash is in the path..."
$Machine = [EnvironmentVariableTarget]::Machine
$Path = [Environment]::GetEnvironmentVariable('Path', $Machine)
if (!(";$Path;".ToLower() -like "*;$binDirNoSlash;*".ToLower())) {
	[Environment]::SetEnvironmentVariable('Path', "$Path;$binDirNoSlash", $Machine)
	$Env:Path += ";$binDirNoSlash"
}

# some local variables now that I have $binDir
$nscExePath = $binDir + $NscExe
$cliExePath = $binDir + $CliExe
$confFileLocal = $binDir + $ConfFile
$nscZipLocal =  $binDir + $NscZip
$cliZipLocal =  $binDir + $CliZip

# $kind Have the user pick which type of channel they want, i.e. stable or nightly. Get the channel kinds from the conf
$opt0 = New-Object System.Management.Automation.Host.ChoiceDescription "&$Stable","Latest Stable Build."
$opt1 = New-Object System.Management.Automation.Host.ChoiceDescription "&$Nightly","Current Nightly Build."
$options = [System.Management.Automation.Host.ChoiceDescription[]]($opt0, $opt1)
$result = $host.ui.PromptForChoice("Build Selection", "What kind of build do you want?", $options, 0)
switch ($result) {
	0{$kind = $Stable}
	1{$kind = $Nightly}
}
Write-Host ""

# $rawConf Download and parse channels control file
Write-Host "Downloading configuration info..."
Invoke-WebRequest -Uri $ConfFileUrl -OutFile $confFileLocal -UseBasicParsing
$rawConf = (Get-Content -Path $confFileLocal -Raw) -split "`r?`n"

# $ver / $verNoV Figure out the version number from the conf file
$verNsc = Get-Version $rawConf $kind $NscApp
$verCli = Get-Version $rawConf $kind $CliApp
$verNoVNsc = Get-NoVVersion $verNsc
$verNoVCli = Get-NoVVersion $verCli
if ($kind -eq $Nightly) {
	Write-Host "Nightly version $verNsc"
}
else
{
	Write-Host "$NscApp version $verNsc"
	Write-Host "$CliApp version $verCli"
}

# Download the zip files
$nscZipUrl = Get-ZipUrl $rawConf $kind $NscApp $verNsc $verNoVNsc
$cliZipUrl = Get-ZipUrl $rawConf $kind $CliApp $verCli $verNoVCli

Write-Host "Downloading archive $nscZipUrl..."
Invoke-WebRequest -Uri $nscZipUrl -OutFile $nscZipLocal -UseBasicParsing
Write-Host "Downloading archive $cliZipUrl..."
Invoke-WebRequest -Uri $cliZipUrl -OutFile $cliZipLocal -UseBasicParsing

# Backup existing versions now that the downloads worked
Invoke-Backup $binDir $NscApp $nscExePath
Invoke-Backup $binDir $CliApp $cliExePath

# Nsc: Unzip, Remove Archive
Write-Host "Installing $NscApp..."
Expand-Archive -Path $nscZipLocal -DestinationPath $binDir
Remove-Item $nscZipLocal

# Cli: Unzip, stable:(move exe from folder then remove folder), Remove Archive 
Write-Host "Installing $CliApp..."
Expand-Archive -Path $cliZipLocal -DestinationPath $binDir -Force
if ($kind -eq $Stable) {
	$cliZipFolderLocal = $binDir + $CliZipFolder.Replace("%VERSIONNOV%", $verNoVCli)
	Move-Item -Path "$cliZipFolderLocal\$CliExe" -Destination "$binDir$CliExe"
	Remove-Item "$cliZipFolderLocal\*"
	Remove-Item $cliZipFolderLocal
}
Remove-Item $cliZipLocal

# Cleanup Conf File
Remove-Item $confFileLocal
