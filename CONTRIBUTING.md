# Contributing

Vestiary is a macOS umbrella repository. Changes should preserve the optional
boundaries between theming, wallpapers, and desktop state. A missing theme or
state contract must not stop a consumer from starting with its own defaults.

## Start here

Read the README for the subsystem you are changing. Read
[`contract/SPEC.md`](contract/SPEC.md) before changing the theme manifest or
adapter interface. Read [`livery/ARCHITECTURE.md`](livery/ARCHITECTURE.md)
before changing Look resolution, transactions, or wallpaper convergence.
Recent `git log` is the re-entry point for what a subsystem is currently doing.

Inspect `git status` before editing. The repository may contain live experiments
or generated test state that belongs to another workstream.

## Bounded agent work

Agent work is authorized one bounded item at a time. A plan must name the
deliverable, blockers, acceptance checks, and terminal condition. Reaching the
terminal condition ends the turn. The next roadmap item requires new
authorization.

Keep orchestration shallow. The coordinating agent may delegate to at most two
workers unless the user approves a wider pass. Workers do not create more
workers. Assign implementation and independent review separately when both are
needed.

Wait for agent events in intervals of at least five minutes. Repeated short
polls are not progress. After two consecutive waits, either do useful local
work or continue with one longer wait. A 2026-07-22 run made 62 agent polls in
45 minutes. Parent token accounting increased by 18.6 million tokens for about
8,000 output tokens during that interval. Routine actions later carried
150,000–215,000 input tokens each.

Stop and write a handoff when a routine action exceeds 100,000 input tokens,
when a stage closes, or when the session requires repeated compaction. Resume
in a fresh session. The handoff records completed work, intentional source
scope, verification results, evidence identities, open limitations, worktree
exclusions, and the next single bounded item. It does not reproduce the
transcript.

Verification has one owner per layer. The implementer runs focused checks. An
independent reviewer tests the claimed boundary. The coordinator runs only the
remaining integration check. A review gets one revision cycle before returning
to the user. Development evidence stays replaceable; only accepted evidence is
preserved as an immutable lineage.

## Repository layout

| Dir | What |
|---|---|
| `contract/` | The public theme API: manifest schema and normative specification. |
| `adapters/` | One executable per themed application, implementing the stable adapter verbs. |
| `integrations/` | Direct consumers that watch the active semantic manifest and use an application API. |
| `livery/` | The Look engine, native panel, catalogs, image pipeline, and transaction orchestrator. |
| `livery.nvim/` | The Neovim consumer plugin, paired with `adapters/nvim`. |
| `fresco/` | The live-wallpaper runtime and shipped Repose composition. |
| `fresco-scene/` | The separately licensed Wallpaper Engine scene helper and its pinned upstream source. |
| `herald/` | The state bus and publisher helper. |
| `repose/` | Native cover-host experiments and composition mockups. |
| `tabard/` | The resident on-screen display and command wrapper. |

## Development setup

The required development environment is macOS with `jq` and the Xcode Command
Line Tools. Optional integrations require their corresponding applications or
commands. `./install` reports the complete dependency set.

```sh
./install --no-wire
```

The installer fetches the pinned Matugen binary when needed and places command
shims under `~/.local/bin`. `--no-wire` leaves application configuration files
unchanged. Run `./install --wire` only when you intend to add loader entries for
installed consumers. `./install --with vscode` packages and installs the
reference extension when both `code` and `npm` are available.

Fresh installs write `~/.config/vestiary/targets.json`. CSS is enabled without
host detection. Detected application adapters require individual confirmation,
or `--enable-detected` in a non-interactive install. `--disable-detected`
records only CSS. Existing installations without a target file retain the
legacy all-adapters default until the user creates one.

Installer-owned resources are recorded in
`~/.config/vestiary/install-receipt.json`. Receipt schema version 1 tracks
exact command shims, appended loader lines, managed configuration files and
their original backups, and editor extensions installed by Vestiary. A
pre-existing extension or already-working loader is not adopted. Repeated
installs update owned resources without taking ownership of new integrations.

## Setup planning contract

`./install --plan` emits setup plan schema version 1. Planning is read-only.
The plan reports compatibility, prerequisites, integration detection, current
selection, permissions, state paths, and proposed actions.

The embedded `selection` object is also a standalone input to
`./install --apply`. Setup selection schema version 1 contains enabled adapter
IDs, one loader-wiring boolean, and the managed Visual Studio Code boolean.
CSS is required. Apply rejects unknown or duplicate adapters and unavailable
selected prerequisites before writing target selection. Matugen acquisition is
reported in the plan and checked again on the applying machine because a
selection may be moved between Macs.

```sh
./install --plan > /tmp/vestiary-plan.json
jq '.selection' /tmp/vestiary-plan.json > /tmp/vestiary-selection.json
./install --apply /tmp/vestiary-selection.json
```

`./uninstall --plan` emits uninstall plan schema version 1. Each receipt
resource has a proposed operation and an outcome of `planned`, `preserved`,
`blocked`, or `unchanged`. `--keep-integrations` and `--purge` can be combined
with planning and produce the same policy preview used by the destructive
command.

For a second-machine validation, retain the install plan, applied selection,
and uninstall plan. Confirm the chosen Look and each selected integration.
Detach the Visual Studio Code extension before the final uninstall preview.
Run the default uninstall first and verify that Livery and Fresco data remain.
Use `--purge` only when the retained plan shows the exact intended data roots.

## Current setup limits

A detected and enabled application needs a working loader. Livery does not yet
provide a command that edits `~/.config/vestiary/targets.json` after setup.

The checked-in `default` profile is the project's captured color baseline.
First application captures the machine's wallpaper state for rollback, but it
does not derive a theme from the machine's application configurations.

The minimum supported macOS release has not been established. The build does
not set an explicit deployment target.

## Verification

The repository-wide validation command compiles the Swift surfaces, checks
shell and Python entry points, validates the checked-in catalogs and schemas,
and exercises Look resolution in temporary runtime roots.

```sh
livery/tests/validate.sh
```

The validation currently expects an installed development system with the
default Ghostty, SketchyBar, yabai, and macOS wallpaper files present. It hashes
those files before and after the run to verify that validation did not change
them. Use focused syntax, type, or subsystem checks on an unconfigured machine.

Generated catalogs must reproduce byte-for-byte:

```sh
livery/generate-themes
git diff --exit-code -- livery/themes.json
```

Adapter discovery, selection, conformance, CSS output, and the Visual Studio
Code entry point have a focused check that does not compile the native
surfaces:

```sh
livery/tests/adapters.sh
livery/tests/desktop-sync.sh
python3 fresco/tests/workshop_test.py
sh fresco-scene/tests/validate.sh
setup/tests/install-state.sh
```

## Change boundaries

The contract is additive within a major version. Public roles are not removed,
renamed, or rebound. New roles declare a fallback to an existing role.

Adapters implement the four stable verbs `render`, `validate`, `reload`, and
`loader-check`. The orchestrator discovers executable files on its adapter
search path; it does not carry a target registry. Run `livery adapter-check`
before proposing an adapter.

Direct consumers watch `~/.config/livery/current/manifest.json`. They are not
part of the adapter transaction and must tolerate an absent or temporarily
unreadable manifest. A consumer that writes application settings must track its
owned keys and provide a non-destructive detach path.

Vestiary ships integration mechanisms. Personal application policy, state
publishers, and loader configuration remain outside the repository.

## Runtime and rollback

Livery contract and profile state lives under `~/.config/livery/`. Fresco state
lives under `~/.config/fresco/`; `~/.config/wallpaper-runtime` remains a
compatibility symlink. Reapplying the current Look repairs rendered targets.
`livery rollback` restores the previous Look and wallpaper-store snapshot.

Fresco runs its mutable worker beneath `~/Applications/Fresco.app`. The frozen
host preserves the Screen & System Audio Recording identity across worker
rebuilds. Run `fresco audio-permission` for the current grant procedure.

`./uninstall` uses the install receipt and preserves runtime data. It removes
only unchanged owned files and restores verified backups. A modified owned
file remains installed and stays in the receipt. `--keep-integrations`
preserves loader wiring and editor extensions. `--purge` additionally removes
the exact Vestiary, Livery, and Fresco configuration roots.

The Visual Studio Code extension writes its attachment status to
`~/.config/vestiary/integrations/vscode.json`. Uninstall refuses to remove the
extension while that record says it owns attached colors, or when the record
is unavailable. The user must run **Vestiary: Detach and Restore Colors** in
Visual Studio Code first.

## Writing

Public documents use standard capitalization. Lead with the current state or
decision. Keep one fact per sentence. Attribute findings to their evidence, and
include the method and run location with performance claims. Do not infer design
intent from the implementation.

The root README owns system identity, current components, shared setup, and
adoption constraints. Subsystem READMEs own subsystem use. Contributor
procedure and production operations belong here. Specifications define frozen
interfaces. Design records keep decisions and rejected alternatives. Handoffs
record as-built state for the next session.

## Commits

Keep commits atomic. Subjects are lowercase, at most 72 characters, and stand
alone in `git log --oneline`. Pure additions may use a noun-phrase manifest.
Changes use an imperative verb when the verb carries information. Add a body
when the commit embodies a decision or finding that the diff cannot preserve.
