#!/bin/bash
# Starts the scratch engine.
#
# Two captures feed it (audio stays in RAM inside scratchd):
#   A  monitor of your speakers — what you normally hear
#   B  monitor of a silent "scratch bus" sink; while you hold the record the
#      player is moved there (route.sh), keeps playing, and we record the
#      track's upcoming audio from it
#
# Builds scratchd from scratchd.c on first run (or when the source is newer),
# so the plugin can be shared as source.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
BUS=gooozmen_scratch_bus

if [[ ! -x $here/scratchd || $here/scratchd.c -nt $here/scratchd ]]; then
  cc -O2 -o "$here/scratchd" "$here/scratchd.c" -lm -lpthread 2>/dev/null || { echo "error build-failed"; exit 1; }
fi

module=""
if ! pactl list short sinks 2>/dev/null | grep -q "[[:space:]]$BUS[[:space:]]"; then
  module=$(pactl load-module module-null-sink sink_name=$BUS \
    'sink_properties=device.description="Vinyl scratch bus" priority.session=0 priority.driver=0') || { echo "error no-bus"; exit 1; }
fi

child=""
cleanup() {
  [[ -n $child ]] && kill "$child" 2>/dev/null
  "$here/route.sh" "" back 2>/dev/null   # never leave a player stuck on the bus
  [[ -n $module ]] && pactl unload-module "$module" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

# Pin our own streams to the current speakers. Left to themselves, the audio
# server may "remember" a target by app name (pw-play/pw-record) — and if our
# output ever landed on the bus we record from, the engine would record itself
# and every scratch would get louder. The UI restarts us when the output
# device changes.
OUT=$(pactl get-default-sink 2>/dev/null)
[[ -n $OUT && $OUT != "$BUS" ]] || { echo "error no-output"; exit 1; }

exec 3< <(exec pw-record --raw --format f32 --rate 48000 --channels 2 --target "$OUT" \
  -P '{ stream.capture.sink = true node.dont-reconnect = true application.name = "gooozmen-scratch" node.name = "gooozmen-scratch-capture" node.description = "Vinyl scratch capture" }' -)
exec 4< <(exec pw-record --raw --format f32 --rate 48000 --channels 2 --target "$BUS" \
  -P '{ stream.capture.sink = true node.dont-reconnect = true application.name = "gooozmen-scratch" node.name = "gooozmen-scratch-bus-capture" node.description = "Vinyl scratch bus capture" }' -)
exec 5> >(exec pw-play --raw --format f32 --rate 48000 --channels 2 --latency 5ms --media-role Music --target "$OUT" \
  -P '{ node.dont-reconnect = true application.name = "gooozmen-scratch" node.name = "gooozmen-scratch" node.description = "Vinyl scratch" }' -)

# stdin/stdout pass straight through to the engine
"$here/scratchd" 3 4 5 <&0 &
child=$!
wait "$child"
