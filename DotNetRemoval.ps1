# Remove .NET Core 3/5/6/7 (Runtime, Windows Desktop, ASP.NET Core) from HKLM/HKU and prune orphaned Program Files\dotnet folders; never delete 8.* or 9.* (PowerShell 5.1, run as admin)

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
  IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $IsAdmin) { Write-Error "Run PowerShell as Administrator."; exit 1 }

$NameInclude = '(?i)^(?:Microsoft\s+)?(?:(?:\.NET(?:\sCore)?\sRuntime)|(?:Windows\s+Desktop\s+Runtime)|(?:ASP\.?NET\s+Core.*?(?:Runtime|Shared\sFramework)))\b'
$NameExclude = '(?i)(Targeting\s*Pack|Developer\s*Pack|Templates|AppHost\s*Pack|Windows\s+SDK|TargetingPack|Host\s*FXR|Shared\sHost)'
$VersionOK   = '^(3(\.\d+)?|5|6|7)\.'

function Get-GuidFrom {
  param([string]$KeyName,[string]$UninstallString)
  $pc = $null
  if ($KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$') { $pc = $KeyName }
  elseif ($UninstallString -and ($UninstallString -match '\{[0-9A-Fa-f\-]{36}\}')) { $pc = $matches[0] }
  return $pc
}

function Get-LocalCoreEntries {
  $out = @()

  foreach ($root in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $p  = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
        $dn = $p.DisplayName; if (-not $dn) { return }
        if ($dn -notmatch $NameInclude) { return }
        if ($dn -match  $NameExclude)  { return }
        $ver = $p.DisplayVersion; if (-not $ver -or $ver -notmatch $VersionOK) { return }
        $us  = $p.UninstallString
        $qus = $p.QuietUninstallString
        $pc  = Get-GuidFrom -KeyName $_.PSChildName -UninstallString $us
        $out += [pscustomobject]@{
          Hive='HKLM'; Path=$_.Name; Name=$dn; Version=$ver;
          ProductCode=$pc; UninstallString=$us; QuietUninstallString=$qus
        }
      } catch {}
    }
  }

  Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-\d-\d+-(\d+-){1,}\d+$' } |
    ForEach-Object {
      $sid = $_.PSChildName
      foreach ($sub in @(
        "HKU:\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKU:\$sid\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
      )) {
        if (-not (Test-Path $sub)) { continue }
        Get-ChildItem $sub -ErrorAction SilentlyContinue | ForEach-Object {
          try {
            $p  = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
            $dn = $p.DisplayName; if (-not $dn) { return }
            if ($dn -notmatch $NameInclude) { return }
            if ($dn -match  $NameExclude)  { return }
            $ver = $p.DisplayVersion; if (-not $ver -or $ver -notmatch $VersionOK) { return }
            $us  = $p.UninstallString
            $qus = $p.QuietUninstallString
            $pc  = Get-GuidFrom -KeyName $_.PSChildName -UninstallString $us
            $out += [pscustomobject]@{
              Hive='HKU'; Path=$_.Name; Name=$dn; Version=$ver;
              ProductCode=$pc; UninstallString=$us; QuietUninstallString=$qus
            }
          } catch {}
        }
      }
    }

  $out
}

function Invoke-SilentUninstall {
  param([string]$UninstallString,[string]$QuietUninstallString,[string]$ProductCode)
  $maxRetry = 3
  for ($i=0; $i -lt $maxRetry; $i++) {
    try {
      if ($QuietUninstallString) {
        $cmd = $QuietUninstallString; if ($cmd -notmatch '(?i)/norestart') { $cmd += ' /norestart' }
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -Wait -PassThru -WindowStyle Hidden
      }
      elseif ($ProductCode) {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $ProductCode, '/qn', '/norestart', 'IGNOREDEPENDENCIES=ALL') -Wait -PassThru -WindowStyle Hidden
      }
      elseif ($UninstallString) {
        if ($UninstallString -match '(?i)msiexec(\.exe)?' -and ($UninstallString -match '\{[0-9A-Fa-f\-]{36}\}')) {
          $guid = $matches[0]
          $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $guid, '/qn', '/norestart', 'IGNOREDEPENDENCIES=ALL') -Wait -PassThru -WindowStyle Hidden
        } else {
          $cmd = $UninstallString
          if ($cmd -notmatch '(?i)\s/quiet')   { $cmd += ' /quiet' }
          if ($cmd -notmatch '(?i)/norestart') { $cmd += ' /norestart' }
          $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -Wait -PassThru -WindowStyle Hidden
        }
      } else { return $null }

      $code = $p.ExitCode
      if ($code -eq 1618) { Start-Sleep -Seconds 30; continue }
      return $code
    } catch { Start-Sleep -Seconds 5 }
  }
  return $null
}

$entries = Get-LocalCoreEntries
if ($entries -and $entries.Count -gt 0) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($e in ($entries | Sort-Object Name, Version)) {
    $sig = if ($e.ProductCode) { "PC|$($e.ProductCode)" } elseif ($e.QuietUninstallString) { "Q|$($e.QuietUninstallString)" } else { "U|$($e.UninstallString)" }
    if ($seen.Add($sig)) { [void](Invoke-SilentUninstall -UninstallString $e.UninstallString -QuietUninstallString $e.QuietUninstallString -ProductCode $e.ProductCode) }
  }
}

function Get-DotNetInstalledMap {
  $map = @{
    'Microsoft.NETCore.App'        = (New-Object 'System.Collections.Generic.HashSet[string]')
    'Microsoft.WindowsDesktop.App' = (New-Object 'System.Collections.Generic.HashSet[string]')
    'Microsoft.AspNetCore.App'     = (New-Object 'System.Collections.Generic.HashSet[string]')
    'SDK'                          = (New-Object 'System.Collections.Generic.HashSet[string]')
  }
  $dotnet = $null; $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
  if ($cmd) { $dotnet = ($cmd | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue) }
  if ($dotnet) {
    try {
      & $dotnet --list-runtimes 2>$null | ForEach-Object {
        if ($_ -match '^(?<fam>Microsoft\.[A-Za-z\.]+)\s+(?<ver>\d+\.\d+\.\d+(?:-[^\s]+)?)\s+\[') {
          $fam = $matches['fam']; $ver = $matches['ver']; if ($map.ContainsKey($fam)) { [void]$map[$fam].Add($ver) }
        }
      }
      & $dotnet --list-sdks 2>$null | ForEach-Object {
        if ($_ -match '^(?<ver>\d+\.\d+\.\d+(?:-[^\s]+)?)\s+\[') { [void]$map['SDK'].Add($matches['ver']) }
      }
    } catch {}
  }
  $map
}

function Remove-LegacyDotNetFolders {
  $map   = Get-DotNetInstalledMap
  $hasMapData = (($map.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum -gt 0)

  $roots = @()
  if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'dotnet') }
  $pf86 = ${env:ProgramFiles(x86)}; if ($pf86) { $roots += (Join-Path $pf86 'dotnet') }

  $families = @(
    @{ Name='Microsoft.NETCore.App';        Rel='shared\Microsoft.NETCore.App' },
    @{ Name='Microsoft.WindowsDesktop.App'; Rel='shared\Microsoft.WindowsDesktop.App' },
    @{ Name='Microsoft.AspNetCore.App';     Rel='shared\Microsoft.AspNetCore.App' }
  )

  foreach ($root in $roots | Where-Object { $_ -and (Test-Path $_) }) {

    foreach ($fam in $families) {
      $base = Join-Path $root $fam.Rel
      if (-not (Test-Path $base)) { continue }
      Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $ver = $_.Name
        if ($ver -notmatch '^(?<maj>\d+)\.\d+\.\d+(-.+)?$') { return }
        $maj = [int]$matches['maj']
        if ($maj -ge 8) { return }  # hard guard: never delete 8.* or 9.*

        $keep = $false
        if ($hasMapData -and $map.ContainsKey($fam.Name)) { $keep = $map[$fam.Name].Contains($ver) }

        if (-not $keep) {
          try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
        }
      }
      if (-not (Get-ChildItem $base -Force -ErrorAction SilentlyContinue | Where-Object { $_ })) {
        Remove-Item -LiteralPath $base -Force -ErrorAction SilentlyContinue
      }
    }

    $fxr = Join-Path $root 'host\fxr'
    if (Test-Path $fxr) {
      Get-ChildItem $fxr -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $ver = $_.Name
        if ($ver -notmatch '^(?<maj>\d+)\.\d+\.\d+(-.+)?$') { return }
        $maj = [int]$matches['maj']
        if ($maj -ge 8) { return }  # hard guard

        $keep = $false
        if ($hasMapData) {
          $keep = $map['Microsoft.NETCore.App'].Contains($ver) -or
                  $map['Microsoft.WindowsDesktop.App'].Contains($ver) -or
                  $map['Microsoft.AspNetCore.App'].Contains($ver)
        }
        if (-not $keep) {
          try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
        }
      }
      if (-not (Get-ChildItem $fxr -Force -ErrorAction SilentlyContinue | Where-Object { $_ })) {
        Remove-Item -LiteralPath $fxr -Force -ErrorAction SilentlyContinue
      }
    }

    $sdk = Join-Path $root 'sdk'
    if (Test-Path $sdk) {
      Get-ChildItem $sdk -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $ver = $_.Name
        if ($ver -notmatch '^(?<maj>\d+)\.\d+\.\d+(-.+)?$') { return }
        $maj = [int]$matches['maj']
        if ($maj -ge 8) { return }  # hard guard

        $keep = $false
        if ($hasMapData) { $keep = $map['SDK'].Contains($ver) }
        if (-not $keep) {
          try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
        }
      }
      if (-not (Get-ChildItem $sdk -Force -ErrorAction SilentlyContinue | Where-Object { $_ })) {
        Remove-Item -LiteralPath $sdk -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

$found = Get-LocalCoreEntries
if ($found -and $found.Count -gt 0) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($e in ($found | Sort-Object Name, Version)) {
    $sig = if ($e.ProductCode) { "PC|$($e.ProductCode)" } elseif ($e.QuietUninstallString) { "Q|$($e.QuietUninstallString)" } else { "U|$($e.UninstallString)" }
    if ($seen.Add($sig)) { [void](Invoke-SilentUninstall -UninstallString $e.UninstallString -QuietUninstallString $e.QuietUninstallString -ProductCode $e.ProductCode) }
  }
}
Remove-LegacyDotNetFolders
