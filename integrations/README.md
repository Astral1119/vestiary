# Integrations

Direct consumers read Livery's public semantic manifest and apply it through an
application API. They do not participate in Livery's render, validation,
reload, or rollback transaction. Consumers should keep their own defaults when
`~/.config/livery/current/manifest.json` is absent or unreadable.

[`vscode/`](vscode/) is the reference direct consumer. It watches the active
manifest, updates only its declared Visual Studio Code color keys, and can
detach while restoring values that it still owns.

File-oriented integrations belong in [`../adapters/`](../adapters/). The
adapter README documents target discovery, selection, conformance, and the
generic CSS artifact.
