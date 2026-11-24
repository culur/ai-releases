# 🚀 ai-releases

📦 Release binaries for culur-ai.

`ai` wraps code agent CLIs (Claude Code, Codex, Antigravity) and shells in long-lived terminal sessions, served to a web app by a local daemon.

| Platform                             | Tray                          | Also needed |
| :----------------------------------- | :---------------------------- | :---------- |
| 🪟 Windows x64 (ARM64 via emulation) | System tray                   | —           |
| 🍎 macOS 12+ (Intel, Apple silicon)  | Menu bar (new, partly tested) | `tmux`      |
| 🐧 Linux x86-64, ARM64               | None, headless daemon         | `tmux`      |

> [!WARNING]
> Running `ai` is no different from opening an SSH channel into your machine. Any approved web client can run any command as your user. Protect it as you protect your SSH keys; see [Security](#-security).

## 📥 Install

The install scripts check the archive's SHA256 against `checksums.txt`, and its cosign signature when [cosign](https://github.com/sigstore/cosign/releases) v2.4+ is on `PATH`. No admin or root rights needed.

🪟 Windows (PowerShell), installs to `%LOCALAPPDATA%\Programs\culur-ai`:

```powershell
irm https://raw.githubusercontent.com/culur/ai-releases/main/install.ps1 | iex
```

🍎 macOS and 🐧 Linux, installs to `~/.local/share/culur-ai`:

```bash
curl -fsSL https://raw.githubusercontent.com/culur/ai-releases/main/install.sh | sh
```

🎯 The script lists the releases built for your machine, stable and beta, and lets you pick one: **Up/Down** or a number, **Enter** to install, **Esc**/**q** to cancel. It also shows the version already installed. Without a terminal (CI), it installs the newest stable release.

| Variable              | Effect                                                     |
| :-------------------- | :--------------------------------------------------------- |
| `AI_INSTALL_VERSION`  | Install this version without the menu, e.g. `0.1.0-beta.1` |
| `AI_INSTALL_DIR`      | Install somewhere else                                     |
| `AI_RELEASE_BASE_URL` | Install from a local folder of archives (testing builds)   |

### 📁 Files and PATH

| Item         | Windows                                            | macOS                                            |
| :----------- | :------------------------------------------------- | :----------------------------------------------- |
| ⚙️ Binary    | `%LOCALAPPDATA%\Programs\culur-ai\bin\ai.exe`      | `~/.local/share/culur-ai/bin/ai`                 |
| 🛠️ Config    | `%USERPROFILE%\.config\culur-ai`                   | `~/.config/culur-ai`                             |
| 🔁 Autostart | `HKCU\...\CurrentVersion\Run`, value `CulurAITray` | `~/Library/LaunchAgents/com.culur.ai.tray.plist` |
| 📜 Logs      | `ai logs`                                          | `~/Library/Logs/culur-ai/tray/backend.log`       |

Linux uses the same paths as macOS for the binary and config. `AI_INSTALL_DIR` changes the install folder.

The script does **not** add `bin` to `PATH`; it prints the command when it is missing. Run it once, then open a new terminal and check with `ai --version`.

```powershell
[Environment]::SetEnvironmentVariable('Path', "$env:LOCALAPPDATA\Programs\culur-ai\bin;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')
```

```zsh
echo 'export PATH="$HOME/.local/share/culur-ai/bin:$PATH"' >> ~/.zshrc
```

### 🌐 Linux server over SSH

A Linux server needs no install command: install `ai` on it from the Web UI of a machine that already runs `ai`.

1. In the Web UI, open **VMs** and add the server's SSH login.
2. Pick a release and install `ai`. The daemon uploads a verified release binary and runs it as a systemd user service on port `17700`.
3. The page lists the admin steps it cannot do without sudo, such as enabling linger (required, so `ai` keeps running after logout and starts at boot), installing `tmux` or opening the firewall port. Run them in the server's SSH terminal; the daemon never asks for your password.

Upgrade, start/stop and uninstall are on the same page. macOS and Windows have no remote install: their tray needs a desktop session.

## ▶️ Run

| Platform   | Command    | Result                                                                               |
| :--------- | :--------- | :----------------------------------------------------------------------------------- |
| 🪟 Windows | `ai`       | Tray icon; first run turns on **Start with Windows**                                 |
| 🍎 macOS   | `ai`       | Menu bar icon; first run turns on **Start at login**. Over SSH: `ai serve --no-tray` |
| 🐧 Linux   | `ai serve` | Headless daemon; keep it in `tmux` or your own process manager                       |

**Quit** in the tray menu stops the daemon and closes all sessions. To start it again, run `ai` (full path if `bin` is not on `PATH`: `& "$env:LOCALAPPDATA\Programs\culur-ai\bin\ai.exe"` on Windows, `~/.local/share/culur-ai/bin/ai` on macOS). `ai claude`, `ai codex`, `ai agy`, `ai shell` and `ai restart` also start the tray when it is not running. With autostart on, it starts again at the next login.

The daemon listens on port `17700` (`ai config port <port>` to change it). Open the Web UI from the tray menu, or point the web app at `<host>:17700`, then approve the client with `ai clients approve <client-id>`.

macOS binaries are not signed with an Apple Developer ID yet; the firewall may ask again after each update.

## 🔄 Update

```bash
ai update
```

`ai update --check` only reports; `ai update --channel beta` includes betas (the default channel is `stable`). On Windows and macOS the tray restarts into the new version and rolls back if it fails; on Linux, run `ai restart` afterwards.

## 🗑️ Uninstall

Turn off autostart in the tray menu and **Quit** (Linux: `ai kill`), then delete the install folder and its `PATH` entry.

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\culur-ai"
```

```bash
rm -rf ~/.local/share/culur-ai ~/Library/Logs/culur-ai ~/Library/Application\ Support/culur-ai
```

🧹 Optional: delete settings, certificates and approved clients. Skip this if you plan to reinstall.

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.config\culur-ai"
```

```bash
rm -rf ~/.config/culur-ai
```

## 🔒 Security

Treat `ai` as an open SSH channel into your machine:

- ✅ Approve only your own devices. Check the list with `ai clients list` and remove the rest with `ai clients revoke <client-id>`.
- 🚫 Do not expose port `17700` to the internet. Use it on a trusted LAN or a private network such as Tailscale, or limit it with `--bind 127.0.0.1`.
- 🔐 Keep `~/.config/culur-ai` private, like `~/.ssh`. It holds the TLS key, the signing secret of client tokens and the approved client list.
- 🔑 Keep the MCP token (`ai mcp token`) secret, like a private key.
- 🛑 Quit the tray, or turn off autostart, when you do not need remote access.

## ⚖️ Disclaimer

This software is provided "as is", without warranty of any kind. You use it at your own risk. The authors are not liable for any damage, data loss or security incident from its use, including commands that you, an approved client or a code agent run through it. You are responsible for securing the machines you install it on.
