# Common harness contract

The common harness stores reproducible correctness and lifecycle evidence. Its
candidate adapter runs six correctness baselines. It does not apply performance
policy.

`workloads-v1.json` is the accepted identity catalog. It contains nine primary
identities and three deferred identities. Every entry is currently
`contract-only` or `adapter-baseline`. `adapter-baseline` means a real candidate
run exists but the complete workload definition is not yet exercised.

## Workload manifests

Manifest schema versions 1 and 2 share these fields:

- `workload`: accepted identity, positive workload version, and catalog
  classification;
- `criteriaVersion`: the predeclared acceptance criteria;
- `assets` and `inputs`: nonempty lists of stable identities, SHA-256 hashes,
  and byte counts;
- `reference`: the stable identity, SHA-256 hash, and byte count of the
  correctness reference;
- `seed`: a nonnegative integer;
- `checkpoints`: unique identities, nondecreasing monotonic nanosecond times,
  and invariant references;
- `invariants`: unique identities and descriptions.

Schema version 1 is frozen and rejects `derivedArtifacts`. Schema version 2
accepts an optional nonempty `derivedArtifacts` list. Each item binds a
generator source asset and parameter input to distinct generated, comparison,
and generator-binary artifact names. Version 2 currently requires
`byteReproducible` to be false. The result records both generated digests and
whether they happened to match; it does not turn generated container bytes
into stable workload inputs. A manifest file name may retain the workload
version while its `schemaVersion` selects these validation rules.

The media-video workload treats each seek as a new decoded semantic-sequence
epoch. It compares the two generated containers at initial load and again over
the same post-seek sequence without binding the result to earlier wall-clock
playback history.

`validate_manifest()` rejects unknown versions, identities, classifications,
fields, duplicate identities, malformed hashes and counts, and dangling
invariant references. `manifest_hash()` hashes canonical UTF-8 JSON with sorted
keys and no insignificant whitespace.

Correctness results must reproduce the manifest reference exactly. Checkpoint
identities, order, and invariant lists must match the manifest. Semantic
assertion identities and order must match the declared invariants.

## Result records

Result schema version 1 has a common envelope: `run`, `candidate`,
`criteriaVersion`, `build`, `artifacts`, and `verdict`. `run` records UTC
boundaries, the operator label, the agent role, purpose, source and binary
hashes, workload and manifest identities, asset and input hashes, and seed.
Result schema version 1 may bind either supported workload-manifest schema.
The record stores the exact canonical manifest hash, so changing a manifest
from version 1 to version 2 creates a different binding.

Purpose selects the remaining required sections:

- `correctness`: minimal `host` and `display` identity, `policy`, correctness
  checkpoints and semantic assertions, required `execution` counts, and
  structured `shaders` diagnostics;
- `lifecycle`: an owned process manifest, create/destroy and reload iterations,
  explicit device-loss support, before/after/peak resources, and structured
  leak-tool evidence;
- `profiling`: a reserved purpose. Result version 1 rejects profiling records;
  a later version must define the complete serialized profiling protocol.

Inapplicable sections are absent. Correctness records cannot carry profiling,
energy, brightness, or process-inventory fields. Lifecycle records cannot
carry correctness or profiling sections. Unknown fields fail validation.
Version 1 required metrics use `{status: "available", value: integer}` and
reject unavailable values. Lifecycle result version 2 admits unavailable
device-loss and driver-private GPU evidence only when the exact reason is bound
by the lifecycle reference. Correctness version 2 and profiling records remain
rejected.

Verdict categories that follow directly from evidence are not policy inputs.
The correctness check requires every checkpoint and assertion to pass and zero
graphics errors. The diagnostics check requires no error diagnostic. For
lifecycle version 2, the manifest reference fixes iteration values, unsupported
reasons, endpoint requirements, minimum peaks, lifecycle assertions, and the
zero-leak criterion. Lifecycle, resource, and leak checks must equal the
verdict derived from the content-addressed raw evidence. The build check is true
for every structurally valid record because the required build evidence is
present.

Lifecycle process manifests form one rooted acyclic tree. The only root is
`candidate`; its executable hash equals the run and build binary hash. Every
other role has one parent and must reach the candidate root.

`operator` names the person or automation owner. `agentRole` is `automation`,
`operator`, `root-agent`, or `subagent`. A subagent may emit correctness or
lifecycle records. Profiling records are rejected; subagent profiling is
rejected explicitly before the reserved-purpose rejection.

## Artifact and record storage

`ingest_artifact()` opens every source and store component relative to an open
directory descriptor with `O_NOFOLLOW`. It hashes and copies one open source
descriptor, compares its identity and size before and after the copy, and does
not change the source. It writes the content atomically under
`artifacts/sha256/<prefix>/<sha256>` and returns the only artifact descriptor
accepted by the result validator. Descriptors contain a stable name, media
type, SHA-256 hash, byte count, and relative content-addressed path.

Publishing uses a hard link from a private temporary file and never overwrites
an existing CAS key. An existing key is opened without following symlinks and
must match the expected hash and byte count. Multiple logical artifact names
may refer to the same CAS path. Every descriptor in a result must be referenced
by its build or purpose evidence.

`verify_artifacts()` rejects missing, changed, traversing, or symlinked
artifacts. `validate_result_against_manifest()` requires exact agreement on
workload, criteria, asset and input hashes, seed, and manifest hash.
`write_record()` requires the manifest, validates the record and artifacts,
hashes canonical JSON, and atomically writes `records/<sha256>.json`.
Temporary files are removed after failed writes. Persisted records reject
absolute paths and user-directory paths.

The storage implementation requires POSIX directory descriptors,
`O_DIRECTORY`, `O_NOFOLLOW`, directory-relative open and link operations, and
same-filesystem hard links inside the store. The store root is a precondition:
it must already exist as a physical, symlink-free directory. The contract
creates only its controlled `artifacts` and `records` descendants. A caller
must also pass a physical source path. A symlink in either supplied path or
any ancestor is rejected.

## Adapter boundary

`run_lifecycle.py` has separate evidence and gate modes. Both run three owned
helper processes through create, load A, reload B, protocol stop, and reap;
sample their process trees with macOS `libproc`; query tracked programs and
renderer allocation classes; and run `/usr/bin/leaks --atExit` for both the
subject and a matched minimal AppKit-window control. The original zero-leak
record remains a rejected baseline. Device-loss injection and complete
driver-private GPU allocation counts are unsupported and carry manifest-bound
reasons rather than zero values.

Lifecycle version 3 uses a separately frozen control calibration rather than a
moving subject-to-control comparison. Forty control-only exits establish
absolute bounds for known Apple framework root cycles. Candidate campaigns run
five controls and five subjects per backend in a fixed order; every run must
independently satisfy those bounds, zero unknown or renderer-attributable
groups, and exact renderer-owned teardown. Calibration and subject evidence is
stored as WAL–receipt–CAS chains in ignored durable archives. Archive-native
verifiers stream the tarballs without extraction, reject unsafe or unexpected
members, and rederive the recorded caps and verdicts without staging.

`run_correctness.py` accepts an explicit helper binary, official asset root,
expected candidate and backend, pre-existing store, canonical source manifest
and digest, build identity, build command labels, operator, and agent role. Its
wrapper resolves filesystem aliases before the adapter enforces physical paths.
It starts exactly one helper. It owns
timeouts, clean stop and reap, protocol validation, raw command/stdout/stderr
capture, artifact ingestion, manifest binding, and record persistence. It does
not search user directories or retain integration-test records outside their
temporary stores.

The repository-owned fixtures contain deterministic project and scene sources,
traces, references, and pinned manifests. The adapter materializes `scene.pkg`
from canonical package JSON. No Workshop content is redistributed.

`static-no-media` proves constructor presentation, zero evaluation and
presentation churn after quiescence, one property-triggered evaluation and
presentation, and requiescence. A `metrics` request itself causes one no-work
scheduler decision, so the adapter records and subtracts that exact observation
cost. Protocol version 1 has no resize command, so resize remains missing.

`continuous-animation` proves 15, 30, and 60 FPS ceilings with predeclared
three-frame slack, continuous-lease and FPS-ceiling coalescing evidence, live
retiming, a zero-frame/zero-decision paused interval, and resumed liveness. The
fixture has no deadline-bearing change stimulus, so missed-deadline acceptance
is outside this baseline. The fixture selects the continuous scheduler but has
no authored visual motion. Both workloads therefore remain
`adapter-baseline` rather than `implemented`.

`script-heavy` uses two loads in one helper. The first is an otherwise inert
text scene with one authored timer-only script. It proves that the timer is
pending after construction, a `leaseAt`-only coordinator decision advances the
script clock, and the real callback fires once within the declared coordinator
epoch bound. The second proves continuous authored updates, cursor and
user-property invalidations, and conservative reason-7 scheduling for one real
unclassified authored script. The adapter checks exact script counts and
diagnostics. It does not claim pixel-reference correctness, and the
unclassified script is not evaluated.

`particle-heavy` loads the same finite instantaneous emitter twice and compares
its seeded simulation hash and lifecycle counters. A real scheduling-policy
transition from 30 to 1 FPS requests a long interval; cumulative-counter deltas
must show that the runtime simulates the lesser of the request and 100
milliseconds, then reports the remaining time as dropped, within the
manifest-bound tolerance. The
adapter then restores 30 FPS and requires the live set to empty, the typed
particle lease to release exactly once, and frames to stop. Program-cache,
render-allocation, particle-pool, and initialization counters must remain
unchanged across active frames and quiescence. The fixture uses the official
`particle/halo` texture. It does not claim pixel-reference correctness. Only
fully recognized finite emitters receive lifecycle scheduling; other particle
graphs retain conservative continuous scheduling.

`media-video` generates the same short H.264 texture twice with AVAssetWriter.
The generator consumes the canonical manifest-bound parameter document for
dimensions, cadence, frame count, colors, codec settings, and container
layout. The adapter ingests both byte-variable containers and the built
generator. It packages each output in a separate real renderer session and
compares initial, sought, and sequence semantic hashes across them.

The workload proves exact media-only classification, decoded-frame readiness,
PTS-driven typed one-shot scheduling, and the causal revision link from that
readiness to presentation. It proves that pause and hide intervals have no
decode, upload, evaluation, presentation, or deadline churn and that resumed
playback excludes inactive wall time. It also proves one terminal EOS
suppression without retry spin, reload isolation, whole-run execution totals,
and exact final player teardown. Generator source, parameters, binary, and
build toolchain remain manifest-bound. Decoded semantic hashes are
deterministic; container bytes are not claimed to be reproducible.

`audio-reactive` packages one repo-owned image and material that use the
official `util/white` texture, avoiding host-font variability. Its exact scale
script consumes a manifest-bound trace of 128-bin stereo samples through the
production recorder and stereo-16 downsample path. Three ordered samples
complete within one 200 ms render interval while rendering is paused. Their
requested offsets do not claim exact delivery spacing. The adapter requires
three typed invalidations, no render work, exact float-bit and downsample
hashes, and one causal accepting presentation of the latest coalesced value
after resume.

The authored transform uses smoothing 60 at a 5 FPS ceiling, so each observed
transition settles exactly: one changed tick schedules a one-shot next-frame
deadline and the following unchanged tick consumes it. Natural due consumption
must not appear as an explicit release or replacement. A separate pre-due
pause proves explicit cancellation and release. A manifest-bound all-zero
sample then clears the prior state and reaches durable quiescence. The load is
output-muted throughout; spectrum input must still affect visual state, and no
sound control or media player may be constructed. Reload resets all input and
causal counters. A mixed two-object scene proves conservative fail-live
scheduling. A source-level near match proves that generic rendering
compatibility remains available without granting tracked lifecycle scheduling.

The synthetic adapter matrix rejects 12 audio fakes: superficial frame-only
acknowledgement, wrong spectrum content, input/render cadence coupling, missing
typed readiness, late causal revision, missing initial deadline acquisition,
deadline replacement churn, stale authored graph state, missing explicit
cancellation release, output playback leakage, false silence quiescence, and
reload leakage.

The source hash is the SHA-256 of a canonical source manifest. Repository-owned
files are represented by logical paths and content hashes, so the manifest
captures tracked and untracked source content without claiming a clean-tree
commit identity. Git-pinned dependencies use a different identity: the
renderer and GLM checkouts must have the declared `HEAD` and no tracked
modifications. The renderer's required direct submodules must also be at their
recorded revisions and free of tracked modifications.

ANGLE is represented as explicit external material rather than as an asserted
clean checkout. Its semantic revision comes from `angle/REVISION`. ANGLE builds
also hash the consumed header tree, and ANGLE-on-Metal builds hash the resolved
`libEGL` and `libGLESv2` runtime dylibs. Logical external names keep host paths
out of the record. The manifest also records path-free build and toolchain
configuration. CTest regenerates it when repository inputs, pinned dependency
source, ANGLE headers, or runtime libraries change and stores it with the
result. Display fields and
generated-program counts come from helper mechanism evidence. Empty fixtures
must report zero live or historically inserted generated programs; the adapter
fails closed otherwise. Script-heavy records the observed cumulative program
counts without imposing the empty-scene assertion. Particle-heavy requires one
cached generated program and verifies that it is reused.

Run the synthetic contract suite with:

```sh
python3 test_contract.py
python3 test_adapter.py
```
