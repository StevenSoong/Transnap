#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
output_dir="$project_dir/dist"
app_dir="$output_dir/Transnap.app"

cd "$project_dir"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"

# dist/ is generated output. Recreate the exact bundle so removed resources
# cannot survive from an earlier build.
rm -rf -- "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Transnap" "$app_dir/Contents/MacOS/Transnap"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/Transnap.icns" "$app_dir/Contents/Resources/Transnap.icns"
codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "com.codex.Transnap"' \
  "$app_dir"

echo "$app_dir"
