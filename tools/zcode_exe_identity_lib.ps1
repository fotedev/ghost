#Requires -Version 5.1
<#
.SYNOPSIS
  ZCode-specific alias map for per-clone exe identity patching, on top of the
  GENERIC Task-Manager exe identity core (tools\exe_identity_lib.ps1, shared
  by all four suites since 2026-11-14). This module now carries ONLY the
  ZCode instance map; every pure mechanic (ico parsing, GRPICONDIR,
  VS_VERSIONINFO surgery) and the whole orchestration
  (Invoke-GhostExeIdentityPatch) live in the generic lib and arrive here via
  dot-source. Unit-tested by tests\zcode_exe_identity.Tests.ps1 (which
  dot-sources THIS file and thereby exercises the generic core transitively).
#>

. (Join-Path $PSScriptRoot 'exe_identity_lib.ps1')

function Get-ZcodeInstanceIdentityMap {
  # Per-clone exe-identity alias map. Parity-tested against $InstanceMap in
  # src\windows\launch_zcode_second_instance.ps1 (tests\zcode_exe_identity.Tests.ps1):
  # DisplayName + AumidSuffix + BrandingRepo must match exactly; ExeName is the
  # Task-Manager-identity copy the launcher starts clones from.
  # Frozen-keys rule: the instance keys (Second..Sixth) are plumbing; the
  # display vocabulary (Blue..Orange) is what users see, including the new
  # Task Manager group names.
  return @{
    'Second' = @{ ExeName = 'ZCode-Blue.exe';   DisplayName = 'Blue';   AumidSuffix = '2'; BrandingRepo = 'zcode-blue-branding' }
    'Third'  = @{ ExeName = 'ZCode-Yellow.exe'; DisplayName = 'Yellow'; AumidSuffix = '3'; BrandingRepo = 'zcode-yellow-branding' }
    'Fourth' = @{ ExeName = 'ZCode-Green.exe';  DisplayName = 'Green';  AumidSuffix = '4'; BrandingRepo = 'zcode-green-branding' }
    'Fifth'  = @{ ExeName = 'ZCode-Red.exe';    DisplayName = 'Red';    AumidSuffix = '5'; BrandingRepo = 'zcode-red-branding' }
    'Sixth'  = @{ ExeName = 'ZCode-Orange.exe'; DisplayName = 'Orange'; AumidSuffix = '6'; BrandingRepo = 'zcode-orange-branding' }
  }
}
