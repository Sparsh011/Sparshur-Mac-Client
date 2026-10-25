#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_swiftc="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
task_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
task_preview_dir="${1:-/private/tmp/sparshur-previews}"
sources=(Sparshur/**/*.swift)
sources=(${sources:#Sparshur/SparshurApp.swift})
sources=(${sources:#Sparshur/AppEntry.swift})
"$task_swiftc" -parse-as-library -swift-version 6 \
  -target "$(uname -m)-apple-macosx14.0" -sdk "$task_sdk" \
  -module-cache-path /private/tmp/sparshur-preview-cache \
  "${sources[@]}" tools/render-previews.swift -o /private/tmp/sparshur-render-previews
/private/tmp/sparshur-render-previews "$task_preview_dir"
