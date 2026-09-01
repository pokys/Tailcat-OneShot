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
* PowerShell
* Internet access
* Microsoft Edge is optional on the client

### Linux

* Linux on `amd64`, `arm64` or `armv7`
* Bash
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

The Linux script has only two operating modes:

```text
[1] SERVER
    Expose this machine/network as a Tailcat exit-node

[2] CLIENT
    Start a local SOCKS5 proxy for manual configuration
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
* a manual SOCKS5 client is stopped with `Ctrl+C`,
* Tailcat exits with an error,
* either script encounters a normal error.

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
Tailcat v0.4.0
```

The version is **intentionally pinned**.

Tailcat is a young project and currently does not guarantee stability of its CLI, API or wire format. Automatically switching to a newer release could therefore break Tailcat-OneShot unexpectedly.

New Tailcat versions should be tested before updating the pinned version.

## Security

Tailcat provides end-to-end encrypted connectivity using the Tailscale data plane without requiring the normal Tailscale control plane.

Tailcat-OneShot does not save the generated server or client key.

Both the server and client are explicitly started with:

```text
--key=new
```

which creates new ephemeral identities for each session.

Treat the generated `tc...` token as a temporary access credential. Anyone who has a valid token may be able to connect while that Tailcat session is active.

Do not publish or otherwise expose an active token.

## Limitations

Tailcat-OneShot is primarily intended for accessing **TCP services** on the remote network through SOCKS5.

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

## License

Tailcat-OneShot is released under the MIT License.

See `LICENSE` for details.
