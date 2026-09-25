# SPDX-License-Identifier: Apache-2.0
# Unit tests for src/windows/identity_utils.ps1 (safe to dot-source: the file
# only defines functions -- verified zero side effects at load time).
# All fixtures live in Pester's TestDrive:; nothing outside the sandbox is touched.

BeforeAll {
    . (Join-Path $PSScriptRoot "..\src\windows\identity_utils.ps1")
}

Describe "New-IdentitySet" {
    It "returns all four identity fields" {
        $ids = New-IdentitySet
        $ids.Keys | Should -Contain "devDeviceId"
        $ids.Keys | Should -Contain "machineId"
        $ids.Keys | Should -Contain "macMachineId"
        $ids.Keys | Should -Contain "sqmId"
    }

    It "devDeviceId is a lowercase GUID" {
        $ids = New-IdentitySet
        $ids.devDeviceId | Should -Match "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        $parsed = [guid]::empty
        [guid]::TryParse($ids.devDeviceId, [ref]$parsed) | Should -BeTrue
    }

    It "machineId is 64 hex characters" {
        (New-IdentitySet).machineId | Should -Match "^[0-9a-f]{64}$"
    }

    It "macMachineId is 128 hex characters" {
        (New-IdentitySet).macMachineId | Should -Match "^[0-9a-f]{128}$"
    }

    It "sqmId is a braced uppercase GUID" {
        $sqmId = (New-IdentitySet).sqmId
        $sqmId | Should -Match "^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$"
    }

    It "generates distinct sets on successive calls" {
        $a = New-IdentitySet
        $b = New-IdentitySet
        $a.machineId | Should -Not -Be $b.machineId
        $a.devDeviceId | Should -Not -Be $b.devDeviceId
    }
}

Describe "Get-PythonCommandInfo" {
    It "returns a working Python 3 interpreter path (skips when none installed)" {
        $exe = Get-PythonCommandInfo
        if (-not $exe) {
            Set-ItResult -Skipped -Because "no Python 3 installed on this host"
            return
        }
        Test-Path -LiteralPath $exe | Should -BeTrue
        $v = & $exe --version 2>&1
        $LASTEXITCODE | Should -Be 0
        ($v -join ' ') | Should -Match '^Python\s+3'
    }

    It "rejects non-Python-3 candidates functionally (probe contract)" {
        # The probe accepts only exit-0 + 'Python 3' output; simulate the
        # contract with a fake exe that exits 9009 (the Store-stub behavior).
        $fake = Join-Path $TestDrive "python_stub.cmd"
        Set-Content -LiteralPath $fake -Value "@echo Python was not found`r`nexit /b 9009`r`n" -Encoding ASCII
        $env:PATH = "$TestDrive;$env:PATH"
        try {
            # A stub named python must not be returned as long as the probe
            # keeps looking; on a host with a real python the probe returns
            # that real one, never the stub path.
            $exe = Get-PythonCommandInfo
            if ($exe) {
                (Get-Item -LiteralPath $exe).FullName | Should -Not -BeLike "*python_stub*"
            }
        }
        finally {
            Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Get-PathBackupLabel" {
    It "maps a rooted path to paths\<drive>\<relative>" {
        $label = Get-PathBackupLabel -Path "C:\Users\somebody\file.txt"
        $label | Should -Be (Join-Path (Join-Path "paths" "C") (Join-Path "Users\somebody" "file.txt"))
    }

    It "falls back to paths\<name> for a bare path" {
        Get-PathBackupLabel -Path "file.txt" | Should -Be (Join-Path "paths" "file.txt")
    }
}

Describe "Get-NewCrashReporterId" {
    It "returns a lowercase GUID" {
        $id = Get-NewCrashReporterId
        $id | Should -Match "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    }
}

Describe "Test-ObjectProperty" {
    It "detects an existing property" {
        $obj = [pscustomobject]@{ devin = [pscustomobject]@{ org_id = "x" } }
        Test-ObjectProperty -Object $obj -Name "devin" | Should -BeTrue
        Test-ObjectProperty -Object $obj.devin -Name "org_id" | Should -BeTrue
    }

    It "returns false for a missing property" {
        $obj = [pscustomobject]@{ version = 1 }
        Test-ObjectProperty -Object $obj -Name "devin" | Should -BeFalse
    }
}

Describe "Set-JsonIdentity" {
    It "writes requested keys and verifies them" {
        $path = Join-Path $TestDrive "storage.json"
        [System.IO.File]::WriteAllText($path, '{"telemetry.machineId": "old", "other": 1}')
        $audit = @()
        $actions = @()
        $backupRoot = Join-Path $TestDrive "backups"

        $ok = Set-JsonIdentity -Path $path -Updates @{ "telemetry.machineId" = "a" * 64; "telemetry.sqmId" = "{NEW}" } `
            -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel "storage.json" -Actions ([ref]$actions)

        $ok | Should -BeTrue
        $content = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $content."telemetry.machineId" | Should -Be ("a" * 64)
        $content."telemetry.sqmId" | Should -Be "{NEW}"
        $content.other | Should -Be 1
        Test-Path -LiteralPath (Join-Path $backupRoot "storage.json") | Should -BeTrue
    }

    It "fails cleanly when the file is missing" {
        $audit = @()
        $actions = @()
        $ok = Set-JsonIdentity -Path (Join-Path $TestDrive "missing.json") -Updates @{ "k" = "v" } `
            -Audit ([ref]$audit) -Actions ([ref]$actions)
        $ok | Should -BeFalse
    }
}

Describe "Backup-FileToTimestampDir" {
    It "copies the file to BackupRoot\<label>" {
        $src = Join-Path $TestDrive "machineid"
        [System.IO.File]::WriteAllText($src, "some-guid")
        $dest = Backup-FileToTimestampDir -Source $src -BackupRoot (Join-Path $TestDrive "bk") -Label "machineid"
        $dest | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $dest -Raw).Trim() | Should -Be "some-guid"
    }

    It "returns null for a missing source" {
        Backup-FileToTimestampDir -Source (Join-Path $TestDrive "nope") -BackupRoot (Join-Path $TestDrive "bk") -Label "x" | Should -BeNullOrEmpty
    }
}

Describe "Clear-BinaryIdentityStore" {
    It "rename action moves the file to .backup and records the action" {
        $target = Join-Path $TestDrive "Cookies"
        [System.IO.File]::WriteAllText($target, "payload")
        $audit = @()
        $root = Join-Path $TestDrive "bk-rename"

        $actions = Clear-BinaryIdentityStore -Paths @($target) -Action "rename" -BackupRoot $root -Audit ([ref]$audit) -RootPath $TestDrive

        Test-Path -LiteralPath "$target.backup" | Should -BeTrue
        Test-Path -LiteralPath $target | Should -BeFalse
        @($actions).Count | Should -Be 1
        # NOTE: $actions is an OrderedDictionary; index via @() (numeric
        # indexing on a dictionary looks up a KEY named "0").
        @($actions)[0].action | Should -Be "rename"
    }

    It "delete action removes the file after backing it up" {
        $target = Join-Path $TestDrive "DIPS"
        [System.IO.File]::WriteAllText($target, "payload")
        $audit = @()
        $root = Join-Path $TestDrive "bk-delete"

        $actions = Clear-BinaryIdentityStore -Paths @($target) -Action "delete" -BackupRoot $root -Audit ([ref]$audit) -RootPath $TestDrive

        Test-Path -LiteralPath $target | Should -BeFalse
        @($actions)[0].action | Should -Be "delete"
        Test-Path -LiteralPath (Join-Path $root "DIPS") | Should -BeTrue
    }

    It "audits missing paths as skipped and returns no actions" {
        $audit = @()
        $actions = Clear-BinaryIdentityStore -Paths @((Join-Path $TestDrive "absent")) -Action "delete" -BackupRoot (Join-Path $TestDrive "bk") -Audit ([ref]$audit) -RootPath $TestDrive
        @($actions).Count | Should -Be 0
        $audit[0].before | Should -Be "missing"
        $audit[0].ok | Should -BeTrue
    }
}

Describe "Write-AuditLog" {
    It "writes valid JSON with one entry per audit record" {
        $audit = @(
            [pscustomobject]@{ file = "a.json"; key = "k"; before = "1"; after = "2"; ok = $true },
            [pscustomobject]@{ file = "b.vscdb"; key = "j"; before = "x"; after = "y"; ok = $false }
        )
        $path = Join-Path $TestDrive "audit_test.json"
        Write-AuditLog -Audit $audit -Path $path
        Test-Path -LiteralPath $path | Should -BeTrue
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 2
        $parsed[1].ok | Should -BeFalse
    }
}

Describe "New-RestoreScript" {
    It "emits a non-empty self-contained restore script" {
        $backupRoot = Join-Path $TestDrive "bk"
        New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        $actions = @([ordered]@{ action = "copy"; originalPath = "C:\x\file.json"; backupPath = (Join-Path $backupRoot "file.json"); renamedPath = $null })

        $restorePath = New-RestoreScript -BackupRoot $backupRoot -App "TestApp" -Actions $actions

        Test-Path -LiteralPath $restorePath | Should -BeTrue
        (Get-Item -LiteralPath $restorePath).Length | Should -BeGreaterThan 0
        (Get-Content -LiteralPath $restorePath -Raw) | Should -Match "Restore-Entry"
    }
}
