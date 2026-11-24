# Install culur-ai (`ai`) for the current user on Windows, no admin needed.
#
#   irm https://raw.githubusercontent.com/culur/ai-releases/main/install.ps1 | iex
#
# Lists the releases that have a Windows archive and lets you pick one
# (Up/Down or 1-9, Enter to install, Esc to cancel). Without an interactive
# console it installs the newest stable release.
#
# Verifies the cosign signature of checksums.txt when cosign is on PATH, then
# the archive's SHA256 against checksums.txt.
#
# Env overrides:
#   AI_INSTALL_VERSION   install this version, such as 0.2.0 or 0.3.0-beta.1, without the menu
#   AI_INSTALL_DIR       install root (default: %LOCALAPPDATA%\Programs\culur-ai)
#   AI_RELEASE_BASE_URL  folder holding the archives and checksums.txt; skips the
#                        menu and AI_INSTALL_VERSION (file:/// works, for testing local builds)
#
# The archive keeps its layout: <dir>\bin\ai.exe, <dir>\packages\document-renderer
# and <dir>\THIRD_PARTY_NOTICES.txt.
# Runs on Windows PowerShell 5.1 and PowerShell 7. The script block keeps its
# variables and preferences out of the caller's session when run through iex.

& {
    $ErrorActionPreference = 'Stop'
    # Module cmdlets (Expand-Archive) read the global preference, not this scope's.
    $savedProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        $Repo = 'culur/ai-releases'
        $RepoUrl = "https://github.com/$Repo/releases"
        $ApiUrl = "https://api.github.com/repos/$Repo/releases?per_page=30"
        $MenuSize = 9

        # Release signing key; keep in sync with apps/cli/internal/updater/cosign.pub
        # of the source repo.
        $PublicKey = @'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUFKpBSd/V4tzUXrjIsjILczpMyq4
7k3TBrIyGqvMsRWeDZXZLbyHTc7o1FXoS0F+qQvNU9gXK0y9jCIoF3oIlg==
-----END PUBLIC KEY-----
'@

        function Stop-Install([string]$Message) {
            throw "install: $Message"
        }

        function Get-ReleaseFile([string]$Url, [string]$OutFile) {
            $uri = [Uri]$Url
            if ($uri.IsFile) {
                if (-not (Test-Path -LiteralPath $uri.LocalPath)) { Stop-Install "not found: $Url" }
                Copy-Item -LiteralPath $uri.LocalPath -Destination $OutFile
                return
            }
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            } catch {
                Stop-Install "download failed: $Url ($($_.Exception.Message))"
            }
        }

        # Releases that have $Archive, newest first: objects with Tag and Beta.
        function Get-Releases([string]$Archive) {
            try {
                $all = Invoke-RestMethod -Uri $ApiUrl -Headers @{ Accept = 'application/vnd.github+json' } -UseBasicParsing
            } catch {
                Stop-Install "cannot list releases from $ApiUrl (GitHub API rate limit?); set AI_INSTALL_VERSION to install a known version ($($_.Exception.Message))"
            }
            foreach ($r in $all) {
                if ($r.draft) { continue }
                if (-not @($r.assets | Where-Object { $_.name -eq $Archive }).Count) { continue }
                [pscustomobject]@{ Tag = [string]$r.tag_name; Beta = [bool]$r.prerelease }
            }
        }

        function Test-InteractiveConsole {
            if ($Host.Name -ne 'ConsoleHost') { return $false }
            try {
                return -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
            } catch {
                return $false
            }
        }

        # Arrow-key menu on the console; returns the chosen release.
        function Select-Release($Releases, [string]$InstalledExe) {
            $items = @($Releases | Select-Object -First $MenuSize)
            $latest = -1
            for ($i = 0; $i -lt $items.Count; $i++) {
                if (-not $items[$i].Beta) { $latest = $i; break }
            }
            $sel = if ($latest -ge 0) { $latest } else { 0 }
            $labels = @(for ($i = 0; $i -lt $items.Count; $i++) {
                $label = $items[$i].Tag
                if ($items[$i].Beta) { $label += '  (beta)' }
                if ($i -eq $latest) { $label += '  (latest stable)' }
                $label
            })
            $width = ($labels | Measure-Object -Property Length -Maximum).Maximum + 8

            Write-Host ''
            if (Test-Path -LiteralPath $InstalledExe) {
                $current = 'unknown'
                try { $current = & $InstalledExe --version 2>$null } catch { }
                Write-Host "Installed: $current"
            }
            Write-Host "Select the version of ai to install (Up/Down or 1-$($items.Count), Enter to install, Esc to cancel):"

            $draw = {
                for ($i = 0; $i -lt $items.Count; $i++) {
                    if ($i -eq $sel) {
                        Write-Host ('  > ' + $labels[$i]).PadRight($width) -ForegroundColor Black -BackgroundColor Cyan
                    } else {
                        Write-Host ('    ' + ($i + 1) + '. ' + $labels[$i]).PadRight($width)
                    }
                }
            }
            $cursorVisible = $true
            try { $cursorVisible = [Console]::CursorVisible } catch { }
            try {
                [Console]::CursorVisible = $false
                & $draw
                # Measured after the first draw, which may have scrolled the console.
                $top = [Console]::CursorTop - $items.Count
                while ($true) {
                    $key = [Console]::ReadKey($true)
                    switch ($key.Key) {
                        'UpArrow' { if ($sel -gt 0) { $sel-- } }
                        'DownArrow' { if ($sel -lt $items.Count - 1) { $sel++ } }
                        'K' { if ($sel -gt 0) { $sel-- } }
                        'J' { if ($sel -lt $items.Count - 1) { $sel++ } }
                        'Enter' { return $items[$sel] }
                        'Escape' { Stop-Install 'cancelled' }
                        'Q' { Stop-Install 'cancelled' }
                        default {
                            $n = 0
                            if ([int]::TryParse([string]$key.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { $sel = $n - 1 }
                        }
                    }
                    [Console]::SetCursorPosition(0, $top)
                    & $draw
                }
            } finally {
                try { [Console]::CursorVisible = $cursorVisible } catch { }
            }
        }

        # Releases ship windows/amd64 only; ARM64 Windows runs it under emulation.
        $cpu = $env:PROCESSOR_ARCHITEW6432
        if (-not $cpu) { $cpu = $env:PROCESSOR_ARCHITECTURE }
        if ($cpu -ne 'AMD64' -and $cpu -ne 'ARM64') { Stop-Install "unsupported architecture: $cpu" }

        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }

        $installDir = $env:AI_INSTALL_DIR
        if (-not $installDir) { $installDir = Join-Path $env:LOCALAPPDATA 'Programs\culur-ai' }
        $binDir = Join-Path $installDir 'bin'
        $exe = Join-Path $binDir 'ai.exe'
        $archive = 'ai_windows_amd64.zip'

        if ($env:AI_RELEASE_BASE_URL) {
            $baseUrl = $env:AI_RELEASE_BASE_URL.TrimEnd('/')
            $tag = '(local)'
        } else {
            if ($env:AI_INSTALL_VERSION) {
                $tag = 'v' + $env:AI_INSTALL_VERSION.TrimStart('v')
            } else {
                $releases = @(Get-Releases $archive)
                if (-not $releases.Count) { Stop-Install "no release has $archive yet (see $RepoUrl)" }
                if (Test-InteractiveConsole) {
                    $tag = (Select-Release $releases $exe).Tag
                } else {
                    $stable = @($releases | Where-Object { -not $_.Beta })
                    if (-not $stable.Count) {
                        $known = ($releases | ForEach-Object { $_.Tag.TrimStart('v') }) -join ', '
                        Stop-Install "no stable release has $archive yet; set AI_INSTALL_VERSION to one of: $known"
                    }
                    $tag = $stable[0].Tag
                }
            }
            $baseUrl = "$RepoUrl/download/$tag"
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('culur-ai-install-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            Write-Host "install: downloading $archive ($tag) from $baseUrl"
            $archivePath = Join-Path $tmp $archive
            $sumsPath = Join-Path $tmp 'checksums.txt'
            Get-ReleaseFile "$baseUrl/$archive" $archivePath
            Get-ReleaseFile "$baseUrl/checksums.txt" $sumsPath

            # checksums.txt is signed with the release key; verify it when cosign exists.
            if (Get-Command cosign -ErrorAction SilentlyContinue) {
                $bundlePath = Join-Path $tmp 'checksums.txt.sigstore.json'
                $keyPath = Join-Path $tmp 'cosign.pub'
                Get-ReleaseFile "$baseUrl/checksums.txt.sigstore.json" $bundlePath
                [IO.File]::WriteAllText($keyPath, $PublicKey)
                # cosign reports on stderr; under 'Stop' PowerShell 5.1 would throw on it.
                $ErrorActionPreference = 'Continue'
                # The bundle is in cosign v3's format: v2.4+ reads it with
                # --new-bundle-format, older cosign cannot read it.
                $cosignVer = $null
                $versionText = (& cosign version 2>&1 | Out-String)
                if ($versionText -match '(?m)^GitVersion:\s*v?(\d+)\.(\d+)') { $cosignVer = [version]"$($Matches[1]).$($Matches[2])" }
                $ErrorActionPreference = 'Stop'
                if ($cosignVer -and $cosignVer.Major -ge 3) {
                    $bundleArgs = @()
                } elseif ($cosignVer -and $cosignVer -ge [version]'2.4') {
                    $bundleArgs = @('--new-bundle-format')
                } else {
                    $shown = if ($cosignVer) { $cosignVer } else { 'of unknown version' }
                    Stop-Install "cosign $shown cannot read the release signature; need cosign v2.4 or newer (v3 recommended). Upgrade it (https://github.com/sigstore/cosign/releases) or remove it from PATH to install without the signature check"
                }
                $ErrorActionPreference = 'Continue'
                $null = & cosign verify-blob --key $keyPath --bundle $bundlePath @bundleArgs --insecure-ignore-tlog=true $sumsPath 2>&1
                $ErrorActionPreference = 'Stop'
                if ($LASTEXITCODE -ne 0) { Stop-Install 'signature check of checksums.txt failed' }
                Write-Host 'install: signature OK'
            } else {
                Write-Warning 'install: cosign not found, skipping the signature check (SHA256 is still checked)'
            }

            $expected = $null
            foreach ($line in Get-Content -LiteralPath $sumsPath) {
                $parts = $line.Trim() -split '\s+'
                if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $archive) { $expected = $parts[0].ToLowerInvariant() }
            }
            if (-not $expected) { Stop-Install "$archive is not listed in checksums.txt" }
            $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($expected -ne $actual) { Stop-Install "SHA256 mismatch for $archive (expected $expected, got $actual)" }
            Write-Host 'install: SHA256 OK'

            $extract = Join-Path $tmp 'extract'
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extract
            $newExe = Join-Path $extract 'bin\ai.exe'
            if (-not (Test-Path -LiteralPath $newExe)) { Stop-Install 'archive has no bin\ai.exe' }

            $pkgDir = Join-Path $installDir 'packages'
            New-Item -ItemType Directory -Force -Path $binDir, $pkgDir | Out-Null

            # Replace the renderer as a whole so files removed upstream do not linger.
            $renderer = Join-Path $pkgDir 'document-renderer'
            if (Test-Path -LiteralPath $renderer) { Remove-Item -LiteralPath $renderer -Recurse -Force }
            Move-Item -LiteralPath (Join-Path $extract 'packages\document-renderer') -Destination $renderer

            # A running ai.exe cannot be overwritten but can be renamed: move it aside.
            if (Test-Path -LiteralPath $exe) {
                $old = "$exe.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).old"
                Move-Item -LiteralPath $exe -Destination $old
                Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $newExe -Destination $exe

            $notices = Join-Path $extract 'THIRD_PARTY_NOTICES.txt'
            if (Test-Path -LiteralPath $notices) {
                Move-Item -LiteralPath $notices -Destination (Join-Path $installDir 'THIRD_PARTY_NOTICES.txt') -Force
            }

            $version = 'ai'
            try { $version = & $exe --version 2>$null } catch { Write-Warning "install: could not run ${exe}: $($_.Exception.Message)" }
            Write-Host "install: installed $version to $installDir"

            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $onPath = @($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }).Count -gt 0
            if (-not $onPath) {
                Write-Host ''
                Write-Host 'Add ai to your user PATH (then open a new terminal):'
                Write-Host "  [Environment]::SetEnvironmentVariable('Path', `"$binDir;`" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')"
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $global:ProgressPreference = $savedProgress
    }
}
