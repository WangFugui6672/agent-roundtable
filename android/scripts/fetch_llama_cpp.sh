#!/usr/bin/env bash
# Fetch the pinned llama.cpp source used by the Android JNI bridge.
#
# The repository does not vendor llama.cpp. This script extracts the source
# snapshot shipped in the pinned llama-cpp-python sdist (llama.cpp 0.5.0).
# It is idempotent: when the source tree already exists it does nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/../app/src/main/cpp/llama.cpp"
archive="llama_cpp_python-0.3.36.tar.gz"
url="https://files.pythonhosted.org/packages/ec/e9/e7de2b0463ea3ffbf0ede6cb21b58c1258a8f6521aae45ca773a59fe7cf3/$archive"
sha256="832db0699007f1be95a7e41ef12e88926b02ba836461e36a36372db2760c1a2e"
root="llama_cpp_python-0.3.36"

if [ -f "$dest/CMakeLists.txt" ]; then
    echo "llama.cpp source already present: $dest"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $archive ..."
curl -L --retry 5 --retry-delay 2 --fail -o "$tmp/$archive" "$url"

echo "$sha256  $tmp/$archive" | shasum -a 256 -c -

tar -xzf "$tmp/$archive" -C "$tmp" "$root/vendor/llama.cpp"
mv "$tmp/$root/vendor/llama.cpp" "$dest"
echo "llama.cpp source ready: $dest"
