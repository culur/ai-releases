#!/bin/sh
# Install culur-ai (`ai`) for the current user on Linux or macOS, no root needed.
#
#   curl -fsSL https://raw.githubusercontent.com/culur/ai-releases/main/install.sh | sh
#
# Lists the releases that have an archive for this machine and lets you pick
# one (Up/Down or 1-9, Enter to install, q to cancel). Without a terminal it
# installs the newest stable release.
#
# Verifies the cosign signature of checksums.txt when cosign is on PATH, then
# the archive's SHA256 against checksums.txt.
#
# Env overrides:
#   AI_INSTALL_VERSION   install this version, such as 0.2.0 or 0.3.0-beta.1, without the menu
#   AI_INSTALL_DIR       install root (default: $HOME/.local/share/culur-ai)
#   AI_RELEASE_BASE_URL  folder holding the archives and checksums.txt; skips the
#                        menu and AI_INSTALL_VERSION (file:// works, for testing local builds)
#
# The archive keeps its layout: <dir>/bin/ai, <dir>/packages/document-renderer
# and <dir>/THIRD_PARTY_NOTICES.txt.
set -eu

REPO="culur/ai-releases"
REPO_URL="https://github.com/$REPO/releases"
API_URL="https://api.github.com/repos/$REPO/releases?per_page=30"
MENU_SIZE=9

# Release signing key; keep in sync with apps/cli/internal/updater/cosign.pub
# of the source repo.
PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUFKpBSd/V4tzUXrjIsjILczpMyq4
7k3TBrIyGqvMsRWeDZXZLbyHTc7o1FXoS0F+qQvNU9gXK0y9jCIoF3oIlg==
-----END PUBLIC KEY-----'

tmp=
old_stty=

cleanup() {
	if [ -n "$old_stty" ]; then
		stty "$old_stty" </dev/tty 2>/dev/null || true
		printf '\033[?25h' >/dev/tty 2>/dev/null || true
	fi
	[ -z "$tmp" ] || rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
	echo "install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

need curl
need tar
need uname
need mktemp
need awk

case "$(uname -s)" in
Linux) os=linux ;;
Darwin) os=darwin ;;
*) fail "unsupported OS: $(uname -s) (use install.ps1 on Windows)" ;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

install_dir="${AI_INSTALL_DIR:-$HOME/.local/share/culur-ai}"
archive="ai_${os}_${arch}.tar.gz"
tmp="$(mktemp -d)"

# Prints "<tag> <stable|beta>" per release that has $archive, newest first.
# Parses the API's JSON without jq: one field per line, then picks tag_name,
# prerelease and the asset download URLs of each release.
list_releases() {
	curl -fsSL -H 'Accept: application/vnd.github+json' "$API_URL" |
		tr ',' '\n' | sed 's/^[[:space:]{[]*//' |
		awk -v archive="$archive" '
			/^"tag_name":/ { v = $0; sub(/^"tag_name":[[:space:]]*"/, "", v); sub(/".*/, "", v); tag = v; order[++n] = tag; next }
			/^"prerelease":/ { chan[tag] = ($0 ~ /true/) ? "beta" : "stable"; next }
			/^"draft":[[:space:]]*true/ { draft[tag] = 1; next }
			/^"browser_download_url":/ { if (index($0, "/" archive "\"")) has[tag] = 1 }
			END { for (i = 1; i <= n; i++) { t = order[i]; if (has[t] && !draft[t]) print t, chan[t] } }'
}

# Shows the menu on /dev/tty and sets $tag to the chosen release.
choose_release() {
	count=$(awk 'END { print NR }' "$1")
	[ "$count" -le "$MENU_SIZE" ] || count=$MENU_SIZE
	latest=$(awk '$2 == "stable" { print NR; exit }' "$1")
	sel=${latest:-1}
	[ "$sel" -le "$count" ] || sel=1

	draw() {
		i=0
		while read -r t c; do
			i=$((i + 1))
			[ "$i" -le "$count" ] || break
			label="$t"
			[ "$c" = beta ] && label="$label  (beta)"
			[ "$i" = "${latest:-}" ] && label="$label  (latest stable)"
			if [ "$i" -eq "$sel" ]; then
				printf '\033[2K  \033[7m > %s \033[0m\n' "$label"
			else
				printf '\033[2K    %d. %s\n' "$i" "$label"
			fi
		done <"$1"
	}

	{
		echo
		if [ -x "$install_dir/bin/ai" ]; then
			echo "Installed: $("$install_dir/bin/ai" --version 2>/dev/null || echo unknown)"
		fi
		echo "Select the version of ai to install (Up/Down or 1-$count, Enter to install, q to cancel):"
	} >/dev/tty
	old_stty=$(stty -g </dev/tty)
	stty -icanon -echo min 1 time 0 </dev/tty
	printf '\033[?25l' >/dev/tty
	draw "$1" >/dev/tty
	esc=$(printf '\033')
	while :; do
		key=$(dd bs=1 count=1 2>/dev/null </dev/tty)
		case "$key" in
		"$esc")
			rest=$(dd bs=1 count=2 2>/dev/null </dev/tty)
			case "$rest" in
			'[A' | OA) [ "$sel" -le 1 ] || sel=$((sel - 1)) ;;
			'[B' | OB) [ "$sel" -ge "$count" ] || sel=$((sel + 1)) ;;
			esac
			;;
		k) [ "$sel" -le 1 ] || sel=$((sel - 1)) ;;
		j) [ "$sel" -ge "$count" ] || sel=$((sel + 1)) ;;
		[1-9]) [ "$key" -gt "$count" ] || sel=$key ;;
		q | Q) fail "cancelled" ;;
		'') break ;; # Enter (the newline is stripped by $(...))
		esac
		printf '\033[%dA' "$count" >/dev/tty
		draw "$1" >/dev/tty
	done
	stty "$old_stty" </dev/tty
	printf '\033[?25h' >/dev/tty
	old_stty=
	tag=$(awk -v n="$sel" 'NR == n { print $1 }' "$1")
}

if [ -n "${AI_RELEASE_BASE_URL:-}" ]; then
	base_url="${AI_RELEASE_BASE_URL%/}"
	tag="(local)"
else
	if [ -n "${AI_INSTALL_VERSION:-}" ]; then
		tag="v${AI_INSTALL_VERSION#v}"
	else
		list_releases >"$tmp/releases" ||
			fail "cannot list releases from $API_URL (GitHub API rate limit?); set AI_INSTALL_VERSION to install a known version"
		[ -s "$tmp/releases" ] || fail "no release has $archive yet (see $REPO_URL)"
		if (exec </dev/tty) 2>/dev/null; then
			choose_release "$tmp/releases"
		else
			tag=$(awk '$2 == "stable" { print $1; exit }' "$tmp/releases")
			[ -n "$tag" ] || fail "no stable release has $archive yet; set AI_INSTALL_VERSION to one of: $(awk '{ printf "%s%s", sep, substr($1, 2); sep = ", " }' "$tmp/releases")"
		fi
	fi
	base_url="$REPO_URL/download/$tag"
fi

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d ' ' -f 1
	else
		fail "missing sha256sum or shasum"
	fi
}

echo "install: downloading $archive ($tag) from $base_url"
curl -fsSL -o "$tmp/$archive" "$base_url/$archive" || fail "download failed: $base_url/$archive"
curl -fsSL -o "$tmp/checksums.txt" "$base_url/checksums.txt" || fail "download failed: $base_url/checksums.txt"

# checksums.txt is signed with the release key; verify it when cosign exists.
if command -v cosign >/dev/null 2>&1; then
	curl -fsSL -o "$tmp/checksums.txt.sigstore.json" "$base_url/checksums.txt.sigstore.json" ||
		fail "download failed: $base_url/checksums.txt.sigstore.json"
	printf '%s\n' "$PUBLIC_KEY" >"$tmp/cosign.pub"
	# The bundle is in cosign v3's format: v2.4+ reads it with
	# --new-bundle-format, older cosign cannot read it.
	cosign_ver="$(cosign version 2>&1 | sed -n 's/^GitVersion:[[:space:]]*v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
	cosign_major="${cosign_ver%%.*}"
	cosign_minor="${cosign_ver#*.}"
	if [ -n "$cosign_ver" ] && [ "$cosign_major" -ge 3 ]; then
		set --
	elif [ -n "$cosign_ver" ] && [ "$cosign_major" -eq 2 ] && [ "$cosign_minor" -ge 4 ]; then
		set -- --new-bundle-format
	else
		fail "cosign ${cosign_ver:-of unknown version} cannot read the release signature; need cosign v2.4 or newer (v3 recommended). Upgrade it (https://github.com/sigstore/cosign/releases) or remove it from PATH to install without the signature check"
	fi
	cosign verify-blob --key "$tmp/cosign.pub" --bundle "$tmp/checksums.txt.sigstore.json" "$@" \
		--insecure-ignore-tlog=true "$tmp/checksums.txt" >/dev/null 2>&1 ||
		fail "signature check of checksums.txt failed"
	echo "install: signature OK"
else
	echo "install: warning: cosign not found, skipping the signature check (SHA256 is still checked)" >&2
fi

expected="$(awk -v name="$archive" '$2 == name || $2 == "*" name { print $1 }' "$tmp/checksums.txt")"
[ -n "$expected" ] || fail "$archive is not listed in checksums.txt"
actual="$(sha256 "$tmp/$archive")"
[ "$expected" = "$actual" ] || fail "SHA256 mismatch for $archive (expected $expected, got $actual)"
echo "install: SHA256 OK"

mkdir -p "$tmp/extract"
tar -xzf "$tmp/$archive" -C "$tmp/extract"
[ -f "$tmp/extract/bin/ai" ] || fail "archive has no bin/ai"

mkdir -p "$install_dir/bin" "$install_dir/packages"
# Replace the renderer as a whole so files removed upstream do not linger.
rm -rf "$install_dir/packages/document-renderer"
mv "$tmp/extract/packages/document-renderer" "$install_dir/packages/document-renderer"
# mv over a running binary is safe: the old inode stays alive until it exits.
mv -f "$tmp/extract/bin/ai" "$install_dir/bin/ai"
chmod 755 "$install_dir/bin/ai"
if [ -f "$tmp/extract/THIRD_PARTY_NOTICES.txt" ]; then
	mv -f "$tmp/extract/THIRD_PARTY_NOTICES.txt" "$install_dir/THIRD_PARTY_NOTICES.txt"
fi

echo "install: installed $("$install_dir/bin/ai" --version 2>/dev/null || echo ai) to $install_dir"

case ":$PATH:" in
*":$install_dir/bin:"*) ;;
*)
	echo
	echo "Add ai to your PATH, e.g. in ~/.profile, ~/.bashrc or ~/.zshrc:"
	echo "  export PATH=\"$install_dir/bin:\$PATH\""
	;;
esac
