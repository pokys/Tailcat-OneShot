# Tailcat-OneShot
# One-shot Windows helper for Tailcat.
#
# https://github.com/tailscale/tailcat
#
# Tailcat version is intentionally pinned because upstream currently
# does not guarantee CLI/API/wire-format stability.

$ErrorActionPreference = "Stop"

$TailcatVersion   = "v0.4.0"
$GitHubReleaseUrl = "https://api.github.com/repos/tailscale/tailcat/releases/tags/$TailcatVersion"

$Root        = Join-Path $env:TEMP ("tailcat-" + [guid]::NewGuid().ToString("N"))
$EdgeProfile = Join-Path $Root "EdgeProfile"

$OldAppData      = $env:APPDATA
$OldLocalAppData = $env:LOCALAPPDATA

$script:TailcatProcess  = $null
$script:EdgeProcess     = $null
$script:EdgeProcessIds  = @()


function Get-Tailcat {

    Write-Host ""
    Write-Host "Downloading Tailcat $TailcatVersion..."

    $Release = Invoke-RestMethod `
        -Uri $GitHubReleaseUrl `
        -Headers @{ "User-Agent" = "Tailcat-OneShot" }

    $Asset = $Release.assets |
        Where-Object {
            $_.name -match "windows_amd64.*\.zip$" -or
            $_.name -match "windows-amd64.*\.zip$"
        } |
        Select-Object -First 1

    if (-not $Asset) {
        throw "Windows AMD64 Tailcat release asset was not found."
    }

    $ChecksumsAsset = $Release.assets |
        Where-Object { $_.name -eq "checksums.txt" } |
        Select-Object -First 1

    if (-not $ChecksumsAsset) {
        throw "checksums.txt was not found in the Tailcat release."
    }

    $ZipFile       = Join-Path $Root $Asset.name
    $ChecksumsFile = Join-Path $Root "checksums.txt"

    Invoke-WebRequest `
        -Uri $Asset.browser_download_url `
        -OutFile $ZipFile `
        -UseBasicParsing

    Invoke-WebRequest `
        -Uri $ChecksumsAsset.browser_download_url `
        -OutFile $ChecksumsFile `
        -UseBasicParsing

    $ChecksumLine = Get-Content $ChecksumsFile |
        Where-Object { $_ -match [regex]::Escape($Asset.name) } |
        Select-Object -First 1

    if (-not $ChecksumLine) {
        throw "SHA256 checksum for $($Asset.name) was not found."
    }

    $ExpectedHash = ($ChecksumLine -split "\s+")[0].Trim().ToLowerInvariant()

    $ActualHash = (
        Get-FileHash $ZipFile -Algorithm SHA256
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

    Remove-Item $ZipFile -Force -ErrorAction SilentlyContinue

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


function Wait-ForSocks {

    param (
        [int]$Port,
        [string]$StderrFile
    )

    for ($i = 0; $i -lt 100; $i++) {

        if ($script:TailcatProcess.HasExited) {

            $Details = ""

            if (Test-Path $StderrFile) {
                $Details = (
                    Get-Content `
                        $StderrFile `
                        -Raw `
                        -ErrorAction SilentlyContinue
                ).Trim()
            }

            if ([string]::IsNullOrWhiteSpace($Details)) {
                throw "Tailcat SOCKS process exited unexpectedly."
            }
            else {
                throw "Tailcat SOCKS failed:`n$Details"
            }
        }

        $Client = New-Object System.Net.Sockets.TcpClient

        try {

            $Async = $Client.BeginConnect(
                "127.0.0.1",
                $Port,
                $null,
                $null
            )

            if ($Async.AsyncWaitHandle.WaitOne(200)) {

                $Client.EndConnect($Async)
                $Client.Close()

                return
            }
        }
        catch {
        }
        finally {
            $Client.Close()
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

    throw "Microsoft Edge was not found."
}


function Get-TemporaryEdgeProcesses {

    param (
        [switch]$IncludeBackgroundProcesses
    )

    # Some Edge children omit both --user-data-dir and the redirected
    # LOCALAPPDATA path from their command line. Keep the process tree rooted
    # at the PID returned by Start-Process so cleanup can still identify them.

    $EdgeProcesses = @(
        Get-CimInstance `
            Win32_Process `
            -Filter "Name='msedge.exe'" `
            -ErrorAction Stop
    )

    foreach ($Process in $EdgeProcesses) {

        if (
            $Process.CommandLine -and
            $Process.CommandLine.IndexOf(
                $Root,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0 -and
            $script:EdgeProcessIds -notcontains [int]$Process.ProcessId
        ) {
            $script:EdgeProcessIds += [int]$Process.ProcessId
        }
    }

    do {
        $ProcessWasAdded = $false

        foreach ($Process in $EdgeProcesses) {

            if (
                $script:EdgeProcessIds -contains [int]$Process.ParentProcessId -and
                $script:EdgeProcessIds -notcontains [int]$Process.ProcessId
            ) {
                $script:EdgeProcessIds += [int]$Process.ProcessId
                $ProcessWasAdded = $true
            }
        }
    }
    while ($ProcessWasAdded)

    if ($IncludeBackgroundProcesses) {
        return @(
            $EdgeProcesses |
                Where-Object {
                    $script:EdgeProcessIds -contains [int]$_.ProcessId
                }
        )
    }

    return @(
        $EdgeProcesses |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine.IndexOf(
                    $EdgeProfile,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            }
    )
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

    $OldPreference = $ErrorActionPreference

    try {

        # Tailcat v0.4.0 writes normal status information to stderr.
        # Do not let PowerShell ISE treat that as a terminating error.

        $ErrorActionPreference = "Continue"

        & $Tailcat --key=new serve exit-node
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }
}


function Run-Client {

    Write-Host ""

    do {
        $Token = (Read-Host "Tailcat tc... token").Trim()
    }
    until ($Token.StartsWith("tc"))

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

    Wait-ForSocks `
        -Port $SocksPort `
        -StderrFile $TailcatStderr

    Write-Host "SOCKS ready."

    $Edge = $null

    try {
        $Edge = Find-Edge
    }
    catch {
    }

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

        Wait-ForSocks `
            -Port $SocksPort `
            -StderrFile $TailcatStderr

        return
    }

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

    $script:EdgeProcessIds += [int]$script:EdgeProcess.Id

    Start-Sleep -Seconds 1

    while ($true) {

        if ($script:TailcatProcess.HasExited) {

            $Details = ""

            if (Test-Path $TailcatStderr) {
                $Details = (
                    Get-Content `
                        $TailcatStderr `
                        -Raw `
                        -ErrorAction SilentlyContinue
                ).Trim()
            }

            if ([string]::IsNullOrWhiteSpace($Details)) {
                throw "Tailcat SOCKS process exited unexpectedly."
            }
            else {
                throw "Tailcat SOCKS failed:`n$Details"
            }
        }

        $EdgeProcesses = @(Get-TemporaryEdgeProcesses)

        if (-not $EdgeProcesses) {
            break
        }

        Start-Sleep -Milliseconds 500
    }
}


function Cleanup {

    Write-Host ""
    Write-Host "Cleaning up..."

    try {

        $EdgeStopped = $false
        $RemainingEdgeProcessIds = @()
        $EmptyEdgeChecks = 0

        for ($Attempt = 1; $Attempt -le 20; $Attempt++) {

            $EdgeProcesses = @(
                Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses
            )

            if ($EdgeProcesses.Count -eq 0) {
                $RemainingEdgeProcessIds = @()
                $EmptyEdgeChecks++

                if ($EmptyEdgeChecks -ge 4) {
                    $EdgeStopped = $true
                    break
                }
            }
            else {
                $EmptyEdgeChecks = 0

                $RemainingEdgeProcessIds = @(
                    $EdgeProcesses | ForEach-Object { $_.ProcessId }
                )

                foreach ($Process in $EdgeProcesses) {
                    Stop-Process `
                        -Id $Process.ProcessId `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }

            Start-Sleep -Milliseconds 250
        }

        if (-not $EdgeStopped) {
            $EdgeProcesses = @(
                Get-TemporaryEdgeProcesses -IncludeBackgroundProcesses
            )

            if ($EdgeProcesses.Count -eq 0) {
                $RemainingEdgeProcessIds = @()
                $EmptyEdgeChecks++
            }
            else {
                $EmptyEdgeChecks = 0
                $RemainingEdgeProcessIds = @(
                    $EdgeProcesses | ForEach-Object { $_.ProcessId }
                )
            }

            $EdgeStopped = ($EmptyEdgeChecks -ge 4)
        }

        if ($EdgeStopped) {
            Write-Host "[OK] Temporary Edge stopped and verified"
        }
        elseif ($RemainingEdgeProcessIds.Count -eq 0) {
            Write-Host "[WARN] Temporary Edge stop was not stable long enough"
        }
        else {
            Write-Host (
                "[WARN] Temporary Edge processes remain: {0}" -f
                ($RemainingEdgeProcessIds -join ", ")
            )
        }
    }
    catch {
        Write-Host (
            "[WARN] Could not verify temporary Edge cleanup: {0}" -f
            $_.Exception.Message
        )
    }

    if ($script:TailcatProcess) {
        try {

            if (-not $script:TailcatProcess.HasExited) {
                Stop-Process `
                    -Id $script:TailcatProcess.Id `
                    -Force `
                    -ErrorAction Stop
            }

            $TailcatStopped = $script:TailcatProcess.WaitForExit(5000)

            if ($TailcatStopped -and $script:TailcatProcess.HasExited) {
                Write-Host "[OK] Tailcat stopped and verified"
            }
            else {
                Write-Host (
                    "[WARN] Tailcat process remains: {0}" -f
                    $script:TailcatProcess.Id
                )
            }
        }
        catch {
            Write-Host (
                "[WARN] Could not verify Tailcat cleanup: {0}" -f
                $_.Exception.Message
            )
        }
    }
    else {
        Write-Host "[OK] No client Tailcat process to stop"
    }

    try {
        $env:APPDATA      = $OldAppData
        $env:LOCALAPPDATA = $OldLocalAppData

        if (
            $env:APPDATA -eq $OldAppData -and
            $env:LOCALAPPDATA -eq $OldLocalAppData
        ) {
            Write-Host "[OK] Environment restored and verified"
        }
        else {
            Write-Host "[WARN] Environment restoration could not be verified"
        }
    }
    catch {
        Write-Host (
            "[WARN] Could not restore environment: {0}" -f
            $_.Exception.Message
        )
    }

    $RemoveError = ""

    for ($Attempt = 1; $Attempt -le 8; $Attempt++) {

        if (-not (Test-Path $Root)) {
            break
        }

        try {
            Remove-Item `
                $Root `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        catch {
            $RemoveError = $_.Exception.Message
        }

        if (Test-Path $Root) {
            Start-Sleep -Milliseconds 250
        }
    }

    if (Test-Path $Root) {
        Write-Host "[WARN] Runtime directory remains: $Root"

        if (-not [string]::IsNullOrWhiteSpace($RemoveError)) {
            Write-Host "[WARN] Last removal error: $RemoveError"
        }
    }
    else {
        Write-Host "[OK] Runtime directory removed and verified"
    }
}


try {

    New-Item `
        -ItemType Directory `
        -Path $Root `
        -Force |
        Out-Null

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

        "Q" {
            return
        }

        default {
            throw "Invalid selection."
        }
    }
}
catch {

    Write-Host ""
    Write-Host "ERROR:"
    Write-Host $_.Exception.Message
}
finally {

    Cleanup
}
