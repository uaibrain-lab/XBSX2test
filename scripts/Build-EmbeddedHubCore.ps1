# Windows PowerShell 5.1: build GPL XBSX2 as a native DLL for ONE Hub APPX.
# Does NOT build/install any XBSX2 APPX or register an emulator protocol.
[CmdletBinding()]
param(
 [string]$Root=(Split-Path -Parent $PSScriptRoot),
 [ValidateSet("Release","Debug")][string]$Configuration="Release",
 [string]$OutputDir=""
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$root=[IO.Path]::GetFullPath($Root)
$project=Join-Path $root "pcsx2-uwp\pcsx2-uwp.vcxproj"
if(!(Test-Path -LiteralPath $project)){throw "XBSX2_PROJECT_MISSING"}
if(!(Select-String -LiteralPath $project -Pattern 'UaiBrainHubEmbedded' -Quiet)){
 throw "NOT_AN_EMBEDDED_XBSX2_BRANCH"
}
if(!$OutputDir){$OutputDir=Join-Path $root "build\embedded-ps2"}
$output=[IO.Path]::GetFullPath($OutputDir)
[IO.Directory]::CreateDirectory($output)|Out-Null
$vswhere=Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild=$null
if(Test-Path -LiteralPath $vswhere){
 $installed=@(& $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath)
 foreach($one in $installed){
  $candidate=Join-Path $one "MSBuild\Current\Bin\MSBuild.exe"
  if(Test-Path -LiteralPath $candidate){$msbuild=$candidate;break}
 }
}
if(!$msbuild){
 foreach($candidate in @(
 "E:\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
 "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
 "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
 )){
  if(Test-Path $candidate){$msbuild=$candidate;break}
 }
}
if(!$msbuild){throw "MSBUILD_NOT_FOUND: install VS2026/2022 C++ UWP tools"}
# The PCSX2 repo does not track compiled deps; an empty checkout cannot
# provide FreeType, Zstd, zlib, DirectX-Headers, SDL, etc. /restore alone also
# does not restore old packages.config. Bootstrap once, reuse on later builds.
$ensure=Join-Path $PSScriptRoot "Ensure-EmbeddedHubDependencies.ps1"
if(-not (Test-Path -LiteralPath $ensure -PathType Leaf)){
 throw "HUB_PS2_DEPENDENCY_BOOTSTRAP_MISSING=$ensure"
}
& $ensure -Root $root
if(-not $?){throw "HUB_PS2_DEPENDENCY_BOOTSTRAP_FAILED"}
# Use one compiler version and WindowsStore/UWP SDK for Hub and embedded core.
$props=@(
 "/p:Configuration=$Configuration",
 "/p:Platform=x64",
 "/p:UaiBrainHubEmbedded=true",
 "/p:GenerateAppxPackageOnBuild=false",
 "/p:AppxPackageSigningEnabled=false",
 "/p:SolutionDir=$($root.TrimEnd('\'))\",
 "/p:OutDir=$($output.TrimEnd('\'))\"
)
$log=Join-Path $output "embedded-ps2-msbuild.log"
Write-Host "HUB_PS2_BUILDING_EMBEDDED_DLL_WITH=$msbuild"
Write-Host "HUB_PS2_MSBUILD_LOG=$log"
# The complete compiler output is retained in the logfile. The console only
# shows errors/summary, avoiding megabytes of unrelated third-party sources.
& $msbuild $project "/restore" "/m:2" "/t:Build" "/verbosity:minimal" "/consoleloggerparameters:ErrorsOnly;Summary" "/fileLogger" ("/fileLoggerParameters:LogFile="+$log+";Verbosity=normal") @props
if($LASTEXITCODE -ne 0){throw "HUB_PS2_EMBEDDED_BUILD_FAILED=$LASTEXITCODE; LOG=$log"}
$dll=Join-Path $output "uaibrain_ps2_embedded.dll"
$lib=Join-Path $output "uaibrain_ps2_embedded.lib"
if(!(Test-Path $dll) -or !(Test-Path $lib)){
 throw "HUB_PS2_BINARY_MISSING: $dll / $lib"
}
$resources=Join-Path $output "resources"
if(!(Test-Path $resources -PathType Container)){
 throw "HUB_PS2_RESOURCES_MISSING=$resources"
}
Write-Host "HUB_PS2_EMBEDDED_BUILD_OK" -ForegroundColor Green
Write-Host "HUB_PS2_EMBEDDED_DLL=$dll"
Write-Host "HUB_PS2_EMBEDDED_IMPLIB=$lib"
Write-Host "HUB_PS2_EMBEDDED_RUNTIME_DIR=$output"
Write-Host "HUB_PS2_FORK_SOURCE_DIR=$root"
Write-Host "ONE_APPX=yes; gameplay hardware validation pending"
