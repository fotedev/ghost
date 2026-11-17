# SPDX-License-Identifier: Apache-2.0
# Tests for the ZCode Linux clone layer (PR 8, 2026-11-17):
# launch_zcode_clone.sh + launch_zcode_cli_light.sh + the reset --instance
# mode + the ghost.sh menu wiring. Static contract only - text assertions
# need no bash; syntax is gated by bash -n in CI, and every live behavior
# (real seed, real launch, real reset) is user-supervised on a Linux host
# (the vendored ZCode evidence is recorded in the launcher header).

Describe 'ZCode Linux clone launcher - contract' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\src\linux\launch_zcode_clone.sh")).Path)
    }

    It 'sets all FIVE env levers (the Windows launcher set, Linux-spelled)' {
        foreach ($lever in @('ZCODE_HOME=', 'ZCODE_DATA_BASE_DIR=', 'ZCODE_DESKTOP_USER_DATA_DIR=', 'ZCODE_DESKTOP_SESSION_DATA_DIR=', 'ZCODE_DESKTOP_HOME_DIR=')) {
            ($script:Raw -match [regex]::Escape("export $lever")) | Should -BeTrue
        }
    }

    It 'uses the FROZEN cross-platform clone layout (ZCode<Name>Home + ZCode-<Name>)' {
        foreach ($name in @('ZCodeSecondHome', 'ZCodeThirdHome', 'ZCodeFourthHome', 'ZCodeFifthHome', 'ZCodeSixthHome',
                            'ZCode-Second', 'ZCode-Third', 'ZCode-Fourth', 'ZCode-Fifth', 'ZCode-Sixth')) {
            ($script:Raw -match [regex]::Escape($name)) | Should -BeTrue
        }
    }

    It 'FAILS CLOSED on a failed seed identity scrub (a clone never runs on Primary identity)' {
        ($script:Raw -match 'a clone must NEVER run on Primary identity - FAILING CLOSED') | Should -BeTrue
        ($script:Raw -match 'exit 1') | Should -BeTrue
    }

    It 'carries the seed marker gates (.zcode-seeding pre-marker + .zcode-seeded completion)' {
        ($script:Raw -match '\.zcode-seeding') | Should -BeTrue
        ($script:Raw -match '\.zcode-seeded') | Should -BeTrue
    }

    It 'waits for a closed Primary before a FIRST seed (the shared CLI db is held by every instance)' {
        ($script:Raw -match 'FAILING CLOSED') | Should -BeTrue
        ($script:Raw -match 'PRIMARY_CLOSED_WAIT') | Should -BeTrue
    }

    It 'requires --instance and validates against the frozen map' {
        ($script:Raw -match '--instance is required') | Should -BeTrue
        ($script:Raw -match 'unknown instance') | Should -BeTrue
    }

    It 'excludes the live CLI locks from the seed copy' {
        ($script:Raw -match "exclude 'cli/db/db.sqlite\*'") | Should -BeTrue
        ($script:Raw -match "exclude 'v2/tasks-index.sqlite\*'") | Should -BeTrue
    }

    It 'documents the identity story honestly (no property store on Linux)' {
        ($script:Raw -match 'NO AppUserModel.ID on Linux') | Should -BeTrue
        ($script:Raw -match 'DERIVED') | Should -BeTrue
    }
}

Describe 'ZCode Linux light worker - contract' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\src\linux\launch_zcode_cli_light.sh")).Path)
    }

    It 'sets the headless CLI levers (ZCODE_HOME / DATA_BASE_DIR / STORAGE_DIR / BUILTIN)' {
        foreach ($lever in @('ZCODE_HOME=', 'ZCODE_DATA_BASE_DIR=', 'ZCODE_STORAGE_DIR=', 'ZCODE_BUILTIN_PROVIDER_CONFIG_FILE=')) {
            ($script:Raw -match [regex]::Escape("export $lever")) | Should -BeTrue
        }
    }

    It 'does NOT export the desktop-userData levers (headless = no Electron)' {
        ($script:Raw -match 'export ZCODE_DESKTOP_USER_DATA_DIR=') | Should -BeFalse -Because 'the desktop levers are irrelevant headless and the first draft juggled them with a broken shell idiom'
    }

    It 'carries the free-model login recipe (the Windows light-worker verified limit)' {
        ($script:Raw -match 'login zai') | Should -BeTrue
        ($script:Raw -match 'opencode-zen') | Should -BeTrue
    }

    It 'refuses a clone home that was never seeded' {
        ($script:Raw -match 'launch the desktop clone once') | Should -BeTrue
    }

    It 'is heredoc-free (repo convention)' {
        ($script:Raw -match "<<'") | Should -BeFalse
    }
}

Describe 'reset_zcode.sh --instance mode' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\src\linux\reset_zcode.sh")).Path)
    }

    It 'roots the SAME v0.2 steps at the frozen clone layout on --instance' {
        ($script:Raw -match 'CLI_DIR_OVERRIDE="\$HOME/\$\{CLONE_HOME_NAME\[\$RESET_INSTANCE\]\}/\.zcode"') | Should -BeTrue
        ($script:Raw -match 'CONFIG_ROOT="\$HOME/\$\{CLONE_USERDATA_NAME\[\$RESET_INSTANCE\]\}"') | Should -BeTrue
    }

    It 'sweeps the clone userData (config + session) backup-first, clone-only' {
        ($script:Raw -match 'Clone userData cleanup') | Should -BeTrue
        ($script:Raw -match 'sweep-tree "\$SUB_DIR"') | Should -BeTrue
        ($script:Raw -match '\$IS_CLONE" -eq 1' ) | Should -BeTrue
    }

    It 'relaxes the absent-config abort for clones only (Primary stays fail-closed)' {
        ($script:Raw -match 'ZCode installation not found') | Should -BeTrue
        ($script:Raw -match 'IS_CLONE" -eq 1 ]]; then') | Should -BeTrue
    }
}

Describe 'ghost.sh menu wiring' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\ghost.sh")).Path)
    }

    It 'renders options 10-12 and dispatches the three Linux tools' {
        ($script:Raw -match '10\) Launch a ZCode clone') | Should -BeTrue
        ($script:Raw -match '11\) Reset a ZCode clone') | Should -BeTrue
        ($script:Raw -match '12\) Launch a light headless worker') | Should -BeTrue
        ($script:Raw -match 'launch_zcode_clone\.sh" --instance "\$inst"') | Should -BeTrue
        ($script:Raw -match 'reset_zcode\.sh" --instance "\$inst"') | Should -BeTrue
        ($script:Raw -match 'launch_zcode_cli_light\.sh" --instance "\$inst"') | Should -BeTrue
    }

    It 'the prompt range covers the new options' {
        ($script:Raw -match 'Select an option \[0-12\]') | Should -BeTrue
    }
}
