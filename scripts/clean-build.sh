#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: clean-build.sh REPOSITORY_ROOT BUILD_DIR" >&2
  exit 2
fi

root="$(cd "$1" && pwd -P)"
requested="$2"
expected="$root/build"

if [ "$requested" != "$expected" ]; then
  echo "refusing to clean a path other than the repository build directory" >&2
  exit 2
fi
if [ ! -e "$expected" ] && [ ! -L "$expected" ]; then
  exit 0
fi
if [ -L "$expected" ] || [ ! -d "$expected" ]; then
  echo "refusing to clean a non-directory or symlinked build path" >&2
  exit 2
fi
actual="$(cd "$expected" && pwd -P)"
if [ "$actual" != "$expected" ]; then
  echo "refusing to clean a build directory with a non-canonical path" >&2
  exit 2
fi

rm -rf -- "$expected"
