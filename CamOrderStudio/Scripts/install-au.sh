#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_bundle="${1:-$root/dist/CamOrder Studio.component}"
destination="$HOME/Library/Audio/Plug-Ins/Components/CamOrder Studio.component"
if [[ ! -d "$source_bundle" ]]; then echo "Build the plug-in with Scripts/build-au.sh first."; exit 1; fi
codesign --verify --deep --strict "$source_bundle"
mkdir -p "$(dirname "$destination")"
if [[ -e "$destination" ]]; then
  backup="$HOME/Library/Application Support/CamOrder Studio/Plugin Backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  mv "$destination" "$backup/"
fi
ditto "$source_bundle" "$destination"
# Restart only Apple's disposable registration service, never Logic or its projects.
killall -u "$(id -un)" AudioComponentRegistrar 2>/dev/null || true
echo "Installed CamOrder Studio. Reopen Logic and choose Audio FX > Audio Units > Santismo > CamOrder Studio."
