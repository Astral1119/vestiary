# Repose — design record and handoff

Rewritten end of 2026-07-16 after the wallpaper-runtime convergence;
extended through 2026-07-17 (cover host → selection model → pixel look →
Instrument Serif resolution → agent-attention contract). Sections are a chronological decision
ledger — later entries supersede earlier ones where marked.
This is the canonical repose document; the earlier SwiftUI vertical-slice
plan is superseded (that day's spike verdicts remain valid and are kept
below). Sibling docs: [`../fresco/README.md`](../fresco/README.md)
(the runtime this all runs on) and
[`../fresco/FEASIBILITY.md`](../fresco/FEASIBILITY.md)
(WE + Livery integration, all four stages shipped).

## Surface model (v2, agreed)

Two products, one runtime, shared feeds (audio via cava, media via
media-control, agents via tmux `@agent_state`, theme via Livery
properties):

- **Desktop** — pure ambience, zero information: the bar owns signals
  while working. Catalog WE wallpapers, changing freely (gallery, panel,
  `fresco set`). An ambient variant of our composition is worth
  doing eventually; not critical.
- **Repose** — the stable cover-level composition at
  [`../fresco/repose/`](../fresco/repose/), authored
  as a WE-compatible web wallpaper (web is the medium now; the dev
  harness is the product — open `index.html` in a browser). Two variants
  switched by the `reposevariant` property:
  - **quiet** (default): the zephyr monolith — plaque odometer clock,
    `%a %F` date, agent dots + sentence, restrained strings, media
    footer. The book test: from across the room — time, music, agent
    state.
  - **loud**: performance — strings at center stage, clock small
    top-right (bar muscle memory), media forward. Auto-settles to quiet
    after three silent minutes.
  - Backdrop: graded-opaque default; `reposebackdrop: clear` for the
    future wallpaper-through cover stack (a wallpaper web view beneath
    the composition inside the cover window).

## Design record (still binding)

- **Book test**: one glance answers time / music / agent state.
- **Zephyr language** ("considerably better"): Material-role plaques,
  graduated hour ÷1.5 minute ÷2 second chips, chipless zero, odometer
  roll (500ms OutQuint); mono (SF Mono) favored over Cantarell.
- **No blended languages; no unixporn chrome**: no glass cards, plaques
  carry the structure; gradient confined to the visualizer; signal colors
  only where they mean something.
- **Strings baseline frozen**: `zephyr-strings/BASELINE.md` (pre-graduation history; the shipped `strings` visualizer carries the frozen geometry)
  (10 strands, shared endpoints, 12ms attack / 45ms release, soft rolling
  normalization). The JS port approximates it — see gaps.
- **Survey-derived** ([`../repose/RESEARCH.md`](../repose/RESEARCH.md)):
  centered monolith; grade-don't-blur; StandBy night tint; dim-then-fade
  entrance; settle-and-park (implemented); smoothstep minute pre-roll.
- **Spike verdicts** ([`../repose/SPIKE.md`](../repose/SPIKE.md), still
  valid for the cover host): non-activating key panel swallows input
  without Accessibility; no ffm drift beneath a cover; bar hide/restore
  clean; media keys pass through by mask omission.

## What needs work (the user's judgment: "repose will need some work")

Status 2026-07-16 (late session): items 1 and 2 of the original gap list
shipped — the accepted strings math is ported verbatim from
`ZephyrStringsPreview.swift` (rolling median-relative normalization
frozen in silence, 1.5-segment lateral spill, 1.85× vertical gain,
per-strand geometry/stroke/glow, dt-exact exp envelopes), and the grade
vignette, StandBy night tint (`reposegrade`/`reposenight` properties,
`s`/`n` dev keys, `?grade=`/`?night=` params), smoothstep minute
pre-roll (columns ease over the last 200ms of second 59;
`cubic-bezier(1/3,0,2/3,1)` is exactly p²(3−2p)), and a `[`/`]`
type-scale nudge (persisted, for judging from a chair) are in. The date
line now renders local time (was UTC via `toISOString`).

Second pass (same day, after the first live look — verdict: "needs
considerably more work; visualizer too wide, clock/viz separated,
agents/media missing, wants a wallpaper backdrop"):

- **Layout v2**: strings moved *into* the monolith at the accepted
  260×80 proportions (34vw × 10.5vw under the agent line), media line
  joins the stack — one column, no screen-wide band. Loud keeps strings
  center-stage fixed (78vw × 42vh) with media forward. Canvas is now
  retina-sharp (devicePixelRatio) and resizes via ResizeObserver.
- **Agents/media were missing on the cover because of a runtime bug,
  now fixed**: both feeds only emitted on change, so any freshly
  created webview started blank. AgentFeed/MediaFeed now cache last
  state; agent counts ride the pending properties and media payloads
  seed the bootstrap's `__weMediaLast`, so late-registering listeners
  replay. Desktop wallpaper switches got the same fix for free.
- **Wallpaper-through cover shipped** (smoke-tested): the cover panel
  hosts the *current desktop wallpaper* (video layer or a second web
  wallpaper instance, fed audio/Livery like the desktop copy) beneath a
  transparent composition webview (`reposebackdrop: clear`,
  `drawsBackground` off). Falls back to graded-opaque when idle or when
  the wallpaper is repose itself. The desktop copy pauses via
  occlusion while covered.
- **Dev harness wallpaper trials**: `w` cycles the Livery fixture walls
  (`?wall=` param, persisted) with the hyprlock grade recipe applied,
  so composition treatments can be judged over real imagery in the
  browser.

Remaining gaps:

1. **Composition treatments over real wallpapers** — legibility tuning
   now that the backdrop is imagery: plaque opacity, scrim strength per
   Look polarity, agent-line contrast. Judge in the harness over the
   fixture walls, then live.
2. **Book-distance verdict** — the scale nudge exists but the chair
   judgment hasn't happened; bake the chosen ×scale into the stylesheet.
3. **Loud variant is a layout, not yet a performance** — candidates:
   vendored butterchurn (Milkdrop), shader ports; must pass the taste
   gate.
4. **Extras** — the temporal-runway line (next boundary + battery) from
   COMPONENT-BANK Tier A is absent; needs a calendar/battery feed from
   the runtime (EventKit or `icalBuddy`; battery via `pmset`).
5. ~~Repose backdrop choice~~ — done: the `scene` axis of repose.json +
   the `scenes/` library (see Selection model below).

## Pixel look (qylock replication, 2026-07-17)

*(Partially superseded by the font-trial resolution below: the face is
now Instrument Serif with sentence-case labels, seconds are shown small
on the HH|MM baseline, and properties.local.json / repose-wallpaper are
gone — repose.json carries everything. The layout, per-scene themes,
and pixelated-strings treatment described here remain accurate.)*

Second language, switched wholesale via `reposelook: zephyr | pixel`
(project.json combo; harness key `k`, `?look=` param) — never blended,
per the design record. Anatomy replicated from qylock's pixel themes
(`Main.qml` of pixel-night-city/pixel-rainyroom): the scene is the star;
corner-anchored flat pixel type (Pixelify Sans, SIL OFL, vendored at
`repose/font/`), hours in `--text` / minutes in `--primary` split by an
`--attention` bar, seconds hidden (qylock-true; pre-roll still animates),
date beneath the clock as tiny wide-tracked uppercase with an accent
dash, square agent dots, hard offset shadows, no plaques. Strings render
at quarter-res upscaled with `image-rendering: pixelated` — chunky
pixel-art strands, thin, flat accents, no glow. Colors stay Livery
roles (qylock hardcodes per-scene palettes; our Looks derive them).

Eleven qylock pixel scene videos are staged at
`~/.config/fresco/qylock-bgs/` (third-party artists' work —
local trial only, never committed). The cover backdrop slot
(`fresco repose-bg <path-or-id|off>`, state file
`repose-wallpaper`) points repose at a dedicated scene without touching
the desktop wallpaper; `repose/properties.local.json` currently sets
`reposelook: pixel` for the trial — delete it (or set zephyr) to return
to the plaque language.

## Selection model (agreed 2026-07-17; **phase 1 built and smoke-tested
same day** — state record, refresh channel, scenes/ library, in-cover
keys, entry hint, fresco editors `repose`/`repose-bg`/
`repose-look`; migration off repose-wallpaper and properties.local.json
done. Live test: look flips and two in-place scene swaps on an open
cover without a blink. Phase 2, the panel Repose mode, is not started.)

User verdict on the pixel look: "looks great, significantly more
cohesive" — but selection/wiring is the gap: nothing on the live cover
is switchable except variant (harness keys are dev-only; any key exits
the real cover), and repose state is scattered across four channels
(properties.local.json look, repose-wallpaper file, CLI variant,
harness localStorage). Direction chosen: **in-cover keys** (the taste
instrument) + **Livery panel Repose mode** (the library instrument),
both over one core.

**Core — one state record + live refresh.**
`~/.config/fresco/repose.json`:
`{ look, scene, variant, grade, night }` where scene is `"desktop"`, a
path, or a workshop id. Replaces the scattered channels (fold
repose-wallpaper in; stop using properties.local.json for look).
`fresco` subcommands become editors of this record. A `refresh`
action on the existing SIGUSR2 command file makes the daemon re-read it
and apply live: look/variant/grade/night push as WE properties (the
composition already handles all four); a scene change swaps the
backdrop subview in place beneath the composition webview — no cover
blink. Cover closed → state simply applies at next entry. This also
closes the "not everything's wired" gaps by construction.

**Scene library = a directory.**
`~/.config/fresco/scenes/` — mp4s, WE project dirs, or
symlinks (qylock-bgs links in); plus the implicit "desktop" mirror
entry. Both pickers iterate the same library; the panel manages it.

**In-cover keys (phase 1).** Carve-out in the cover's event monitor:
`←/→` cycle scene, `⇥` cycle look, `v` variant, `g`/`n` grade/night —
each change applies live AND persists to repose.json (the picker is the
config). Every other key or click still exits. A dim hint line in the
current look's language shows for ~3s on entry, then fades.

**Panel Repose mode (phase 2).** Scene grid with thumbnails (video
first-frame, cached), look/variant/treatment controls, apply = write
repose.json + refresh. Workshop search results gain "add to repose
library" (workshop get → symlink into scenes/) — this is where the
"expand Livery affordances for WE browsing" thread lands.

Out of scope for both: the pixel-look alignment fixes (odometer column
metrics are SF Mono-tuned; Pixelify digits sit off-center; tracked
uppercase lines carry trailing letter-spacing) — separate treatment
pass, judged in the harness first.

Polish round (2026-07-17, after first live selection session): **esc is
now the only exit** (fat-finger protection; stray keys, clicks, scrolls
all swallowed — re-entry costs the cmd+alt-r chord). **Per-scene themes**:
`<scene minus ext>.theme.json` sidecars carry hex roles (text, textmuted,
primary, attention, viz1/viz2, …) pushed over the Livery Look whenever
that scene is up — moving to an unthemed scene restores Livery. All 11
qylock scenes have sidecars extracted from their QML palettes
(emerald is a light scene → dark text). Pixel look grew a small muted
seconds counter riding the HH|MM baseline, a more prominent date, and
finer strands (backing factor 0.25 → 0.4).

Alignment + fonts round (2026-07-17): odometer column metrics are now
per-font (`Pixelify .68em, Silkscreen .82, VT323 .48, Jersey .52` under
`body[data-font]`), the clock carries a small negative margin so its ink
edge lines up with the tracked lines below, and pixel gap tightened to
qylock's near-touching digits. Eight alternate pixel fonts vendored (all
SIL OFL, font/LICENSE.md), spanning genuinely different textures after
the first four read same-y: **Silkscreen** (blocky), **VT323** (thin
CRT), **Jersey 25** (rounded sibling), **Press Start 2P** (heavy NES
arcade, own size/width metrics), **DotGothic16** (Japanese dot-matrix),
**Sixtyfour** (C64 with scanline banding), **Micro 5** (skeletal
5-pixel), **Jacquard 12** (pixel blackletter, the wild card).
`font` joined the state record — in-cover `f` cycles it live,
`fresco repose-font`, harness `f`/`?font=`, `reposefont` property;
each font carries its own odometer column metrics.

**Backlog — visualizer modes** (user request): additional families
beyond the strings — the mockup harness trialed dial and bars; NCS/
Monstercat-style bar EQ suits the pixel look natively (quantized bars
are pixels already); butterchurn/Milkdrop or shader ports remain the
loud-variant candidates; Caelestia's separate Cava/Aubio services are
architecture prior art, not a pacing recipe. The researched shape below
supersedes this initial sketch.

### Visualizer research verdict + spectrum result (2026-07-17)

Research was deliberately front-loaded before adding another state axis.
The first implementation should expose only **`strings | spectrum`** on a
persisted `reposeviz` axis. Look and variant may choose a good initial default,
but do not silently rewrite an explicit visualizer choice. Quiet/loud remains
the placement and intensity axis; it is not a second visualizer taxonomy.
The radial dial from the old mockup does not earn a production slot: it loses
the left-to-right frequency reading without adding a new information shape.

Grounding constraints and prior art:

- [Wallpaper Engine's web audio contract](https://docs.wallpaperengine.io/en/web/audio/visualizer.html)
  is 128 frequency magnitudes at roughly 30 callbacks/sec: 64 left, then 64
  right. Our Cava host is already frequency-domain and mono; it mirrors the 64
  bars to satisfy that shape. Strings and a bar spectrum can consume this
  honestly. A shared JS analysis layer should derive normalized bands plus
  bass/mid/treble, energy, silence and adaptive positive spectral flux
  (`onset`); renderers should not each reinvent smoothing.
- [Caelestia](https://github.com/caelestia-dots/shell) validates the renderer
  shape, not the earlier claimed pacing blend: its background is a symmetric
  Cava bar field with frame-time exponential settling. Its separate Aubio
  service reads raw PCM and currently adjusts a media GIF's speed; it does not
  drive those bars. Borrow the analysis/rendering boundary and symmetric bar
  composition, not its QML/C++ or GPL implementation. With our magnitude-only
  feed, onset is credible; stable BPM is explicitly deferred.
- [Butterchurn](https://github.com/jberg/butterchurn) is the architectural fit
  for a later loud performance because it is WebGL2/JavaScript and MIT, but its
  normal API connects a Web Audio node and internally samples 1024 time-domain
  values before computing its own FFT. Feeding our 64 magnitudes would require
  fabricating phase or relying on internals. Do not do that. Revisit a single
  curated preset only after the runtime provides a raw PCM side channel, with
  WebGL2 capability/fallback and idle teardown measured in WKWebView.
- [projectM](https://github.com/projectM-visualizer/projectm) is the wrong
  first dependency: it is a native visualization library that owns audio
  analysis, tempo detection, preset equations and rendering, while Repose is
  already a web composition with a working audio path. It remains useful as a
  MilkDrop reference, not as the runtime for this phase.

Build order: (1) extract the current strings normalization into a shared audio
model without changing its frozen output; (2) add a mirrored, frequency-ordered
spectrum that can render smooth in zephyr and quantized in pixel; (3) use onset
only for restrained accent/transition timing after it proves stable; (4) judge
the two modes in quiet/loud over dark and light scenes before considering a raw
PCM channel or MilkDrop. No visualizer UI should land before that harness pass.

Spectrum pass shipped the same day. The shared model preserves the strings'
10-band rolling normalization and 12ms/45ms envelope while also maintaining a
24-band spectrum view. Spectrum mirrors the frequency order around a narrow
center break (bass inward, treble outward): rounded, softly glowing bars in
zephyr; quantized square bars in pixel. Quiet remains compact in the monolith;
loud occupies the accepted 78vw × 42vh performance field. The harness pass
covered both Looks and both variants over the moonlit-ocean fixture and caught
one pre-existing cascade bug: pixel's compact width had been overriding the
loud visualizer width. The explicit axis is now live and persistent as
`reposeviz` / `repose.json.viz`, cycled by in-cover `b` or edited with
`fresco repose-viz strings|spectrum`. Strings remain the migration default.

Strings-freeze fix (2026-07-17, user report "sometimes the strings just
stop working"): two hardening layers. Runtime: the cava tap gets a
watchdog — cava emits frames continuously (zeros in silence), so 15s of
silence from a running process means the CoreAudio tap died (typically
an output-device switch, e.g. AirPods); the tap relaunches itself, and
also on process exit. Composition: the draw loop uses chain tokens — if
`animating` is stuck true but nothing has drawn for 2s (webview
suspension mid-animation), wake() arms a fresh chain that supersedes
the stranded one. Watch for recurrence; if it still freezes, the next
suspect is the WKWebView JS clock during panel occlusion.

Font trial resolved (2026-07-17): 13 faces trialed (9 pixel + 4
non-pixel pairings); **final verdict: Instrument Serif** — the serif
display face is now baked in as the pixel look's type (sentence-case
labels, .12em tracking, .5em odometer columns). The font axis, `f`
keys, `repose-font`, `reposefont` property, and the trial scaffolding
are all removed; only InstrumentSerif-Regular.ttf remains vendored.
The freed state slot became **`pixels`**: `reposepixels on|off`
toggles the strings between chunky quarter-res upscale and smooth
retina rendering — in-cover `x`, harness `x`, `?pixels=off`. Media
line now **truncates and scrolls** (marquee: hold → drift to the end →
hold → drift back; pace scales with overflow) instead of ellipsizing;
budgets 34vw quiet / 70vw loud re-measure on variant switch; harness
`m` cycles short → long → off (`?media=long|off`).

## Agent attention and routing (agreed 2026-07-17)

The count anomaly is resolved; the larger attention model is designed but not
built. This section is the canonical pickup point for that work.

### Count diagnosis and fix — shipped

The Repose feed used `tmux list-panes -a -F '#{@agent_state}'`. The five
grouped cockpit sessions expose the same linked windows and physical panes once
per session, so the runtime multiplied every state by five. The feed now asks
for `#{pane_id}|#{@agent_state}` and folds by the server-wide pane ID before
counting. `WallpaperRuntime.swift --self-test-agent-counts` carries a grouped
fixture and is run by the full Livery validation; the daemon was rebuilt and
the validation passed. This fixes the Repose total without redefining what an
agent state means.

SketchyBar is a different projection today: `agent_watch.lua` derives unique
waiting/done *spaces* and a count of working terminal windows from yabai titles.
Those values therefore should not be expected to match Repose's physical-pane
counts. One adjacent grouped-session bug remains: its tmux bell query still
uses `tmux list-windows -a`, so linked sessions can multiply bell flags.

### Provider lifecycle audit

Audited against Codex CLI 0.144.5 and Claude Code 2.1.212 plus their current
official hook references ([Codex](https://learn.chatgpt.com/docs/hooks.md),
[Claude](https://code.claude.com/docs/en/hooks)). Both clients write the same
pane-local `@agent_state` through
`~/.config/claude/hooks/agent-state.sh`.

- **Codex is mostly conservative and correct.** `SessionStart` matches only
  startup/resume/clear (not compact); prompt and post-tool mean working;
  `PermissionRequest` means waiting; `Stop` means done. Codex exposes no
  `SessionEnd`, so the zsh `precmd` hook clears state when the CLI returns to
  its parent shell. With `approval_policy = "never"`, waiting will naturally
  be rare. A final response that asks a conversational question still appears
  as done because there is no deterministic separate hook for that meaning.
- **Claude's current adapter is too broad.** Its unfiltered `SessionStart`
  includes compaction and can temporarily reset an active turn to idle. Its
  unfiltered `Notification` maps every notification to waiting, including
  `auth_success`, `idle_prompt`, and elicitation completion/response—not just
  permission prompts and active elicitation dialogs. It also does not handle
  `StopFailure`, so an API-failed turn can remain working. Claude does have a
  real `SessionEnd`, and that cleanup is already wired.
- **Neither current adapter tracks review acknowledgment.** Today `done` means
  only "the last turn stopped." It does not prove the result is unread, and it
  never becomes complete merely because the user looked at it.

### Canonical state model

Do not extend the single string enum until these three independent axes are
represented:

| Axis | Values |
| --- | --- |
| Execution | working, blocked, stopped |
| Attention | unseen, seen |
| Lifecycle | open, closed |

The user-facing concepts are projections:

- **waiting** = blocked + open. Rare, urgent, explicitly requires input.
- **review** (the current `done`) = stopped + unseen + open. The turn finished
  and its result has not been acknowledged.
- **parked** = stopped + seen + open. Reviewed, still available, no current
  demand.
- **complete** = closed. The work has been reviewed/moved past and should leave
  live attention surfaces rather than persist as another badge.

Expected transitions: `Stop` → stopped/unseen; selecting the exact tmux pane
while its terminal is frontmost, preferably with a short dwell, may mark seen;
the next `UserPromptSubmit` definitely marks the previous result seen before
returning to working; `/clear`, session end, pane death, or explicit archive
closes it. Focus alone must never imply complete.

### Surface split

**Repose is the global ambient view, independent of macOS spaces.** Show
aggregate working activity, make rare waiting visually forceful, and keep a
persistent review signal whose age matters more than a decorative raw total.
Parked should be absent or very subdued. Complete may produce a brief fade/pulse
but should not remain in the live composition.

**SketchyBar is a global agent inbox plus a spatial rail.** The space numbers
and app icons continue to answer where macOS windows live. A cockpit space may
receive a coarse location mark (or a strong tint for true waiting), but it
cannot identify the agents inside one tmux window. `smart_now` should stop
listing agent-bearing space numbers and instead name the next actionable
context: `✳ tutor`, `✳ tutor +2`, `● livery +3`. Bare numerals remain reserved
for spaces; a count-only fallback must use explicit multiplicity (`✳×2`) or a
word (`4 reviews`). Working can be a subdued animated glyph without a number.

Clicking an inbox item routes to a context, not just a space: focus the macOS
space and terminal window, select the appropriate attached tmux client/session,
then its window and pane. Repeated clicks may cycle the matching queue;
right-click or a key opens the full picker. The picker owns transient `1–9`
shortcuts, context name, provider, state, age, and route. Tmux's status line and
picker remain the local context map. Stable "agent space numbers" do not.

### Likely implementation boundary

Pane options remain a useful fast projection but should not be the durable
source of truth. Both hook payloads expose provider session IDs; a shared
registry keyed by provider + session ID should retain execution, attention,
lifecycle, timestamps, and the current tmux route. A small interface such as
`agentctl status --json`, `agentctl focus <id>`, and `agentctl acknowledge
<id>` can feed Repose, SketchyBar, and tmux from one inventory. This also lets a
context survive pane recreation and makes grouped sessions an explicit routing
concern instead of an identity problem.

Build order: correct Claude's event matchers and failure transition; specify
and build the registry/router; add acknowledgment without inferring completion;
then migrate `agent_watch.lua`/`smart_now.lua` and Repose to the shared feed.
Fix grouped bell folding along the way. Do not redesign the bar around the
current title-scraping payload—it cannot expose per-context identity inside
tmux.

## Lock screen split (user ask, 2026-07-17)

User: live-effect WE wallpapers look bad on the macOS lock screen — the
lock screen shows them frozen. The runtime today has zero lock
awareness: no `com.apple.screenIsLocked` handling, and it never touches
the macOS system wallpaper, so the desktop-level window stays composited
behind loginwindow with rendering stopped → frozen mid-frame. Wanted:
**separate wallpapers for desktop and lock screen**. Two candidate
mechanisms (verify which one actually controls what the lock screen
composites before building):

1. **Hide on lock**: daemon listens to DistributedNotificationCenter
   `com.apple.screenIsLocked` / `screenIsUnlocked`, orders the desktop
   windows out on lock and back in on unlock — the lock screen then
   shows the static system wallpaper, which the user picks freely.
   Cheapest; "separate lock wallpaper" = System Settings.
2. **Swap on lock**: same notifications, but swap the desktop surface to
   a dedicated lock scene (`fresco lock-bg <scene>`, new channel
   in repose.json) — keeps runtime content on the lock screen (a still
   or a scene that reads well paused). Watch for a flash at lock-engage;
   notification timing vs. the lock snapshot is the open question.

## Lock image in Livery — shipped 2026-07-17

liveryctl now has a first-class **lock image** concept; `fresco
lock-bg` stays the low-level actuator. Grounding facts: the store's
Desktop slot is only visible while locked (runtime covers the desktop);
`apply_wallpaper_for_target` writes the theme still into that slot on
every `livery apply`; rollback restores whole store snapshots;
`sync_live_wallpaper` already bridges liveryctl → fresco.

Implemented decisions:

1. **Surface**: `livery lock <image>|scene:<name>|theme|off|status`.
   `theme` = follow the current profile still (today's behavior, the
   default); an explicit image pins the lock across theme switches.
2. **Storage**: global, not per-profile — `$RUNTIME_ROOT/lock.json`
   `{image, source: file|scene|theme, updatedAt}` (or state.json
   schema bump). Mental model: "my lock wallpaper" survives theme
   churn. Per-profile overrides (manifest `outputs.lock`) are a later
   layer.
3. **Apply semantics**: `apply_wallpaper_for_target` becomes
   lock-aware — pinned lock image wins the store slot; the theme still
   is what `lock theme` restores. No pin → exactly today's behavior.
4. **Rollback semantics**: lock is orthogonal to theme rollback —
   after the store-snapshot restore, re-assert the pinned lock image.
5. **Runtime-down trade-off (accepted)**: daemon stopped ⇒ desktop
   shows the lock image. Static and fine; no lifecycle hooks.
6. **Derivations**: `scene:<name>` = ffmpeg frame-grab from
   `~/.config/fresco/scenes/`. Graded/night variants of the
   still so the lock matches the Look remain panel-era jam material.

Shipped after pickup: `livery lock [status]`, `<image>`, `scene:<name>`,
`theme`, and `off`; global schema-v1 state at
`~/.config/livery/lock.json`; content-addressed ffmpeg scene stills under
`~/.config/livery/lock/scenes/`; pinned file/scene images override normal
Look wallpaper application and are reasserted after rollback. `theme` is an
explicit follow-current-Look policy; `off` removes lock-specific state without
changing the store immediately. Dry-run regression coverage exercises apply,
rollback, scene extraction, theme-follow, and off. The WallpaperEngine stayed
unchanged. The existing low-level `fresco lock-bg` remains useful as an
unmanaged actuator, but `livery lock` is now the durable interface.

**UI jam seeds (pickup session)**: lock picker beside the theme picker
in the Livery panel; "use this scene as lock" from inside the cover;
scene thumbnails from the library; per-theme lock overrides; where
scene keep/kill curation lives (same panel phase-2 surface as the
Repose mode grid).

## Wallpaper sourcing (for the backdrop catalog)

- **WE Workshop** is the deep catalog and the plumbing already exists
  (`workshop get`, `fresco set <id>`, panel search + gallery).
  The affordance gap is *discovery*: the panel searches by query only —
  trending/top-rated/tag browsing (Workshop's `browse/?appid=431960`
  sort modes) would make it a real catalog browser.
- **Direct-MP4 sites** need no WE at all (the runtime plays video
  natively): moewalls.com, motionbgs.com, mylivewallpapers.com.
- **Ricing ecosystems** are design-pattern sources, not wallpaper
  sources: qylock (already mined — odometer + smoothstep pre-roll),
  caelestia (settle-and-park, exit choreography), end-4 dots-hyprland,
  Noctalia. Worth mining again when composition treatments resume.

## Cover host (shipped 2026-07-16, smoke-tested; esc-only since 07-17)

The runtime grew the cover-level window kind per the spike verdicts:
`WebHost` takes a `surface` (`.desktop`/`.cover`); the cover is a
non-activating key `NSPanel` at `.screenSaver` level. A local event
monitor owns input: **esc is the only exit** (superseding the original
any-key-exits); selection keys act (see Selection model); stray keys,
clicks, and scrolls are swallowed; media keys are systemDefined and
pass through untouched. Entry hides the bar, exit restores it (also on
daemon shutdown), covers fade out 250ms, and the web layer runs a
dim-then-fade entrance on load. Covers receive the audio/agents/media
feeds and Livery-role pushes (with per-scene theme overrides). Entry:
**`cmd+alt-r`** (skhd) → `fresco repose` → `repose-command` +
SIGUSR2.

## Current state (end of 2026-07-17 session)

- `cmd+alt-r` toggles the cover; esc exits. In-cover: `←→` scene,
  `tab` look, `x` pixels, `v` variant, `g` grade, `n` night, `l`
  scene-name label — live, persisted to
  `~/.config/fresco/repose.json`.
- **Scene-name label (2026-07-17, for narrowing the 25-scene library)**:
  small muted name bottom-right, fed by new `reposescene` (name) +
  `reposelabel` (on|off) properties from the state record; state axis
  `label` (default on), `fresco repose-label on|off`, in-cover
  `l`. The ctl/property channel is the hook a Livery panel toggle
  would use later. Built as an axis, not a debug hack — flip it off
  when the narrowing is done.
- Looks: **zephyr** (plaque odometer, SF Mono, Livery-colored) and
  **pixel** (qylock bones + Instrument Serif voice, per-scene themes,
  pixelated-or-smooth strings). User's current resting state: pixel,
  dusk-city scene, grade off.
- Scene library: `~/.config/fresco/scenes/` (11 qylock mp4
  symlinks + theme sidecars; add anything, arrows pick it up).
- Hardening in place: agent/media state replay to new webviews, cava
  watchdog (device-switch deaths), chain-token draw loop, media
  marquee, esc-only exit.
- Known bug (unchanged): WE preset bundled-files path rewrite missing.
- **Audio-tap TCC is attribution-dependent (diagnosed and hardened 2026-07-17)**:
  System Audio Recording (kTCCServiceAudioCapture) is charged to the
  *responsible process* at the top of the spawn chain, not to cava.
  Grants exist for cava and tmux (path-keyed, added 2026-07-15); skhd
  and the daemon binary have none, and ghostty only has Microphone
  (a different service). So a daemon started from a tmux shell taps
  fine, but one started via skhd (`cmd+alt-r` after the ctl's
  stale-binary restart) is denied — and since a CLI process can't
  show a permission dialog, macOS silently opens the Settings pane
  instead; the old 10s watchdog loop made that "keeps opening System
  Settings". The daemon now preflights capture without prompting and skips
  Cava when permission is absent. More importantly, daily-driver starts put
  the mutable renderer beneath the frozen, signed
  `~/Applications/Wallpaper Runtime.app` host (bundle ID
  the pre-rename wallpaper-runtime bundle id). Grant that app once under System Settings
  > Privacy & Security > Screen & System Audio Recording; ordinary renderer
  rebuilds never touch the host signature, so they retain the grant. Both
  LaunchServices starts and the optional launchd agent use this same responsible
  app. `fresco audio-permission` reports the exact permission owner.

## Roadmap (ordered)

1. **Livery/Repose UI — SHIPPED 2026-07-17.** Repose is a top-level
   workspace (`cmd+2`). After a live correction pass, it is an ordered rotation
   editor rather than a second live picker: the stable library grid toggles
   membership, the draggable filmstrip defines arrow-key order, and `NOW` is
   read-only. `scenePool` stores stable scene IDs; absence migrates to every
   catalog scene in the old deterministic order. Composition controls stay
   inside the cover. Live WE items in the Livery library have an additive “add
   to repose” action; no keep/remove/kill UI exists. Lock stays outside Repose:
   the Look footer offers normal apply and exact rendered “lock only” targets,
   backed by a content-addressed cached artifact. The header's compact global
   theme/pinned/unmanaged policy control uses Livery chrome rather than a
   native menu. This supersedes the earlier design-only gate below.

   Drag follow-up: borderless-window background dragging is disabled. The
   header alone carries `WindowDragGesture`; the rotation cards use a direct
   high-priority horizontal gesture and commit their stable-ID order on end.
   A live drag was verified through `repose.json`, then the original order was
   restored. This avoids SwiftUI's file-style drag/drop ambiguity and prevents
   the filmstrip gesture from moving the whole panel.

   Earlier design record: **Livery/Repose UI design first — sketch, do not build yet** (user
   correction 2026-07-17). Think through the workspace model, scene
   selection, treatment controls, lock picker, “use this scene as lock,”
   and Workshop/library relationship before touching SwiftUI. Scene
   keep/kill is explicitly deferred; design around the full current set
   without turning that into a curation decision.
   Follow-up decision: Repose controls should apply immediately, matching
   the existing in-cover keys (write `repose.json` + refresh when open;
   persist for next entry when closed). Do not add a staged Apply footer.
   Lock is orthogonal, not a Repose treatment: its primary UI should be an
   explicit “set as lock” action on the selected library wallpaper. A scene
   detail may eventually offer the same contextual action using its derived
   still, but lock policy does not belong in the Repose control stack and
   does not need its own top-level workspace. Keep a compact global lock
   status/policy affordance for `theme` / pinned / unmanaged.
2. **Lua specimen color contract — AUDITED + FIXED 2026-07-17.** It remains
   an illustrative syntax map, not a claim to reproduce Ghostty's syntax
   grammar. Token colors use resolved ANSI slots, while the rendering surface
   now carries explicit terminal background/foreground, Ghostty opacity, and
   minimum contrast. The representative cell background composites terminal
   background over sampled wallpaper color before the contrast fallback.
   Generated and imported palette records now expose those fields; old runtime
   records follow the resolver's documented wallpaper-theme defaults.

   Original audit note: Current implementation hand-assigns tokens to ANSI slots, but
   carries UI background/text in `ThemePalette`, uses a hard-coded 50%
   backdrop tint, and contrast-checks against the opaque UI background.
   The semantic contract has separate terminal background/foreground,
   ANSI, opacity, and minimum-contrast roles. Confirm the intended
   specimen (actual Ghostty rendering vs. illustrative syntax map), then
   make the data path honest as part of the eventual UI build.
3. **Lock screen split + durable Livery policy — SOLVED 2026-07-17,
   awaiting the user's image pick.** Diagnosis: the lock screen mirrors the *system* wallpaper,
   which Livery sets to a still of the current theme — the "frozen
   live wallpaper" was that still. Since the runtime covers the
   desktop, the system wallpaper is only ever visible while locked, so
   the store's Desktop image IS the lock slot. Shipped:
   `fresco lock-bg <image>` (drives Livery's
   `livery-wallpaper-engine apply-global`; `theme` restores the
   current profile still; bare prints status). Hide-on-lock also
   shipped (screenIsLocked/Unlocked → hide+pause desktop hosts, exit
   open cover, restore on unlock) — right thing for power either way.
   Also fixed en route: `fresco stop` now waits for the daemon
   to exit (restart race left it dead). The clobbering caveat is closed:
   `livery lock <image>|scene:<name>|theme|off` owns durable global policy,
   and pinned images are reasserted by Look apply and rollback. Scene inputs
   are cached as representative PNG stills with ffmpeg.
4. **Rest of the qylock themes — ambient batch STAGED 2026-07-17;
   keep/kill deferred.** 25 of qylock's 37 themes now in the scene
   library: 11 pixel + 12 ambient + both Reverse:1999 (user-requested
   test — reverse1999-1/-2, native mp4s, sepia-gold Cinzel palettes)
   (dog-samurai, enfield, forest,
   last-of-us, sword, winter native mp4s; field, girl-coffee,
   girl-pillow, man-bicycle, material-you, women-umbrella were still
   PNGs, converted to 4s loop mp4s — runtime is video-only). Sidecars
   hand-tuned from each theme's Main.qml palette; the six converted
   ones are LIGHT scenes with dark-ink text roles — first real test of
   light-scene legibility. Not staged (deliberate): clockwork +
   nothing (pure QML, no background) and the game/gacha recreations
   (Minecraft, osu!×2, Terraria, Ninja Gaiden, Windows 7, Genshin,
   Star Rail, NieR, Reverse:1999 ×2, WuWa) — their look lives in the
   QML chrome, not the backdrop; look-mining material for future
   looks. Same rules as qylock-bgs: third-party art, local only,
   never commit. Follow-ups pending verdict: native image-scene
   support in the runtime (drop the loop-mp4 shim), and the user
   wants to think about **broader Livery integration** — per-scene
   sidecars currently override Livery roles; the open question is the
   reverse direction (scenes feeding/being fed by Looks properly).
5. **Agent attention/state v2 — DESIGNED; count bug FIXED 2026-07-17.**
   Repose now folds grouped tmux sessions by physical pane ID and has a
   regression test. The next work is the shared provider-session registry,
   lifecycle corrections (especially Claude compact/Notification/StopFailure),
   review acknowledgment, context router, and global-inbox SketchyBar
   projection. Bare numbers remain spatial; see **Agent attention and
   routing** above for the binding model and build order.
6. Treatment/legibility pass over real scenes + book-distance verdict
   (`[`/`]` nudge, bake the ×scale); consider renaming the look axis
   (the "pixel" look is now serif-voiced — names have drifted).
7. **Visualizer modes — SPECTRUM SHIPPED 2026-07-17.**
   `reposeviz: strings|spectrum` runs over a shared magnitude/envelope model. Onset remains
   the next analysis experiment; Butterchurn
   remains a later loud-only experiment after a real raw-PCM feed; projectM is
   reference material, not a phase-one dependency. See the verdict above.
8. Extras line (next boundary + battery; EventKit/`icalBuddy` + `pmset`
   feeds).
9. Preset bundled-file rewrite (known bug, item 3380416096).
10. WKWebView-snapshot frame source; `workshop config` property UX;
   panel polish; Scene (.pkg) renderer; ambient desktop variant.

## Suggested next-session prompt

> Pick up agent attention/state v2 from `desktop-scenes/HANDOFF.md`, especially
> **Agent attention and routing**. The grouped-tmux Repose count bug is already
> fixed and validated. Preserve the three-axis execution/attention/lifecycle
> model: waiting is a rare explicit block, review is stopped + unseen, parked is
> seen but open, and complete leaves the live set. First correct the Claude hook
> mappings, then design/build the provider-session registry and context router
> before changing SketchyBar. Repose is the global ambient projection;
> SketchyBar is a global inbox plus a spatial rail; tmux is the local context
> map. Reserve bare numbers for macOS spaces, use context names + overflow in
> the inbox, and never infer complete from focus alone. Read
> `sketchybar/WORKFLOW.md`, `~/.codex/hooks.json`, `~/.claude/settings.json`,
> and `~/.config/claude/hooks/agent-state.sh` before editing.
