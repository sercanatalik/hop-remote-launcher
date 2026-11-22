<p align="center">
  <img src="icon/AppIcon.png" width="128" height="128" alt="Hop app icon">
</p>

<h1 align="center">Hop</h1>

<p align="center">A tiny macOS menu-bar launcher for your remote Macs.<br>
One click to Screen Share, SSH or open files, with Macs on your Tailscale network found automatically.</p>

---

## What it does

Click the Hop icon in the menu bar. You'll see every Mac you use with a live status dot: 🟢 online, ⚫️ offline, ⚪️ checking. Each Mac has these options:

- **Screen Share**: opens macOS's built-in Screen Sharing (`vnc://`)
- **SSH in Terminal**: `ssh://`
- **Open Shared Files**: connects in Finder (`smb://`)
- **Wake**: sends a Wake-on-LAN packet, when you've set a MAC address
- **Copy Address**

Macs live in two groups:

- **My Macs** are the ones you add yourself, by Bonjour name, IP address or Tailscale name.
- **Tailscale** lists every Mac on your tailnet automatically, with live online status. Hop reads it from the Tailscale app already on your Mac, so no API key is needed. Choose **Add to My Macs** on any of them to rename it or set a user name.

Hop is a single Swift file with no dependencies, no account and no telemetry. Your list stays in `~/Library/Application Support/Hop/hosts.json`.

## Install

### Download

Get `Hop.zip` from the [latest release](https://github.com/sercanatalik/hop-remote-launcher/releases/latest), unzip it, and move **Hop.app** to Applications.

Hop isn't notarised by Apple yet, so macOS will block it the first time. Try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run this:

```bash
xattr -dr com.apple.quarantine /Applications/Hop.app
```

### Build from source

You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). Then run:

```bash
git clone https://github.com/sercanatalik/hop-remote-launcher.git
cd hop-remote-launcher
./build.sh --install
```

`UNIVERSAL=1 ./build.sh` builds one app for both Apple silicon and Intel.

## Set up your remote Macs

On each remote Mac, open **System Settings → General → Sharing** and turn on:

| Feature in Hop | Turn on |
| --- | --- |
| Screen Share | **Screen Sharing** |
| SSH in Terminal | **Remote Login** |
| Open Shared Files | **File Sharing** |

**Away from home:** install [Tailscale](https://tailscale.com) on every Mac, and they show up in Hop wherever you are, with no port forwarding.

**Wake-on-LAN** only works on the same local network. It also needs "Wake for network access" turned on in the remote Mac's Battery or Energy settings, and MacBooks usually only wake this way when plugged in.

The first time Hop starts, macOS may ask for **Local Network** access. Allow it, or every status dot stays ⚫️.

## Contributing

Issues and pull requests are welcome. Use **Report an Issue…** in the Hop menu, or [open one here](https://github.com/sercanatalik/hop-remote-launcher/issues/new).

Hop is deliberately small: one Swift file (`Hop.swift`) and a build script, with no Xcode project. Every push is built on a real Mac by GitHub Actions. To publish a release, push a tag like `v1.0.0`, and the workflow attaches a universal `Hop.zip`.

## License

[MIT](LICENSE) © 2026 Sercan Atalik
