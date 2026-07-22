# Vestiary for Visual Studio Code

This extension follows Livery's active semantic manifest and applies its public
UI, signal, and terminal colors through the Visual Studio Code configuration
API. It watches `~/.config/livery/current/manifest.json`; no rendered adapter
artifact is required.

The status bar reports the current Look. **Vestiary: Detach and Restore Colors**
stops following Livery and restores each owned color when it has not been
changed since Vestiary applied it. **Vestiary: Reconnect** resumes following the
manifest. Set `vestiary.runtimeRoot` when Livery uses a non-default runtime.
Detach before uninstalling the extension so it can restore the colors it owns.
The extension records that state under
`~/.config/vestiary/integrations/vscode.json`; Vestiary's uninstaller refuses
to remove a managed extension until detachment is confirmed there.

## Development install

Open this directory in Visual Studio Code and run the `Extension` launch target
to use an Extension Development Host. Run the ownership and manifest checks,
then package a VSIX for installation in the normal editor:

```sh
npm test
npm run package
code --install-extension vestiary-vscode-0.1.0.vsix
```

Packaging downloads `@vscode/vsce` through `npx`. The installed extension has
no runtime package dependencies.
