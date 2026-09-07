# Development checks only; the distributed helper has no Pester dependency.
# Run: Invoke-Pester ./tests/Windows.Tests.ps1

BeforeAll {
    $script:SourcePath = Join-Path (Split-Path $PSScriptRoot) 'Tailcat_OneShot.ps1'
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:SourcePath, [ref]$Tokens, [ref]$ParseErrors
    )
    if ($ParseErrors) { throw $ParseErrors[0] }
    foreach ($Definition in $Ast.FindAll({
        param ($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        . ([scriptblock]::Create($Definition.Extent.Text))
    }

    function New-EdgeSnapshot {
        param ([int]$Id, [int]$Parent, [datetime]$Created, [string]$CommandLine = 'msedge.exe')
        [pscustomobject]@{
            ProcessId = $Id; ParentProcessId = $Parent
            CreationDate = $Created; CommandLine = $CommandLine
        }
    }
}

Describe 'Tailcat errors' {
    BeforeEach {
        $script:Log = Join-Path $TestDrive 'stderr.log'
        $script:FailedProcess = [pscustomobject]@{ HasExited = $true; ExitCode = 7 }
    }

    It 'reports the exit code when the log is missing' {
        { Assert-TailcatRunning $script:FailedProcess $script:Log } | Should -Throw '*exit code 7*'
    }

    It 'handles an empty log during proxy startup' {
        [System.IO.File]::WriteAllText($script:Log, '')
        { Wait-ForSocks $script:FailedProcess 1080 $script:Log } | Should -Throw '*exit code 7*'
    }

    It 'includes useful stderr without surrounding whitespace' {
        Set-Content -LiteralPath $script:Log -Value '  connection refused  '
        { Assert-TailcatRunning $script:FailedProcess $script:Log } | Should -Throw '*connection refused'
    }

    It 'allows a running proxy to continue' {
        { Assert-TailcatRunning ([pscustomobject]@{HasExited = $false}) $script:Log } | Should -Not -Throw
    }

    It 'detects a failed native server' {
        $script:FakeServer = Join-Path $TestDrive 'server.cmd'
        Set-Content -LiteralPath $script:FakeServer -Value '@exit /b 7'
        Mock Get-Tailcat { $script:FakeServer }
        Mock Show-Network {}
        Mock Show-RuntimeInfo {}
        { Run-Server } | Should -Throw '*exit code 7*'
    }
}

Describe 'TCP forwarding' {
    BeforeEach {
        $script:Answers = [System.Collections.Generic.Queue[string]]::new()
        $script:Answers.Enqueue('tc-test-token')
        Mock Read-Host { $script:Answers.Dequeue() }
        Mock Get-Tailcat { 'tailcat.exe' }
        Mock Show-RuntimeInfo {}
        Mock Invoke-TailcatForeground {}
    }

    It 'passes one IPv4 mapping with an ephemeral identity to Tailcat' {
        $script:Answers.Enqueue('13389:192.168.1.20:3389')
        Run-Forward
        Should -Invoke Invoke-TailcatForeground -Times 1 -Exactly -ParameterFilter {
            $Binary -eq 'tailcat.exe' -and
            ($Arguments -join '|') -eq '--key=new|forward|tc-test-token|13389:192.168.1.20:3389'
        }
    }

    It 'passes IPv6 and an automatically selected local port unchanged' {
        $script:Answers.Enqueue('0:[fd00::20]:5432')
        Run-Forward
        Should -Invoke Invoke-TailcatForeground -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 4 -and $Arguments[3] -eq '0:[fd00::20]:5432'
        }
    }

    It 'rejects an empty mapping before downloading' {
        $script:Answers.Enqueue('')
        { Run-Forward } | Should -Throw '*mapping is required*'
        Should -Invoke Get-Tailcat -Times 0 -Exactly
    }
}

Describe 'Edge ownership' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive 'tailcat-session'
        $script:EdgeProfile = Join-Path $script:Root 'EdgeProfile'
        $script:EdgeProcessStarts = @{}
        $script:Created = [datetime]::UtcNow.AddMinutes(-1)
        # CIM creation times have microsecond precision.
        $script:Created = $script:Created.AddTicks(-($script:Created.Ticks % 10))
        $script:Snapshots = @()
        Mock Get-CimInstance { $script:Snapshots }
    }

    It 'finds descendants without profile arguments and excludes unrelated Edge' {
        $script:Snapshots = @(
            (New-EdgeSnapshot 102 101 $script:Created.AddSeconds(2)),
            (New-EdgeSnapshot 101 100 $script:Created.AddSeconds(1)),
            (New-EdgeSnapshot 100 1 $script:Created "msedge.exe --user-data-dir=$script:EdgeProfile"),
            (New-EdgeSnapshot 200 1 $script:Created)
        )
        $Found = @(Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses)
        ($Found.ProcessId | Sort-Object) -join ',' | Should -Be '100,101,102'
        @(Get-TemporaryEdgeProcesses).ProcessId | Should -Be 100
    }

    It 'forgets a reused PID and does not adopt its children' {
        $script:EdgeProcessStarts[100] = $script:Created.Ticks
        $script:Snapshots = @(
            (New-EdgeSnapshot 100 1 $script:Created.AddSeconds(10)),
            (New-EdgeSnapshot 101 100 $script:Created.AddSeconds(11))
        )
        @(Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses).Count | Should -Be 0
        $script:EdgeProcessStarts.Count | Should -Be 0
    }

    It 'retains an already identified child after its parent exits' {
        $script:EdgeProcessStarts[100] = $script:Created.Ticks
        $script:EdgeProcessStarts[101] = $script:Created.AddSeconds(1).Ticks
        $script:Snapshots = @((New-EdgeSnapshot 101 100 $script:Created.AddSeconds(1)))
        @(Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses).ProcessId | Should -Be 101
        $script:EdgeProcessStarts.ContainsKey(100) | Should -BeFalse
    }

    It 'does not adopt a child older than its alleged parent' {
        $script:Snapshots = @(
            (New-EdgeSnapshot 100 1 $script:Created "msedge.exe --user-data-dir=$script:EdgeProfile"),
            (New-EdgeSnapshot 101 100 $script:Created.AddSeconds(-10))
        )
        @(Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses).ProcessId | Should -Be 100
    }

    It 'checks creation time again immediately before stopping a process' {
        $script:Candidate = [pscustomobject]@{
            Handle = 123; StartTime = $script:Created.AddSeconds(10)
            HasExited = $false; Killed = $false; Disposed = $false
        }
        $script:Candidate | Add-Member ScriptMethod Kill { $this.Killed = $true }
        $script:Candidate | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        Mock Get-Process { $script:Candidate }
        $Snapshot = New-EdgeSnapshot 100 1 $script:Created
        Stop-EdgeProcess $Snapshot
        $script:Candidate.Killed | Should -BeFalse
        $script:Candidate.Disposed | Should -BeTrue

        $script:Candidate.StartTime = $script:Created.AddTicks(7)
        Stop-EdgeProcess $Snapshot
        $script:Candidate.Killed | Should -BeTrue
    }
}

Describe 'Runtime cleanup' {
    BeforeEach {
        $script:Runtime = Join-Path $TestDrive ('tailcat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Runtime | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Runtime 'runtime.log') -Value 'temporary'
        Mock Start-Sleep {}
    }

    It 'removes the owned directory and its contents' {
        Remove-RuntimeDirectory $script:Runtime $TestDrive
        Test-Path -LiteralPath $script:Runtime | Should -BeFalse
    }

    It 'refuses the base itself, an unexpected name and a different parent' {
        { Remove-RuntimeDirectory $TestDrive $TestDrive } | Should -Throw '*unexpected runtime path*'
        { Remove-RuntimeDirectory (Join-Path $TestDrive 'other') $TestDrive } | Should -Throw '*unexpected runtime path*'
        { Remove-RuntimeDirectory $script:Runtime (Join-Path $TestDrive 'other') } | Should -Throw '*unexpected runtime path*'
        Test-Path -LiteralPath (Join-Path $script:Runtime 'runtime.log') | Should -BeTrue
    }

    It 'preserves files outside the runtime when it contains a junction' {
        $Outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $Outside | Out-Null
        $Sentinel = Join-Path $Outside 'keep.txt'
        Set-Content -LiteralPath $Sentinel -Value 'keep'
        New-Item -ItemType Junction -Path (Join-Path $script:Runtime 'link') -Value $Outside | Out-Null
        Remove-RuntimeDirectory $script:Runtime $TestDrive
        Get-Content -LiteralPath $Sentinel | Should -Be 'keep'
    }

    It 'refuses a runtime root redirected by a junction' {
        $Redirected = Join-Path $TestDrive ('tailcat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Junction -Path $Redirected -Value $script:Runtime | Out-Null
        try {
            { Remove-RuntimeDirectory $Redirected $TestDrive } | Should -Throw '*redirected runtime directory*'
            Test-Path -LiteralPath (Join-Path $script:Runtime 'runtime.log') | Should -BeTrue
        }
        finally {
            [System.IO.Directory]::Delete($Redirected)
        }
    }

    It 'still restores the environment and removes files if process cleanup fails' {
        $script:EdgeProcess = $null
        $script:TailcatProcess = $null
        $script:EdgeProcessStarts = @{}
        $script:RuntimeCreated = $true
        $script:ExitCode = 0
        Mock Stop-TemporaryEdge { throw 'process cleanup failed' }
        Mock Stop-Tailcat {}
        Mock Restore-Environment {}
        Mock Remove-RuntimeDirectory {}
        Cleanup
        $script:ExitCode | Should -Be 1
        Should -Invoke Stop-Tailcat -Times 1 -Exactly
        Should -Invoke Restore-Environment -Times 1 -Exactly
        Should -Invoke Remove-RuntimeDirectory -Times 1 -Exactly
    }
}

Describe 'Real process identity' {
    It 'stops only the owned helper after matching its creation time' {
        $Executable = (Get-Command powershell.exe).Source
        $Owned = Start-Process -FilePath $Executable -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30'
        ) -WindowStyle Hidden -PassThru
        try {
            $null = $Owned.Handle
            $Snapshot = Get-CimInstance Win32_Process -Filter "ProcessId=$($Owned.Id)"
            Stop-EdgeProcess $Snapshot
            $Owned.WaitForExit(5000) | Should -BeTrue
        }
        finally {
            if (-not $Owned.HasExited) { $Owned.Kill(); $Owned.WaitForExit() }
            $Owned.Dispose()
        }
    }
}

Describe 'Bounded downloads' {
    BeforeEach {
        $script:OutputFile = Join-Path $TestDrive 'download.zip'
        $script:Attempts = 0
        Mock Start-Sleep {}
    }

    It 'recovers from a temporary failure using at most three attempts' {
        Mock Invoke-WebRequest {
            $script:Attempts++
            if ($script:Attempts -lt 3) { throw [System.Net.WebException]::new('temporary failure') }
            Set-Content -LiteralPath $OutFile -Value 'complete'
        }
        Invoke-Download 'https://example.invalid/archive.zip' $script:OutputFile
        $script:Attempts | Should -Be 3
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly -ParameterFilter { $TimeoutSec -eq 120 }
        (Get-Content -LiteralPath $script:OutputFile) | Should -Be 'complete'
    }

    It 'stops after three failures and removes partial data' {
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value 'partial'
            throw [System.Net.WebException]::new('temporary failure')
        }
        { Invoke-Download 'https://example.invalid/archive.zip' $script:OutputFile } | Should -Throw '*Download failed*'
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Test-Path -LiteralPath $script:OutputFile | Should -BeFalse
    }

    It 'does not retry a permanent HTTP error' {
        Mock Invoke-WebRequest {
            $Failure = [System.Exception]::new('Not found')
            $Failure | Add-Member NoteProperty Response ([pscustomobject]@{StatusCode = 404})
            throw $Failure
        }
        { Invoke-Download 'https://example.invalid/archive.zip' $script:OutputFile } | Should -Throw '*Not found*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }
}

Describe 'Release verification' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('tailcat-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root | Out-Null
        $script:TailcatVersion = 'v0.6.0'
        $script:ReleaseBaseUrl = 'https://example.invalid/v0.6.0'
        $script:ArchiveName = 'tailcat_0.6.0_windows_amd64.zip'
        $script:FixtureZip = Join-Path $TestDrive 'fixture.zip'
        $FakeBinary = Join-Path $TestDrive 'tailcat.exe'
        Set-Content -LiteralPath $FakeBinary -Value 'fixture, never executed'
        Compress-Archive -LiteralPath $FakeBinary -DestinationPath $script:FixtureZip -Force
        $Hash = (Get-FileHash -LiteralPath $script:FixtureZip -Algorithm SHA256).Hash
        $script:ChecksumText = "$Hash  $script:ArchiveName"
        Mock Invoke-Download {
            if ($Uri.EndsWith('/checksums.txt')) {
                Set-Content -LiteralPath $OutFile -Value $script:ChecksumText
            }
            else {
                Copy-Item -LiteralPath $script:FixtureZip -Destination $OutFile
            }
        }
    }

    It 'extracts a verified archive and returns its executable path' {
        $Binary = Get-Tailcat
        Test-Path -LiteralPath $Binary -PathType Leaf | Should -BeTrue
        Get-Content -LiteralPath $Binary | Should -Be 'fixture, never executed'
    }

    It 'does not extract an archive with a mismatched checksum' {
        $script:ChecksumText = ('0' * 64) + "  $script:ArchiveName"
        Mock Expand-Archive {}
        { Get-Tailcat } | Should -Throw '*SHA256 verification failed*'
        Should -Invoke Expand-Archive -Times 0 -Exactly
    }

    It 'requires an exact archive name in the checksums file' {
        $script:ChecksumText += '.other'
        { Get-Tailcat } | Should -Throw '*checksum*was not found*'
    }

    It 'restores TLS settings after a download failure' {
        $Before = [Net.ServicePointManager]::SecurityProtocol
        Mock Invoke-Download { throw 'download failed' }
        { Get-Tailcat } | Should -Throw '*download failed*'
        [Net.ServicePointManager]::SecurityProtocol | Should -Be $Before
    }
}

Describe 'Script exit status' {
    It 'returns 0 for Quit and 1 for invalid input, with no runtime directories left' {
        $Harness = Join-Path $TestDrive 'invoke.ps1'
        @'
param ([string]$Target, [string]$Choice)
$env:TEMP = $PSScriptRoot
function Read-Host { return $Choice }
function Clear-Host {}
& $Target
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $Harness
        $Shell = (Get-Process -Id $PID).Path
        & $Shell -NoProfile -NonInteractive -File $Harness $script:SourcePath Q
        $LASTEXITCODE | Should -Be 0
        & $Shell -NoProfile -NonInteractive -File $Harness $script:SourcePath invalid
        $LASTEXITCODE | Should -Be 1
        @(Get-ChildItem -LiteralPath $TestDrive -Directory -Filter 'tailcat-*').Count | Should -Be 0
    }
}
