#!/bin/bash

# Install Better Workspaces into the current user's Omarchy config by symlinking
# this checkout, so `git pull` updates it in place.
#
#   ~/.config/hypr/better-workspaces            -> hypr/better-workspaces
#   ~/.config/omarchy/plugins/<plugin id>       -> shell/<plugin id>
#   ~/.config/hypr/workspaces.lua               (created from the example if missing,
#                                                otherwise left alone)

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
plugin_id="bumaruf.better-workspaces"
hypr="$config/hypr"
plugins="$config/omarchy/plugins"
stamp="$(date +%s)"

link() {
  local source="$1" target="$2"
  if [[ -e $target && ! -L $target ]]; then
    mv "$target" "$target.bak.$stamp"
    echo "Backed up $target to $target.bak.$stamp"
  fi
  ln -sfn "$source" "$target"
  echo "Linked $target"
}

mkdir -p "$hypr" "$plugins"
link "$repo/hypr/better-workspaces" "$hypr/better-workspaces"
link "$repo/shell/$plugin_id" "$plugins/$plugin_id"

# Load the module from the user's workspaces.lua, which hyprland.lua requires.
if ! grep -qs 'hypr.better-workspaces.init' "$hypr/workspaces.lua"; then
  if [[ -e $hypr/workspaces.lua ]]; then
    mv "$hypr/workspaces.lua" "$hypr/workspaces.lua.bak.$stamp"
    echo "Backed up $hypr/workspaces.lua to $hypr/workspaces.lua.bak.$stamp"
  fi
  cp "$repo/hypr/workspaces.lua" "$hypr/workspaces.lua"
  echo "Wrote $hypr/workspaces.lua (edit the monitor list there)"
fi

if ! grep -qs 'require("hypr.workspaces")' "$hypr/hyprland.lua"; then
  echo 'require("hypr.workspaces")' >>"$hypr/hyprland.lua"
  echo "Added require(\"hypr.workspaces\") to $hypr/hyprland.lua"
fi

if command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null
  errors="$(hyprctl configerrors)"
  [[ -z ${errors//[[:space:]]/} ]] || { echo "$errors" >&2; exit 1; }
fi

# Swap the stock (or cloned) workspace widget for ours, keeping its place.
shell_json="$config/omarchy/shell.json"
if [[ -f $shell_json ]] && command -v jq >/dev/null; then
  current="$(jq -r '[.bar.layout[]?[]?.id | select(test("workspaces$"))] | first // empty' "$shell_json")"
  if [[ -n $current && $current != "$plugin_id" ]]; then
    cp "$shell_json" "$shell_json.bak.$stamp"
    jq --arg old "$current" --arg new "$plugin_id" \
      '(.bar.layout[]?[]? | select(.id == $old) | .id) |= $new' \
      "$shell_json.bak.$stamp" >"$shell_json"
    echo "Replaced $current with $plugin_id in the bar (backup: $shell_json.bak.$stamp)"
  fi
fi

if command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$plugin_id" >/dev/null
  echo "Enabled $plugin_id"
fi

echo "Done. SUPER+\` (key left of 1) opens the overview; SUPER+CTRL+UP/DOWN switches workspaces."
