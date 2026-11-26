#!/bin/sh
# 今の WhiplashCore (Swift) に UserDefaults の保存データを書き出させ、shared の commonTest の fixture にする。
# 保存形式を変えたら、これを流し直して Kotlin 側のテストが同じ内容を読み書きできるか確かめる。
set -eu
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/shared/src/commonTest/fixtures/swift"
rm -rf "$out"
mkdir -p "$out"
cd "$repo/WhiplashCore"
WHIPLASH_FIXTURE_DIR="$out" swift test --filter SharedCoreFixtureExport
find "$out" -type f | sort
