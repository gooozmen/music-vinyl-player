# gooozmen.music

Music widget for the Omarchy top bar: a big play/pause and a small "next"
button. Right click opens a card with a spinning vinyl record you can scratch
with the mouse, Serato style.

## Controls

**Bar**
- Left click: play/pause, or next track
- Right click anywhere on the widget: open/close the card
- Middle click: next track · Wheel: previous/next

**Card**
- Dropdown at the top: which player to follow (Auto = whatever is playing)
- Grab the record and move it: scratch. One turn = 1.8 s of audio (33⅓ rpm)
- Let go: the platter spins back up and the track carries on
- Wheel over the record: ±5 s · Click the progress bar: seek

## Files

| File | What it is |
|------|-----------|
| `manifest.json` | Plugin id, name, entry point (`BarWidget.qml`) |
| `BarWidget.qml` | Bar buttons, player selection, the right-click card, dropdown, transport |
| `Vinyl.qml` | The record: drawing, spin, tonearm, mouse handling, talks to the engine |
| `NeedleEvent.qml` | The "needle snapped" mini-game: stylus box, lid, drag the broken needle off and the new one on |
| `engine/scratchd.c` | Scratch audio engine (C). Keeps the last 30 s of what you hear in RAM and replays it at the speed/direction of your hand |
| `engine/scratch.sh` | Builds `scratchd` on first run, creates the silent scratch bus, wires everything to PipeWire (`pw-record` / `pw-play`) |
| `engine/route.sh` | Moves the player's audio to the scratch bus while you hold the record, and back |
| `engine/scratchd` | Compiled engine — built automatically, not in git |

State lives in `~/.local/state/gooozmen-music/`:
- `source` — selected player
- `needle.json` — needle state: `broken`, `wear` (turns since the last new needle), `count`
- `кладбище-игл.txt` — the needle graveyard: how many you've broken, the last
  victim's track, your rank (Аккуратист → … → Qbert отдыхает) and an epitaph

Tweak the feel in `engine/scratchd.c`: `TAU` (how tightly sound follows the
hand), `VEL_SMOOTH`, `MOTOR_TIME` (spin-up after release), `MAX_RATE`.
Change `secondsPerTurn` in `Vinyl.qml` for a faster/slower platter.

## Needle event

Scratch for a long time and the needle can snap: after 4 turns in one go,
every further turn has a small chance (0.5% growing to 4%, more as the needle
wears). You hear it skid, the tonearm jumps, and a stylus box appears:
click it open, drag the broken needle off the tonearm, drag the new one on.
The music keeps playing meanwhile — only the record is out of action.

**Shift + right click on the record** snaps it on purpose (to test or show
off). Edit `"broken": true` in `needle.json` to trigger it from the outside.

## How scratching works

Players (Spotify etc.) can't play backwards over MPRIS, so the engine does it
itself, the way xwax/Mixxx/Serato do:

- It always keeps the last 30 s of what you hear in RAM (never on disk).
- When you grab the record, the player is **not** paused: its audio is moved to
  a silent "scratch bus" (a null sink that exists only while the engine runs)
  and keeps playing there, so the buffer keeps filling with what comes next.
- A playhead chases the platter: the sound follows your hand's speed and
  direction, slides in pitch, and stops dead when your hand does. Hold the
  record still and the music falls behind, like real vinyl; push it and you
  can catch up — but not past live, there's no audio there yet.
- Let go: the motor spins the platter back up to 1x, the player is seeked to
  exactly where the record is and moved back to your speakers.

The timecode on the record and under it shows the record's real position in
the track while you scratch. The tonearm tracks the song: outer groove at the
start, label edge at the end.

## Install

```bash
omarchy plugin add https://github.com/gooozmen/music-vinyl-player.git --enable
```

Needs: `pipewire` (`pw-record`, `pw-play`, `wpctl`), `jq`, and `cc` (gcc) to
build the engine on first run — all present on a stock Omarchy install with
`base-devel`. Without a compiler the record still works, it just seeks instead
of scratching.

If the widget doesn't show up after a change: `omarchy restart shell`.
