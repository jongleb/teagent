#!/bin/sh
# Builds the release binary for target $1 and packs
# dist/teagent-<version>-<target>.tar.gz.
set -eu

target=$1
version=$(sed -n 's/^(version \(.*\))$/\1/p' dune-project)
name=teagent-$version-$target
dir=dist/$name

opam exec -- dune build --profile release --build-dir _build_dist bin/teagent.exe

rm -rf "$dir" && mkdir -p "$dir/licenses"
cp _build_dist/default/bin/teagent.exe "$dir/teagent"
chmod 755 "$dir/teagent"
strip "$dir/teagent"

case $(uname -s) in
  Linux) libraries=$(ldd "$dir/teagent") ;;
  Darwin) libraries=$(otool -L "$dir/teagent" | tail -n +2) ;;
esac
echo "$libraries"
if echo "$libraries" | grep -Eq '/opt/|/usr/local/|homebrew|opam'; then
  echo "teagent links a library that is not part of the system" >&2
  exit 1
fi
test "$("$dir/teagent" --version)" = "$version"

cp LICENSE README.md "$dir/"
cp vendor/dartea/LICENSE "$dir/licenses/dartea.txt"
cp vendor/dartea/NOTICE "$dir/licenses/dartea-notice.txt"
tar -czf "dist/$name.tar.gz" -C dist "$name"
echo "dist/$name.tar.gz"
