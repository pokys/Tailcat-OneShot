# Tailcat-OneShot
# One-shot Windows helper for Tailcat.
#
# https://github.com/tailscale/tailcat
#
# Tailcat version is intentionally pinned because upstream currently
# does not guarantee CLI/API/wire-format stability.

$ErrorActionPreference = "Stop"

$TailcatVersion  = "v0.6.0"
$ReleaseBaseUrl = "https://github.com/tailscale/tailcat/releases/download/$TailcatVersion"

$TempBase    = [System.IO.Path]::GetFullPath($env:TEMP)
$Root        = Join-Path $TempBase ("tailcat-" + [guid]::NewGuid().ToString("N"))
$EdgeProfile = Join-Path $Root "EdgeProfile"
$RuntimeCreated = $false
$script:ExitCode = 0

$OldAppData      = $env:APPDATA
$OldLocalAppData = $env:LOCALAPPDATA

$script:TailcatProcess  = $null
$script:EdgeProcess     = $null
$script:EdgeProcessStarts = @{}


function Invoke-Download {

    param ([string]$Uri, [string]$OutFile)

    $Request = @{
        Uri = $Uri; OutFile = $OutFile; UseBasicParsing = $true
        Headers = @{ "User-Agent" = "Tailcat-OneShot" }
        TimeoutSec = 120; ErrorAction = 'Stop'
    }
    # PowerShell 7.4+ separates connection and response-read timeouts.
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $Request.OperationTimeoutSeconds = 120
    }

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Invoke-WebRequest @Request
            return
        }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue

            $StatusCode = 0
            if ($_.Exception.Response) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }

            # Retry network failures and transient HTTP errors only.
            if ($Attempt -eq 3 -or (
                $StatusCode -ne 0 -and
                $StatusCode -notin @(408, 429, 500, 502, 503, 504)
            )) {
                throw "Download failed: $Uri`n$($_.Exception.Message)"
            }

            Write-Host "[WARN] Download attempt $Attempt/3 failed: $($_.Exception.Message)"
            Write-Host "Retrying in 2 seconds..."
            Start-Sleep -Seconds 2
        }
    }
}


function Get-Tailcat {

    Write-Host ""
    Write-Host "Downloading Tailcat $TailcatVersion..."

    $ArchiveName = "tailcat_$($TailcatVersion.TrimStart('v'))_windows_amd64.zip"
    $ZipFile = Join-Path $Root $ArchiveName
    $ChecksumsFile = Join-Path $Root "checksums.txt"

    $OldSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol

    try {

        # Windows PowerShell 5.1 on older Windows Server versions can
        # default to TLS versions that GitHub no longer accepts.

        [Net.ServicePointManager]::SecurityProtocol =
            $OldSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        Invoke-Download -Uri "$ReleaseBaseUrl/$ArchiveName" -OutFile $ZipFile
        Invoke-Download -Uri "$ReleaseBaseUrl/checksums.txt" -OutFile $ChecksumsFile
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $OldSecurityProtocol
    }

    $ChecksumPattern = '^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($ArchiveName) + '$'
    $ChecksumLine = Get-Content -LiteralPath $ChecksumsFile |
        Where-Object { $_ -match $ChecksumPattern } |
        Select-Object -First 1

    if (-not $ChecksumLine) {
        throw "SHA256 checksum for $ArchiveName was not found."
    }

    $ExpectedHash = ($ChecksumLine -split "\s+")[0].Trim().ToLowerInvariant()

    $ActualHash = (
        Get-FileHash -LiteralPath $ZipFile -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    if ($ExpectedHash -ne $ActualHash) {
        throw "Tailcat SHA256 verification failed."
    }

    Write-Host "SHA256 verified."

    $ExtractPath = Join-Path $Root "tailcat"

    New-Item `
        -ItemType Directory `
        -Path $ExtractPath `
        -Force |
        Out-Null

    Expand-Archive `
        -Path $ZipFile `
        -DestinationPath $ExtractPath `
        -Force

    Remove-Item -LiteralPath $ZipFile -Force -ErrorAction SilentlyContinue

    $Tailcat = Get-ChildItem `
        -Path $ExtractPath `
        -Filter "tailcat.exe" `
        -Recurse |
        Select-Object -First 1

    if (-not $Tailcat) {
        throw "tailcat.exe was not found in the downloaded archive."
    }

    return $Tailcat.FullName
}


function Show-Network {

    Write-Host ""
    Write-Host "Local network:"
    Write-Host ""

    $Configs = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object {
            $_.NetAdapter.Status -eq "Up" -and
            $_.IPv4Address
        }

    foreach ($Config in $Configs) {

        foreach ($Address in $Config.IPv4Address) {

            $IP = $Address.IPAddress

            if (
                $IP -eq "127.0.0.1" -or
                $IP -like "169.254.*"
            ) {
                continue
            }

            $Gateway = ""

            if ($Config.IPv4DefaultGateway) {
                $Gateway = $Config.IPv4DefaultGateway.NextHop
            }

            Write-Host ("Interface : {0}" -f $Config.InterfaceAlias)
            Write-Host ("Address   : {0}/{1}" -f $IP, $Address.PrefixLength)

            if ($Gateway) {
                Write-Host ("Gateway   : {0}" -f $Gateway)
            }

            Write-Host ""
        }
    }
}


function Show-RuntimeInfo {

    Write-Host ""
    Write-Host "Runtime information"
    Write-Host "-------------------"
    Write-Host "Tailcat version : $TailcatVersion"
    Write-Host "Temporary path  : $Root"
    Write-Host "APPDATA         : $env:APPDATA"
    Write-Host "LOCALAPPDATA    : $env:LOCALAPPDATA"

    Write-Host ""
    Write-Host "Tailcat-OneShot does NOT intentionally modify:"
    Write-Host "  - Windows services"
    Write-Host "  - Firewall rules"
    Write-Host "  - System proxy"
    Write-Host "  - Routing"
    Write-Host "  - VPN adapters"
    Write-Host "  - Scheduled tasks"
    Write-Host "  - Persistent environment variables"

    Write-Host ""
    Write-Host "Windows itself may still create normal OS traces such as"
    Write-Host "Event Log, Prefetch or Defender history."
}


function Get-FreeTcpPort {

    $Listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0
    )

    $Listener.Start()

    try {
        return ([System.Net.IPEndPoint]$Listener.LocalEndpoint).Port
    }
    finally {
        $Listener.Stop()
    }
}


function Assert-TailcatRunning {

    param ($Process, [string]$StderrFile)

    if (-not $Process.HasExited) {
        return
    }

    $Details = [string](Get-Content -LiteralPath $StderrFile -Raw -ErrorAction SilentlyContinue)
    $Message = "Tailcat SOCKS process exited unexpectedly (exit code $($Process.ExitCode))."

    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $Message += "`n$($Details.Trim())"
    }

    throw $Message
}


function Wait-ForSocks {

    param (
        $Process,
        [int]$Port,
        [string]$StderrFile
    )

    for ($i = 0; $i -lt 100; $i++) {

        Assert-TailcatRunning -Process $Process -StderrFile $StderrFile

        $Client = New-Object System.Net.Sockets.TcpClient
        $Async = $null

        try {

            $Async = $Client.BeginConnect(
                "127.0.0.1",
                $Port,
                $null,
                $null
            )

            if ($Async.AsyncWaitHandle.WaitOne(200)) {

                $Client.EndConnect($Async)
                return
            }
        }
        catch {
        }
        finally {
            $Client.Close()
            if ($Async) {
                $Async.AsyncWaitHandle.Close()
            }
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Tailcat SOCKS proxy did not start."
}


function Find-Edge {

    $Candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )

    foreach ($Candidate in $Candidates) {

        if (
            $Candidate -and
            (Test-Path $Candidate)
        ) {
            return $Candidate
        }
    }

    return $null
}


function Get-TemporaryEdgeProcesses {

    param (
        [switch]$IncludeBackgroundProcesses
    )

    # Track creation times as well as PIDs; Windows can reuse a departed PID.
    # Children may omit the profile path, so discover them through live parents.

    $EdgeProcesses = @(
        Get-CimInstance `
            Win32_Process `
            -Filter "Name='msedge.exe'" `
            -ErrorAction Stop
    )

    $CurrentProcesses = @{}
    foreach ($Process in $EdgeProcesses) {
        $CurrentProcesses[[int]$Process.ProcessId] = $Process
    }

    foreach ($ProcessId in @($script:EdgeProcessStarts.Keys)) {
        $Current = $CurrentProcesses[$ProcessId]
        if (-not $Current -or -not $Current.CreationDate -or
            $Current.CreationDate.ToUniversalTime().Ticks -ne $script:EdgeProcessStarts[$ProcessId]) {
            $script:EdgeProcessStarts.Remove($ProcessId)
        }
    }

    foreach ($Process in $EdgeProcesses) {

        if (
            $Process.CreationDate -and $Process.CommandLine -and
            $Process.CommandLine.IndexOf(
                $Root,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        ) {
            $script:EdgeProcessStarts[[int]$Process.ProcessId] = $Process.CreationDate.ToUniversalTime().Ticks
        }
    }

    do {
        $ProcessWasAdded = $false

        foreach ($Process in $EdgeProcesses) {

            if (
                $Process.CreationDate -and
                $script:EdgeProcessStarts.ContainsKey([int]$Process.ParentProcessId) -and
                -not $script:EdgeProcessStarts.ContainsKey([int]$Process.ProcessId) -and
                $Process.CreationDate.ToUniversalTime().Ticks -ge $script:EdgeProcessStarts[[int]$Process.ParentProcessId]
            ) {
                $script:EdgeProcessStarts[[int]$Process.ProcessId] = $Process.CreationDate.ToUniversalTime().Ticks
                $ProcessWasAdded = $true
            }
        }
    }
    while ($ProcessWasAdded)

    if ($IncludeBackgroundProcesses) {
        return @(
            $EdgeProcesses |
                Where-Object {
                    $script:EdgeProcessStarts.ContainsKey([int]$_.ProcessId)
                }
        )
    }

    return @(
        $EdgeProcesses |
            Where-Object {
                $script:EdgeProcessStarts.ContainsKey([int]$_.ProcessId) -and
                $_.CommandLine -and
                $_.CommandLine.IndexOf(
                    $EdgeProfile,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            }
    )
}


function Invoke-TailcatForeground {

    param ([string]$Binary, [string[]]$Arguments)

    $OldPreference = $ErrorActionPreference
    try {
        # Normal Tailcat status goes to stderr; PowerShell ISE must allow it.
        $ErrorActionPreference = "Continue"
        & $Binary @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Tailcat failed (exit code $LASTEXITCODE)."
        }
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }
}


function Read-TailcatToken {

    do {
        $Token = (Read-Host "Tailcat tc... token").Trim()
    }
    until ($Token.StartsWith("tc"))
    return $Token
}


function Run-Server {

    $Tailcat = Get-Tailcat

    Show-Network
    Show-RuntimeInfo

    Write-Host ""
    Write-Host "Starting Tailcat exit-node..."
    Write-Host ""
    Write-Host "Share the generated tc... token with the CLIENT."
    Write-Host "Press Ctrl+C to stop."
    Write-Host ""

    Invoke-TailcatForeground -Binary $Tailcat -Arguments @('--key=new', 'serve', 'exit-node')
}


function Run-Forward {

    $Token = Read-TailcatToken
    Write-Host ""
    Write-Host "Mapping: local-port:remote-IP:remote-port"
    Write-Host "Example: 13389:192.168.1.20:3389"
    Write-Host "Use local port 0 to choose a free port automatically."
    $Mapping = (Read-Host "Mapping").Trim()
    if ([string]::IsNullOrWhiteSpace($Mapping)) {
        throw "A port mapping is required."
    }

    $Tailcat = Get-Tailcat
    Show-RuntimeInfo
    Write-Host ""
    Write-Host "Starting TCP forwarding on localhost..."
    Write-Host "Tailcat will print the local endpoint when ready."
    Write-Host "Press Ctrl+C to disconnect and clean up."

    Invoke-TailcatForeground -Binary $Tailcat -Arguments @('--key=new', 'forward', $Token, $Mapping)
}


function Run-Client {

    Write-Host ""

    $Token = Read-TailcatToken

    $Tailcat = Get-Tailcat

    $SocksPort = Get-FreeTcpPort

    $TailcatStdout = Join-Path $Root "tailcat.stdout.log"
    $TailcatStderr = Join-Path $Root "tailcat.stderr.log"

    Show-RuntimeInfo

    Write-Host ""
    Write-Host "Starting Tailcat SOCKS proxy..."
    Write-Host "SOCKS endpoint : 127.0.0.1:$SocksPort"

    $script:TailcatProcess = Start-Process `
        -FilePath $Tailcat `
        -ArgumentList @(
            "--key=new",
            "socks",
            "--listen=$SocksPort",
            $Token
        ) `
        -RedirectStandardOutput $TailcatStdout `
        -RedirectStandardError $TailcatStderr `
        -PassThru `
        -WindowStyle Hidden

    $null = $script:TailcatProcess.Handle

    Wait-ForSocks `
        -Process $script:TailcatProcess `
        -Port $SocksPort `
        -StderrFile $TailcatStderr

    Write-Host "SOCKS ready."

    $Edge = Find-Edge

    if (-not $Edge) {
        Write-Host ""
        Write-Host "Microsoft Edge was not found."
        Write-Host "Continuing in manual SOCKS5 mode."
        Write-Host ""
        Write-Host "SOCKS5 host : 127.0.0.1"
        Write-Host "SOCKS5 port : $SocksPort"
        Write-Host ""
        Write-Host "Configure proxy DNS in the application when available."
        Write-Host "Press Ctrl+C to disconnect and clean up."
        Write-Host ""

        while (-not $script:TailcatProcess.HasExited) {
            Start-Sleep -Seconds 1
        }

        Assert-TailcatRunning -Process $script:TailcatProcess -StderrFile $TailcatStderr

        return
    }

    Open-TemporaryEdge -Edge $Edge -SocksPort $SocksPort

    while ($true) {
        Assert-TailcatRunning -Process $script:TailcatProcess -StderrFile $TailcatStderr

        if (-not @(Get-TemporaryEdgeProcesses)) {
            break
        }

        Start-Sleep -Milliseconds 500
    }
}


function Open-TemporaryEdge {

    param ([string]$Edge, [int]$SocksPort)

    Write-Host ""
    Write-Host "Target URL examples:"
    Write-Host "  https://192.168.1.10"
    Write-Host "  http://192.168.1.1"
    Write-Host ""
    Write-Host "Leave blank to open an empty Edge window."
    Write-Host ""

    $Url = (Read-Host "URL [optional]").Trim()

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $Url = "about:blank"
    }
    elseif (
        -not $Url.StartsWith("http://") -and
        -not $Url.StartsWith("https://")
    ) {
        throw "URL must start with http:// or https://."
    }

    New-Item `
        -ItemType Directory `
        -Path $EdgeProfile `
        -Force |
        Out-Null

    Write-Host ""
    Write-Host "Opening isolated Microsoft Edge..."
    Write-Host "Target : $Url"
    Write-Host ""
    Write-Host "Close the temporary Edge window to disconnect and clean up."
    Write-Host ""

    $script:EdgeProcess = Start-Process `
        -FilePath $Edge `
        -ArgumentList @(
            "`"--user-data-dir=$EdgeProfile`"",
            "`"--proxy-server=socks5://127.0.0.1:$SocksPort`"",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-features=HttpsUpgrades",
            "`"$Url`""
        ) `
        -PassThru

    # Win32_Process reports creation time with microsecond precision.
    $null = $script:EdgeProcess.Handle
    $Started = $script:EdgeProcess.StartTime.ToUniversalTime().Ticks
    $script:EdgeProcessStarts[[int]$script:EdgeProcess.Id] = $Started - ($Started % 10)
    Get-TemporaryEdgeProcesses | Out-Null
    Start-Sleep -Seconds 1
}


function Stop-EdgeProcess {

    param ($Snapshot)

    $Process = Get-Process -Id $Snapshot.ProcessId -ErrorAction SilentlyContinue
    if (-not $Process) {
        return
    }

    try {
        # Keep a handle to this process before checking its identity and killing it.
        # A PID lookup alone can target a replacement process between these steps.
        $null = $Process.Handle
        $Started = $Process.StartTime.ToUniversalTime().Ticks
        if (($Started - ($Started % 10)) -eq $Snapshot.CreationDate.ToUniversalTime().Ticks -and
            -not $Process.HasExited) {
            $Process.Kill()
        }
    }
    catch {
        if (-not $Process.HasExited) {
            throw
        }
    }
    finally {
        $Process.Dispose()
    }
}


function Stop-TemporaryEdge {

    if (-not $script:EdgeProcess) {
        Write-Host "[OK] No temporary Edge process to stop"
        return
    }

    $EmptyChecks = 0
    $StopError = ""
    for ($Attempt = 1; $Attempt -le 20; $Attempt++) {
        $Processes = @(Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses)
        if ($Processes.Count -eq 0) {
            $EmptyChecks++
            if ($EmptyChecks -ge 4) {
                Write-Host "[OK] Temporary Edge stopped and verified"
                return
            }
        }
        else {
            $EmptyChecks = 0
            foreach ($Snapshot in $Processes) {
                try {
                    Stop-EdgeProcess -Snapshot $Snapshot
                }
                catch {
                    $StopError = $_.Exception.Message
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }

    $Remaining = @(Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses)
    if ($Remaining.Count -gt 0) {
        throw "Temporary Edge processes remain: $(($Remaining.ProcessId) -join ', '). $StopError"
    }
    throw "Temporary Edge stop was not stable long enough to verify."
}


function Stop-Tailcat {

    if (-not $script:TailcatProcess) {
        Write-Host "[OK] No client Tailcat process to stop"
        return
    }

    if (-not $script:TailcatProcess.HasExited) {
        $script:TailcatProcess.Kill()
    }
    if (-not $script:TailcatProcess.WaitForExit(5000)) {
        throw "Tailcat process remains: $($script:TailcatProcess.Id)"
    }

    Write-Host "[OK] Tailcat stopped and verified"
}


function Restore-Environment {

    $env:APPDATA = $OldAppData
    $env:LOCALAPPDATA = $OldLocalAppData
    if ($env:APPDATA -ne $OldAppData -or $env:LOCALAPPDATA -ne $OldLocalAppData) {
        throw "Environment restoration could not be verified."
    }
    Write-Host "[OK] Environment restored and verified"
}


function Remove-RuntimeDirectory {

    param ([string]$Path, [string]$BaseDirectory)

    $FullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $FullBase = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\')
    $Parent = [System.IO.Path]::GetDirectoryName($FullPath)
    if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent.TrimEnd('\') -ne $FullBase -or
        [System.IO.Path]::GetFileName($FullPath) -cnotmatch '^tailcat-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected runtime path: $Path"
    }

    $RemoveError = ""
    for ($Attempt = 1; $Attempt -le 8; $Attempt++) {
        if (-not (Test-Path -LiteralPath $FullPath)) {
            Write-Host "[OK] Runtime directory removed and verified"
            return
        }

        try {
            $Directory = Get-Item -LiteralPath $FullPath -Force -ErrorAction Stop
            if ($Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to remove a redirected runtime directory: $FullPath"
            }
            Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $RemoveError = $_.Exception.Message
        }
        if (Test-Path -LiteralPath $FullPath) {
            Start-Sleep -Milliseconds 250
        }
    }

    if (Test-Path -LiteralPath $FullPath) {
        throw "Runtime directory remains: $FullPath. $RemoveError"
    }
    Write-Host "[OK] Runtime directory removed and verified"
}


function Cleanup {

    Write-Host ""
    Write-Host "Cleaning up..."

    # Each step must still run if an earlier one fails.
    foreach ($Step in @(
        { Stop-TemporaryEdge },
        { Stop-Tailcat },
        { Restore-Environment },
        { if ($RuntimeCreated) { Remove-RuntimeDirectory -Path $Root -BaseDirectory $TempBase } }
    )) {
        try {
            & $Step
        }
        catch {
            $script:ExitCode = 1
            Write-Host "[WARN] $($_.Exception.Message)"
        }
    }

    if ($script:EdgeProcess) { $script:EdgeProcess.Dispose() }
    if ($script:TailcatProcess) { $script:TailcatProcess.Dispose() }
    $script:EdgeProcessStarts.Clear()
}


try {

    New-Item `
        -ItemType Directory `
        -Path $Root `
        -Force |
        Out-Null

    $RuntimeCreated = $true

    $env:APPDATA      = Join-Path $Root "AppData"
    $env:LOCALAPPDATA = Join-Path $Root "LocalAppData"

    New-Item `
        -ItemType Directory `
        -Path $env:APPDATA `
        -Force |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Path $env:LOCALAPPDATA `
        -Force |
        Out-Null

    Clear-Host

    Write-Host "Tailcat-OneShot"
    Write-Host "==============="
    Write-Host ""
    Write-Host "Temporary Windows helper for Tailcat."
    Write-Host ""
    Write-Host "[1] SERVER"
    Write-Host "    Expose this PC/network as Tailcat exit-node"
    Write-Host ""
    Write-Host "[2] CLIENT"
    Write-Host "    Connect to exit-node and open temporary Edge when available"
    Write-Host ""
    Write-Host "[3] FORWARD"
    Write-Host "    Forward a local TCP port to a service on the remote network"
    Write-Host ""
    Write-Host "[Q] Quit"
    Write-Host ""

    $Choice = (Read-Host "Select").Trim().ToUpperInvariant()

    switch ($Choice) {

        "1" {
            Run-Server
        }

        "2" {
            Run-Client
        }

        "3" {
            Run-Forward
        }

        "Q" {
            # Continue through cleanup and the final exit code.
        }

        default {
            throw "Invalid selection."
        }
    }
}
catch {

    $script:ExitCode = 1
    Write-Host ""
    Write-Host "ERROR:"
    Write-Host $_.Exception.Message
}
finally {

    Cleanup
}

exit $script:ExitCode
