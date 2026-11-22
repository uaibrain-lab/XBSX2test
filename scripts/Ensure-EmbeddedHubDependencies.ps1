# Prepare native XBSX2/PCSX2 UWP dependencies for the ONE-APPX Hub.
# Existing successful dependencies are reused, not rebuilt each time.
[CmdletBinding()]
param(
 [string]$Root=(Split-Path -Parent $PSScriptRoot),
 [switch]$CheckOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$root=[IO.Path]::GetFullPath($Root)
$version="3.0.260818.1"
$nugetProps=Join-Path $root ("packages\Microsoft.Windows.CppWinRT."+$version+"\build\native\Microsoft.Windows.CppWinRT.props")
$nugetTargets=Join-Path $root ("packages\Microsoft.Windows.CppWinRT."+$version+"\build\native\Microsoft.Windows.CppWinRT.targets")
$dependencyFiles=@(
 "include\freetype2\ft2build.h",
 "include\directx\d3d12.h",
 "include\zstd.h",
 "include\zlib.h",
 "lib\freetype.lib",
 "lib\zstd.lib",
 "bin\SDL3.dll"
)
function Get-MissingDeps {
 return @($dependencyFiles | Where-Object {
  -not (Test-Path -LiteralPath (Join-Path (Join-Path $root "deps") $_) -PathType Leaf)
 })
}
$missing=@(Get-MissingDeps)
$nugetOk=(Test-Path -LiteralPath $nugetProps -PathType Leaf) -and (Test-Path -LiteralPath $nugetTargets -PathType Leaf)
Write-Host "HUB_PS2_NUGET_READY=$nugetOk"
Write-Host "HUB_PS2_DEPS_MISSING=$($missing.Count)"
foreach($file in $missing){Write-Host "HUB_PS2_MISSING=deps\$file"}
if($CheckOnly){
 if($missing.Count -gt 0 -or -not $nugetOk){throw "HUB_PS2_PREREQUISITES_MISSING"}
 Write-Host "HUB_PS2_PREREQUISITES_OK"
 return
}
if(-not $nugetOk){
 $command=Get-Command nuget.exe -ErrorAction SilentlyContinue
 $nuget=if($command){$command.Source}else{""}
 if(-not $nuget){
  $toolDir=Join-Path $root ".hub-build-tools"
  [IO.Directory]::CreateDirectory($toolDir)|Out-Null
  $nuget=Join-Path $toolDir "nuget.exe"
  if(-not (Test-Path -LiteralPath $nuget -PathType Leaf)){
   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
   Write-Host "HUB_PS2_DOWNLOAD_NUGET_FROM_OFFICIAL_SOURCE"
   Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nuget -UseBasicParsing
  }
 }
 Write-Host "HUB_PS2_RESTORING_CPPWINRT=$version"
 & $nuget install Microsoft.Windows.CppWinRT -Version $version -OutputDirectory (Join-Path $root "packages") -Source "https://api.nuget.org/v3/index.json" -NonInteractive -Verbosity normal
 if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nugetProps -PathType Leaf) -or -not (Test-Path -LiteralPath $nugetTargets -PathType Leaf)){
  throw "HUB_PS2_CPPWINRT_RESTORE_FAILED: check HTTPS access to nuget.org"
 }
}
if($missing.Count -gt 0){
 $bat=Join-Path $root ".github\workflows\scripts\uwp\build-dependencies-uwp.bat"
 if(-not (Test-Path -LiteralPath $bat -PathType Leaf)){throw "HUB_PS2_DEPS_SCRIPT_MISSING=$bat"}
 $sevenCommand=Get-Command 7z.exe -ErrorAction SilentlyContinue
 $seven=if($sevenCommand){$sevenCommand.Source}else{""}
 if(-not $seven){
  $seven=@(
   (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
   (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) '7-Zip\7z.exe')
  )|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
 }
 if(-not $seven){throw "HUB_PS2_NEEDS_7ZIP: install 7-Zip (winget install --id 7zip.7zip -e)"}
 $env:SEVENZIP='"'+$seven+'"'
 # Never use the first patch.exe on PATH. Strawberry Perl exposes an
 # incompatible/crashing patch.exe at C:\Strawberry\c\bin\patch.exe.
 # Only the Git for Windows copy is supported by our upstream UWP patches.
 $gitTool=Get-Command git.exe -ErrorAction SilentlyContinue
 $gitRoots=@()
 if($gitTool){
  $gitBin=Split-Path -Parent $gitTool.Source
  $gitRoots+=Split-Path -Parent $gitBin
 }
 $gitRoots+=@(
  "C:\Program Files\Git",
  "C:\Program Files (x86)\Git",
  "E:\Program Files\Git",
  "E:\Git"
 )
 $patchPath=$null
 foreach($gitRoot in ($gitRoots|Select-Object -Unique)){
  $candidate=Join-Path $gitRoot 'usr\bin\patch.exe'
  if(Test-Path -LiteralPath $candidate -PathType Leaf){
   $patchPath=$candidate
   break
  }
 }
 if(-not $patchPath){
  throw "HUB_PS2_NEEDS_GIT_PATCH: Git for Windows usr\bin\patch.exe not found. Strawberry patch.exe is unsupported."
 }
 if($patchPath -match '(?i)strawberry'){
  throw "HUB_PS2_UNSAFE_PATCH_TOOL=$patchPath"
 }
 $env:PATCH='"'+$patchPath+'"'
 Write-Host "HUB_PS2_PATCH_TOOL=$patchPath"
 $vswhere=Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) 'Microsoft Visual Studio\Installer\vswhere.exe'
 if(Test-Path -LiteralPath $vswhere){
  $vsDirs=@(& $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath)
  foreach($vs in $vsDirs){
   if(-not $vs){continue}
   $cmakeDir=Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
   $ninjaDir=Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
   foreach($folder in @($cmakeDir,$ninjaDir)){
    if(Test-Path -LiteralPath $folder -PathType Container){$env:PATH=$folder+';'+$env:PATH}
   }
  }
 }
 foreach($exe in @('cmake.exe','ninja.exe','curl.exe','tar.exe','certutil.exe')){
  if(-not (Get-Command $exe -ErrorAction SilentlyContinue)){
   throw "HUB_PS2_NEEDS_TOOL=$exe; install VS C++ CMake/Ninja and Windows build tools"
  }
 }
 $env:DEBUG="0"
 $env:HUB_DEPS_NONINTERACTIVE="1"
 Write-Host "HUB_PS2_BUILDING_ORIGINAL_UWP_DEPS"
 & $env:ComSpec /d /c ('"'+$bat+'"')
 if($LASTEXITCODE -ne 0){throw "HUB_PS2_UWP_DEPENDENCIES_FAILED=$LASTEXITCODE"}
 $missing=@(Get-MissingDeps)
 if($missing.Count -gt 0){throw ("HUB_PS2_DEPS_INCOMPLETE="+($missing -join ','))}
}
Write-Host "HUB_PS2_PREREQUISITES_OK" -ForegroundColor Green
