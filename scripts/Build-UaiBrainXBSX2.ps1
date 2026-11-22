# Xbox UWP x64 package for the separate UaiBrain XBSX2 engine.
# Requires Windows, VS 2026/2022 C++ UWP tools and Windows SDK.
# Does not include games, BIOS or third-party keys.
[CmdletBinding()]
param(
 [string]$RepoRoot=(Split-Path -Parent $PSScriptRoot),
 [ValidateSet("Release","Debug")][string]$Configuration="Release",
 [string]$OutputDir="",
 [string]$Thumbprint=""
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
if($env:OS -ne "Windows_NT"){throw "BUILD_REQUIRES_WINDOWS"}
$root=[IO.Path]::GetFullPath($RepoRoot)
$project=Join-Path $root "pcsx2-uwp\pcsx2-uwp.vcxproj"
$manifest=Join-Path $root "pcsx2-uwp\Package.appxmanifest"
if(!(Test-Path -LiteralPath $project -PathType Leaf)){throw "XBSX2_PROJECT_MISSING=$project"}
if(!(Select-String -LiteralPath $manifest -Pattern 'Name="UaiBrain.XBSX2Engine"' -Quiet)){
 throw "XBSX2_NOT_HUB_ENGINE: wrong branch/manifest"
}
if(!(Select-String -LiteralPath $manifest -Pattern 'Name="uaibrain-xbsx2"' -Quiet)){
 throw "XBSX2_PROTOCOL_MISMATCH"
}
if(-not $OutputDir){$OutputDir=Join-Path $root "build\hub-ps2-AppPackages"}
$out=[IO.Path]::GetFullPath($OutputDir)
[IO.Directory]::CreateDirectory($out)|Out-Null
$msbuild=""
$vswhere=Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Microsoft Visual Studio\Installer\vswhere.exe"
if(Test-Path $vswhere){
 $found=& $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
 if($LASTEXITCODE -eq 0 -and $found){
  $candidate=Join-Path ($found|Select-Object -First 1) "MSBuild\Current\Bin\MSBuild.exe"
  if(Test-Path $candidate){$msbuild=$candidate}
 }
}
if(-not $msbuild){
 foreach($candidate in @(
  "E:\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
  "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
  "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
 )){
  if(Test-Path $candidate){$msbuild=$candidate;break}
 }
}
if(-not $msbuild){throw "MSBUILD_NOT_FOUND: install VS2026/2022 C++ UWP build tools"}
$sign=$false
if($Thumbprint){
 $cert=Get-Item ("Cert:\CurrentUser\My\"+$Thumbprint) -ErrorAction SilentlyContinue
 if(-not $cert -or -not $cert.HasPrivateKey -or
   $cert.Subject -ne "CN=UaiBrainDev" -or
   $cert.NotAfter -le (Get-Date)){
  throw "SIGNING_CERT_INVALID: requires CN=UaiBrainDev and private key"
 }
 $sign=$true
}
$props=@(
 "/p:Configuration=$Configuration",
 "/p:Platform=x64",
 "/p:AppxBundle=Always",
 "/p:AppxBundlePlatforms=x64",
 "/p:UapAppxPackageBuildMode=SideLoadOnly",
 "/p:AppxPackageDir=$($out.TrimEnd('\'))\",
 "/p:AppxPackageSigningEnabled=$sign"
)
if($sign){
 $props+="/p:PackageCertificateThumbprint=$Thumbprint"
 $props+="/p:PackageCertificateKeyFile="
}
Write-Host "HUB_PS2_BUILD=$msbuild"
Write-Host "HUB_PS2_IDENTITY=UaiBrain.XBSX2Engine"
Write-Host "HUB_PS2_PROTOCOL=uaibrain-xbsx2:"
Write-Host "HUB_PS2_SIGNED=$sign"
& $msbuild $project "/restore" "/m:2" "/t:Build" @props
if($LASTEXITCODE -ne 0){throw "HUB_PS2_BUILD_FAILED=$LASTEXITCODE"}
$packages=Get-ChildItem -LiteralPath $out -Recurse -File |
 Where-Object {$_.Extension -in @(".msixbundle",".appxbundle",".appx",".msix")} |
 Sort-Object LastWriteTime -Descending
if(-not $packages){throw "HUB_PS2_PACKAGE_MISSING=$out"}
Write-Host "HUB_PS2_PACKAGE=$($packages[0].FullName)" -ForegroundColor Green
if(-not $sign){
 Write-Warning "Package is UNSIGNED. Sign with a valid CN=UaiBrainDev cert before Xbox installation."
}
Write-Host "HUB_PS2_GAME_MODE_REQUIRED=YES"
Write-Host "HUB_PS2_HARDWARE_VALIDATION=PENDING"
