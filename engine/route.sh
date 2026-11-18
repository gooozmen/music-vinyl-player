#!/bin/bash
# route.sh <app> bus   move every audio stream of <app> to the silent scratch bus
#                      (safe to call repeatedly: players such as Spotify create
#                      new streams on seek/pause, and each must be caught, or
#                      it plays through the speakers on top of the scratch)
# route.sh <app> back  move every stream sitting on the bus back to where it
#                      came from ("" = any app)
set -u
app="${1,,}"; to="${2:-back}"
BUS=gooozmen_scratch_bus
state="${XDG_RUNTIME_DIR:-/tmp}/gooozmen-scratch-route"

bus_id=$(pactl -f json list sinks 2>/dev/null | jq -r --arg b "$BUS" '.[] | select(.name==$b) | .index')
[[ -n $bus_id ]] || exit 0

streams() {
  pactl -f json list sink-inputs 2>/dev/null | jq -r --arg app "$app" '
    .[] | select($app == "" or (((.properties["application.name"] // "") + " " + (.properties["application.process.binary"] // "") + " " + (.properties["node.name"] // "")) | ascii_downcase | contains($app)))
    | select((.properties["node.name"] // "") | startswith("gooozmen-") | not)
    | "\(.index) \(.sink)"'
}

if [[ $to == bus ]]; then
  touch "$state"
  streams | while read -r idx sink; do
    [[ $sink == "$bus_id" ]] && continue
    grep -q "^$idx " "$state" || echo "$idx $sink" >> "$state"
    pactl move-sink-input "$idx" "$BUS" 2>/dev/null
  done
else
  streams | while read -r idx sink; do
    [[ $sink == "$bus_id" ]] || continue
    orig=$(awk -v i="$idx" '$1==i {print $2; exit}' "$state" 2>/dev/null)
    if [[ -n $orig ]]; then
      pactl move-sink-input "$idx" "$orig" 2>/dev/null || pactl move-sink-input "$idx" @DEFAULT_SINK@ 2>/dev/null
    else
      pactl move-sink-input "$idx" @DEFAULT_SINK@ 2>/dev/null
    fi
  done
  rm -f "$state"
fi
exit 0
