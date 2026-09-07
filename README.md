# Tailcat-OneShot
<img width="532" height="367" alt="image" src="https://github.com/user-attachments/assets/5118c343-e5dd-48d2-a9f7-0384764491e2" />

A small, temporary Windows and Linux helper for [Tailcat](https://github.com/tailscale/tailcat).

Tailcat-OneShot makes it easy to create a **one-shot encrypted connection to a remote machine and its local network** without installing a VPN client, changing system routing, or configuring firewall rules.

It is intended primarily as a lightweight **remote service / troubleshooting tool**.

## How it works

On the remote Windows or Linux machine:

```text
Tailcat_OneShot.ps1 / Tailcat_OneShot.sh
        │
        └── Tailcat exit-node
                  │
                  └── tc... token
```

On the client:

```text
Tailcat_OneShot.ps1 / Tailcat_OneShot.sh
        │
        └── local SOCKS5 proxy
                    │
                    └── remote LAN
```

The server generates a temporary `tc...` token.

Enter that token on the client and Tailcat-OneShot starts a local SOCKS5 proxy. The Windows script opens an isolated Microsoft Edge instance when Edge is available. The Linux script prints the proxy settings for manual configuration.

You can then access TCP-based web interfaces on the remote network, for example:

```text
https://192.168.1.10    ESXi
https://192.168.1.20    Proxmox
https://192.168.1.30    iDRAC / iLO
http://192.168.1.1      Router
https://192.168.1.40    NAS
```

## Requirements

### Windows

* Windows
* Windows PowerShell 5.1 or PowerShell 7
* Internet access
* Microsoft Edge is optional on the client

### Linux

* Linux on `amd64`, `arm64` or `armv7`
* POSIX-compatible `/bin/sh`
* `curl`, `tar`, `sha256sum`, `awk`, `mktemp` and `uname`
* Internet access

Administrator or root privileges are normally not required.

## Windows usage

Download:

```text
Tailcat_OneShot.ps1
```

Run it from PowerShell:

```powershell
.\Tailcat_OneShot.ps1
```

You will see:

```text
Tailcat-OneShot
===============

[1] SERVER
    Expose this PC/network as Tailcat exit-node

[2] CLIENT
    Connect to exit-node and open temporary Edge when available

[3] FORWARD
    Forward a local TCP port to a service on the remote network

[Q] Quit
```

### SERVER

Choose:

```text
1
```

Tailcat-OneShot downloads the tested Tailcat release, verifies its SHA256 checksum and starts:

```text
Tailcat exit-node
```

A temporary `tc...` token will be displayed.

Send that token to the client.

The server uses:

```text
--key=new
```

so a new ephemeral Tailcat identity is generated for every session.

Stopping the server invalidates that session.

### CLIENT

Choose:

```text
2
```

Enter the `tc...` token from the server.

If Microsoft Edge is available, optionally enter the URL you want to open:

```text
https://192.168.1.10
```

If the URL is left blank, Edge opens:

```text
about:blank
```

Tailcat-OneShot then:

1. starts a Tailcat SOCKS proxy with a new ephemeral client identity on a random localhost port,
2. if Edge is available, creates a temporary profile and opens an isolated Edge instance using that SOCKS proxy,
3. if Edge is not available, prints the SOCKS5 host and port for manual configuration,
4. waits until the temporary Edge window is closed or the manual mode is stopped with `Ctrl+C`,
5. stops the complete temporary Edge process tree when applicable and stops Tailcat,
6. removes the temporary runtime directory.

Closing the isolated Edge window disconnects the client automatically. Without Edge, press `Ctrl+C` to disconnect and clean up.

### PuTTY through the SOCKS5 proxy

The same temporary SOCKS5 proxy can also be used manually by PuTTY to reach
SSH servers in the remote LAN.

Keep the Windows client running. If it opened a temporary Edge window, keep
that window open as well. Configure PuTTY as follows:

```text
Session -> Host Name : IP address or DNS name in the remote LAN
Session -> Port      : 22

Connection -> Proxy -> Proxy type     : SOCKS 5
Connection -> Proxy -> Proxy hostname : 127.0.0.1
Connection -> Proxy -> Port           : the port shown as SOCKS endpoint
```

For example, if Tailcat-OneShot prints:

```text
SOCKS endpoint : 127.0.0.1:49152
```

use `127.0.0.1` and port `49152` as the PuTTY proxy, while the PuTTY session
itself points to the desired SSH host in the remote LAN.

SSH authentication remains between PuTTY and the destination SSH server.
Closing the temporary Edge window or stopping the client with `Ctrl+C` stops
the Tailcat SOCKS proxy and therefore also terminates connections using it.

PuTTY may save its normal settings and SSH host keys. Those belong to PuTTY
and are not removed by Tailcat-OneShot cleanup.

## Linux usage

Download `Tailcat_OneShot.sh`, make it executable and run it as a normal user:

```bash
chmod +x Tailcat_OneShot.sh
./Tailcat_OneShot.sh
```

Or run it directly with the system shell:

```sh
sh Tailcat_OneShot.sh
```

The Linux script has three operating modes:

```text
[1] SERVER
    Expose this machine/network as a Tailcat exit-node

[2] CLIENT
    Start a local SOCKS5 proxy for manual configuration

[3] FORWARD
    Forward a local TCP port to a service on the remote network
```

The server prints a temporary `tc...` token. On the client, enter that token
and accept the default SOCKS5 port `1080` or choose another local port.

The client then prints settings such as:

```text
SOCKS5 host : 127.0.0.1
SOCKS5 port : 1080
Proxy DNS   : enable it in the application when available
```

Enter those settings manually in Firefox, PuTTY or another SOCKS5-capable
application. For Firefox, select SOCKS v5 and enable **Proxy DNS when using
SOCKS v5**. Keep the script running and press `Ctrl+C` when finished.

The Linux script does not detect, configure or launch a browser. It does not
install missing commands or packages.

### Optional QR code in the Linux console

In SERVER mode, the script offers to display the token as a QR code when
`qrencode` is available. Press `y` to use it, or Enter to keep text only.
If the command is missing, the script prints an installation hint and continues.

Install it separately, using your distribution's package manager as administrator:

| Distribution | Command |
| --- | --- |
| Debian / Ubuntu | `apt install qrencode` |
| Alpine Linux | `apk add libqrencode-tools` |

QR generation runs locally and displays directly in the text console, including
a VM console in ESXi or PVE. It needs UTF-8, a font with block characters and
enough space to show the complete code; 80 columns by 40 rows is recommended
for the usual token. A longer token may require more space. Read the QR with
a phone or an offline QR reader on a screenshot of the console.

When QR is selected, Tailcat writes the token to `tc.txt` inside the session's
temporary directory. The script waits for about 30 seconds for a complete address
and displays the QR once. A QR rendering error or timeout does not stop the
server, and the text token remains available. The token file is removed with
the session directory during normal cleanup. The installed `qrencode` package
remains installed.

## TCP forwarding (Windows and Linux)

For applications such as an RDP or database client, choose **[1] SERVER** on the
remote machine and **[3] FORWARD** on the client. Enter the server's `tc...` token
and one mapping in this format:

```text
local-port:remote-IP:remote-port
```

For example, `13389:192.168.1.20:3389` makes `127.0.0.1:13389` on the client
reach `192.168.1.20:3389` on the remote network. Point the RDP client at
`127.0.0.1:13389`. IPv6 targets use brackets, for example `15432:[fd00::20]:5432`.

Use local port `0` to let Tailcat choose a free port; it prints the local
endpoint when ready. Tailcat validates the mapping and reports invalid or
occupied ports. Listeners use localhost, and forwarding carries TCP only.

Keep the script running and press `Ctrl+C` to disconnect and clean up. This
mode opens no browser and saves no mappings or profiles.

## No installation

Tailcat-OneShot does not install Tailcat on either platform.

The Tailcat binary and all runtime files are downloaded into a randomly generated directory under:

```text
# Windows
%TEMP%\tailcat-...

# Linux
${TMPDIR:-/tmp}/tailcat-oneshot.XXXXXXXX
```

The directory is removed during normal cleanup.

Both scripts download the pinned release directly, use download timeouts and
allow at most two retries for transient download failures. Archives are extracted
only after SHA256 verification. Failed downloads are cleaned up with the session;
there is no persistent download cache.

Linux allows 15 seconds to connect and 120 seconds per download attempt. Windows
sets the web request timeout to 120 seconds and, when supported by PowerShell,
also sets the separate response-read timeout to 120 seconds.

## What it does NOT intentionally change

Tailcat-OneShot does not intentionally modify:

* installed packages
* system services
* firewall rules
* system proxy settings
* system routing or network interfaces
* startup configuration or scheduled tasks
* persistent environment variables

On Windows, the SOCKS proxy is configured automatically only for the temporary
Edge process. Other applications can opt in by using the displayed localhost
SOCKS5 endpoint, as in the PuTTY example above. On Linux, configuration is
always manual.

On Windows, Edge uses a temporary:

```text
--user-data-dir
```

which is removed after the session.

Windows itself may still create normal operating-system traces such as Event Log entries, Prefetch data or Microsoft Defender history.

On Linux, Tailcat receives temporary `HOME`, `TMPDIR` and `XDG_*` directories
inside the runtime directory. Applications configured manually by the user may
still save their own settings, history or host keys outside that directory.

## Cleanup

Cleanup runs when:

* the server is stopped normally,
* the temporary Edge window is closed,
* a manual SOCKS5 or TCP forwarding client is stopped with `Ctrl+C`,
* Tailcat exits with an error,
* either script encounters a normal error.

Cleanup attempts each step even if another step fails. It verifies process
termination and directory removal, and reports anything it could not clean up.
Runtime directory removal is restricted to the generated directory under the
original temporary location. Windows tracks temporary Edge processes by both
PID and creation time, and checks their identity again before stopping them.

Windows returns exit code `0` on normal completion (including Quit), or `1` on
an error or incomplete cleanup. Linux preserves Tailcat's exit status and uses
the usual signal exit codes, such as `130` for `Ctrl+C`. Failed Linux cleanup
changes an otherwise successful exit to `1`.

A forced process kill, system crash, power loss or reboot can prevent cleanup from running.

In that case a temporary directory may remain under:

```text
# Windows
%TEMP%\tailcat-...

# Linux
${TMPDIR:-/tmp}/tailcat-oneshot.XXXXXXXX
```

It can be safely removed manually when Tailcat-OneShot is no longer running.

## Tailcat version

Tailcat-OneShot currently uses:

```text
Tailcat v0.6.0
```

The version is **intentionally pinned**.

Tailcat is a young project and currently does not guarantee stability of its CLI, API or wire format. Automatically switching to a newer release could therefore break Tailcat-OneShot unexpectedly.

New Tailcat versions should be tested before updating the pinned version.

Use the updated wrapper on both the server and client. Tailcat v0.6.0 includes
a WireGuard pre-shared key (PSK) in newly generated addresses by default;
clients v0.5.0 and earlier cannot connect to those addresses. Tailcat-OneShot
keeps PSK enabled and continues to generate fresh identities with `--key=new`.

## Security

Tailcat provides end-to-end encrypted connectivity using the Tailscale data plane without requiring the normal Tailscale control plane.

Tailcat-OneShot does not save the generated WireGuard private keys.

Both the server and client are explicitly started with:

```text
--key=new
```

which creates new ephemeral identities for each session.

Treat the generated `tc...` token as a temporary access credential. Anyone who has a valid token may be able to connect while that Tailcat session is active.

The token is Tailcat's connection address and now also contains the secret PSK.
It remains valid only for that running session.

Do not publish or otherwise expose an active token.

## Limitations

Tailcat-OneShot is primarily intended for accessing **TCP services** on the remote network through SOCKS5.

Tailcat v0.6.0 also supports UDP through SOCKS5 UDP ASSOCIATE. This requires
support in the application using the proxy; it does not automatically enable
UDP for every application.

It is not a full system VPN replacement.

For example, `ping`/ICMP does not travel through the SOCKS proxy.

## Why?

Sometimes installing and configuring a full VPN or remote-access agent is unnecessary.

The intended workflow is:

```text
run script
    ↓
get token
    ↓
connect
    ↓
service remote network
    ↓
close Edge / press Ctrl+C / stop server
    ↓
cleanup
```

No installer, no permanent service and no intentionally persistent configuration.

## Upstream project

Tailcat is developed by Tailscale:

https://github.com/tailscale/tailcat

Tailcat-OneShot is an independent helper script and is **not an official Tailscale project**.

Tailcat itself is distributed under the BSD 3-Clause License.

## Development checks

The offline regression tests cover errors, process ownership, cleanup and
downloads. They use temporary fixtures and do not start a real Tailcat connection.
They are not needed to run either helper.

On Windows, with Pester 5 installed:

```powershell
Invoke-Pester ./tests/Windows.Tests.ps1
```

On Linux:

```sh
sh tests/Linux.Tests.sh
```

Run the Windows checks in both Windows PowerShell 5.1 and PowerShell 7 when
changing Windows behavior. Git Bash can run the shell checks as a preliminary
check, but does not replace testing on Linux; the symlink check is skipped on
hosts that emulate links by copying files.

## License

Tailcat-OneShot is released under the MIT License.

See `LICENSE` for details.
