# Repose cover-spike: mechanics verification

**Verdict (2026-07-16): both modes passed with no felt difference, so the
simpler one wins — `--mode key` (non-activating key panel, no
Accessibility requirement) is the architecture for the vertical slice.
The event tap remains a documented fallback.**

A disposable, instrumented full-screen cover — no scene, no strings. It
exists to answer the platform questions beneath the repose design
([`../desktop-scenes/HANDOFF.md`](../desktop-scenes/HANDOFF.md)) before the
composition is built, and to pick between the two candidate architectures:

- **`--mode tap`** (default): the cover never becomes key and never
  activates; an active CGEventTap consumes keyboard input. Focus is never
  disturbed, so exit restores nothing. Requires Accessibility for the
  launching terminal.
- **`--mode key`**: a non-activating panel (Spotlight-style) takes key
  status and receives keys directly. No permissions, but key status moves,
  so exit-time behavior needs scrutiny.

The platform wrinkle that forces this choice: NSEvent *global monitors can
observe keystrokes but cannot consume them* — a never-key cover without a
tap would leak every keystroke into the hidden focused window.

## Running

```sh
./run              # tap mode
./run --mode key   # key-window mode
```

The cover appears after 2 seconds and auto-exits after 120 seconds
(`REPOSE_SPIKE_AUTO_EXIT` overrides). Any key or click exits; after each
exit a report prints, then Enter re-enters and `q` quits.

Safety notes:

- In tap mode the keyboard is consumed while covered, including Ctrl-C in
  the terminal. Click to exit, or wait for the auto-exit.
- If the spike dies uncleanly the bar stays hidden: `sketchybar --bar
  hidden=off` restores it.
- If tap creation fails, the HUD says so loudly and keys pass through to
  hidden windows; grant Accessibility (System Settings → Privacy &
  Security → Accessibility) to the terminal that launches `run`.

## Checklist

Record each outcome; together they choose the architecture and settle the
handoff's "verify rather than assume" items.

Input swallowing:

- [ ] Type freely while covered, then exit and check the previously
      focused window (leave a terminal focused): **no characters arrived**.
- [ ] Click several times before exiting intentionally: nothing beneath
      reacted, no window was raised.
- [ ] With music playing: play/pause, skip, and volume keys **work without
      exiting** (tap mode taps only keyDown/keyUp; NX_SYSDEFINED is never
      tapped).
- [ ] `ctrl+1..9` while covered: does the Space switch, or is it consumed
      before skhd sees it? (Both taps are head-inserted; creation order
      decides. Either result is fine — record which.)

Focus and activation:

- [ ] Exit report: `focus preserved: YES`.
- [ ] Exit report: `app ever activated: no` (both modes — the key-mode
      panel is non-activating).
- [ ] HUD during cover: wave the mouse across regions where windows sit
      beneath. `focus drift` stays `none observed` → focus-follows-mouse
      does not reach beneath the cover and needs no suspension. If drift
      appears, production must suspend ffm like the popup contract.
- [ ] After exit, hover between windows: ffm/autoraise behave normally
      with no dead first-transition (the Livery panel quirk).

Layout and chrome:

- [ ] HUD line: cover windows invisible to yabai, or listed but floating;
      bsp layout unchanged after several enter/exit cycles.
- [ ] Bar hides on enter, returns on exit.
- [ ] Both displays covered if two are attached (single-display is the
      shipping target; this is informational).

Mode comparison:

- [ ] Run both modes through the list above. Prefer tap mode if it passes
      cleanly (zero focus movement by construction); fall back to key mode
      if Accessibility friction or tap flakiness shows up.

## Out of scope

Composition, wallpaper backdrop, agent state, media metadata, entry
keybind — all belong to the mockup phase and the vertical slice, not this
spike.
