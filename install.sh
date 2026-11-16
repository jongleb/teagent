#!/bin/sh
# Installs the teagent binary from the GitHub release.
#   curl -fsSL https://jongleb.github.io/teagent/install.sh | sh
# TEAGENT_VERSION=0.1.0 picks a release (default: the latest);
# TEAGENT_INSTALL_DIR picks the folder (default: ~/.local/bin).
set -eu

repo=jongleb/teagent
dir=${TEAGENT_INSTALL_DIR:-$HOME/.local/bin}
releases=${TEAGENT_RELEASES:-https://github.com/$repo/releases}

fail() {
  echo "teagent: $1" >&2
  exit 1
}

case "$(uname -s)" in
  Darwin) os=apple-darwin ;;
  Linux) os=unknown-linux-gnu ;;
  *) fail "no binary for $(uname -s); build from source: https://github.com/$repo#from-source" ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) cpu=aarch64 ;;
  x86_64 | amd64) cpu=x86_64 ;;
  *) fail "no binary for $(uname -m); build from source: https://github.com/$repo#from-source" ;;
esac

if [ "$os" = apple-darwin ] && [ "$cpu" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  cpu=aarch64
fi

target=$cpu-$os
version=${TEAGENT_VERSION:-$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$releases/latest" | sed -n 's#.*/tag/v##p')}
version=${version#v}
[ -n "$version" ] || fail "could not find the latest release at $releases"

name=teagent-$version-$target
base=$releases/download/v$version
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "Downloading teagent $version for $target"
curl -fsSL "$base/$name.tar.gz" -o "$tmp/$name.tar.gz" || fail "download failed: $base/$name.tar.gz"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || fail "download failed: $base/SHA256SUMS"

expected=$(awk -v file="$name.tar.gz" '$2 == file { print $1 }' "$tmp/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$name.tar.gz" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')
fi
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch for $name.tar.gz"

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
mkdir -p "$dir"
install -m 755 "$tmp/$name/teagent" "$dir/teagent"
echo "Installed teagent $("$dir/teagent" --version) to $dir/teagent"

if [ "$os" = unknown-linux-gnu ] && [ ! -x /usr/bin/bwrap ]; then
  echo
  echo "The sandboxed shell needs bubblewrap: sudo apt install bubblewrap (or dnf, pacman, apk)."
fi

case ":$PATH:" in
  *":$dir:"*) ;;
  *)
    echo
    echo "$dir is not on your PATH. Add it:"
    echo "  export PATH=\"$dir:\$PATH\""
    ;;
esac

echo
echo "Use it from Claude Code or Codex, in your project folder:"
echo "  claude mcp add --scope project teagent -- teagent --mcp"
echo "  codex mcp add teagent -- teagent --mcp"
