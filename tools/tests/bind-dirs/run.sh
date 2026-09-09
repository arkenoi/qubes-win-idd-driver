#!/usr/bin/env bash
# Offline tests for the bind-dirs core (core-agent/src/bind-dirs/bind-dirs.c), built with gcc
# against the in-memory fake file system. No guest, no Windows. Exit 1 on any failed check.
#
# Also builds the core with -Werror and strict warnings so an ntdll-unfriendly construct (CRT
# call, printf) shows up here before it costs a CI round-trip.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
core="$repo/core-agent/src/bind-dirs"
out="${TMPDIR:-/tmp}/bind-dirs-tests.$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT

# The core alone, strict: this is the file that ships in the native image.
gcc -std=c99 -Wall -Wextra -Werror -Wno-unused-parameter -pedantic \
    -c "$core/bind-dirs.c" -o "$out/core.o"

# Undefined-behaviour + address sanitizers on the test build when the runtime is installed:
# the core does a lot of manual buffer work and a silent overrun here would be a silent
# overrun at BootExecute. Probe first (the dev qube has gcc but no libasan) and SAY which
# build ran, so a plain build is never mistaken for a sanitized one.
san=()
if echo 'int main(void){return 0;}' | gcc -x c -fsanitize=address,undefined -o "$out/probe" - >/dev/null 2>&1; then
    san=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    echo "build: sanitized (ASan+UBSan)"
else
    echo "build: PLAIN - sanitizer runtime not installed on this host"
fi
gcc -std=gnu99 -g -O1 "${san[@]}" \
    -Wall -Wextra -Wno-unused-parameter \
    -I"$core" "$core/bind-dirs.c" "$here/fake-fs.c" "$here/test-bind-dirs.c" \
    -o "$out/test-bind-dirs"

"$out/test-bind-dirs"
