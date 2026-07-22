const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vscode = require('vscode');

const STATE_KEY = 'vestiary.colorOwnership.v1';
const INTEGRATION_STATE = path.join(
  os.homedir(),
  '.config',
  'vestiary',
  'integrations',
  'vscode.json',
);
const ANSI_KEYS = [
  'terminal.ansiBlack',
  'terminal.ansiRed',
  'terminal.ansiGreen',
  'terminal.ansiYellow',
  'terminal.ansiBlue',
  'terminal.ansiMagenta',
  'terminal.ansiCyan',
  'terminal.ansiWhite',
  'terminal.ansiBrightBlack',
  'terminal.ansiBrightRed',
  'terminal.ansiBrightGreen',
  'terminal.ansiBrightYellow',
  'terminal.ansiBrightBlue',
  'terminal.ansiBrightMagenta',
  'terminal.ansiBrightCyan',
  'terminal.ansiBrightWhite',
];

function color(value) {
  if (typeof value === 'string') {
    return value;
  }
  if (value && typeof value.hex === 'string') {
    return value.hex;
  }
  return undefined;
}

function setColor(colors, key, value) {
  const resolved = color(value);
  if (resolved) {
    colors[key] = resolved;
  }
}

function colorsFor(manifest) {
  const colors = {};
  const ui = manifest.ui || {};
  const signals = manifest.signals || {};
  const terminal = manifest.terminal || {};

  setColor(colors, 'foreground', ui.text);
  setColor(colors, 'descriptionForeground', ui.textMuted);
  setColor(colors, 'focusBorder', ui.primary);
  setColor(colors, 'selection.background', ui.selection);
  setColor(colors, 'errorForeground', signals.error);

  setColor(colors, 'editor.background', ui.background);
  setColor(colors, 'editor.foreground', ui.text);
  setColor(colors, 'editor.selectionBackground', ui.selection);
  setColor(colors, 'editor.inactiveSelectionBackground', ui.selection);
  setColor(colors, 'editorCursor.foreground', terminal.cursor);
  setColor(colors, 'editorLineNumber.foreground', ui.textMuted);
  setColor(colors, 'editorLineNumber.activeForeground', ui.text);
  setColor(colors, 'editorWidget.background', ui.surfaceElevated || ui.surface);
  setColor(colors, 'editorWidget.border', ui.outline);

  setColor(colors, 'sideBar.background', ui.surface);
  setColor(colors, 'sideBar.foreground', ui.text);
  setColor(colors, 'sideBar.border', ui.outlineVariant || ui.outline);
  setColor(colors, 'activityBar.background', ui.surfaceElevated || ui.surface);
  setColor(colors, 'activityBar.foreground', ui.text);
  setColor(colors, 'activityBar.inactiveForeground', ui.textMuted);
  setColor(colors, 'activityBarBadge.background', ui.primary);
  setColor(colors, 'activityBarBadge.foreground', ui.onPrimary);
  setColor(colors, 'titleBar.activeBackground', ui.surface);
  setColor(colors, 'titleBar.activeForeground', ui.text);
  setColor(colors, 'titleBar.inactiveBackground', ui.background);
  setColor(colors, 'titleBar.inactiveForeground', ui.textMuted);
  setColor(colors, 'statusBar.background', ui.primary);
  setColor(colors, 'statusBar.foreground', ui.onPrimary);

  setColor(colors, 'input.background', ui.surfaceElevated || ui.surface);
  setColor(colors, 'input.foreground', ui.text);
  setColor(colors, 'input.border', ui.outline);
  setColor(colors, 'dropdown.background', ui.surfaceElevated || ui.surface);
  setColor(colors, 'dropdown.foreground', ui.text);
  setColor(colors, 'dropdown.border', ui.outline);
  setColor(colors, 'button.background', ui.primary);
  setColor(colors, 'button.foreground', ui.onPrimary);
  setColor(colors, 'badge.background', ui.secondary);
  setColor(colors, 'badge.foreground', ui.onPrimary);

  setColor(colors, 'notifications.background', ui.surfaceElevated || ui.surface);
  setColor(colors, 'notifications.foreground', ui.text);
  setColor(colors, 'notifications.border', ui.outline);
  setColor(colors, 'notificationsErrorIcon.foreground', signals.error);
  setColor(colors, 'notificationsWarningIcon.foreground', signals.warning);
  setColor(colors, 'notificationsInfoIcon.foreground', signals.info);

  setColor(colors, 'terminal.background', terminal.background);
  setColor(colors, 'terminal.foreground', terminal.foreground);
  setColor(colors, 'terminalCursor.foreground', terminal.cursor);
  setColor(colors, 'terminal.selectionBackground', terminal.selectionBackground);
  if (Array.isArray(terminal.ansi)) {
    ANSI_KEYS.forEach((key, index) => setColor(colors, key, terminal.ansi[index]));
  }

  return colors;
}

function manifestCompatibilityError(manifest) {
  if (!manifest || manifest.schemaVersion !== 3 || manifest.kind !== 'look-manifest') {
    return 'unsupported Look manifest version or kind';
  }
  if (!['dark', 'light'].includes(manifest.variant)) {
    return 'manifest has an invalid variant';
  }
  if (![manifest.ui, manifest.terminal, manifest.signals]
    .every((domain) => domain && typeof domain === 'object' && !Array.isArray(domain))) {
    return 'manifest is missing a public color domain';
  }
  const mapped = colorsFor(manifest);
  const required = [
    'editor.background',
    'editor.foreground',
    'focusBorder',
    'badge.background',
    'badge.foreground',
    'terminal.background',
    'terminal.foreground',
    ...ANSI_KEYS,
  ];
  if (!required.every((key) => /^#[0-9a-fA-F]{6}$/.test(mapped[key] || ''))) {
    return 'manifest is missing a required color role';
  }
  return undefined;
}

function planApply(currentInput, stateInput, next, containerPresent) {
  const current = { ...currentInput };
  const lastApplied = { ...(stateInput.lastApplied || {}) };
  const state = {
    ...stateInput,
    previous: { ...(stateInput.previous || {}) },
    lastApplied: {},
  };
  if (typeof state.containerPresent !== 'boolean') {
    state.containerPresent = containerPresent;
  }
  for (const [key, lastValue] of Object.entries(lastApplied)) {
    if (Object.prototype.hasOwnProperty.call(next, key)) {
      continue;
    }
    if (current[key] === lastValue) {
      const previous = state.previous[key];
      if (previous && previous.present) {
        current[key] = previous.value;
      } else {
        delete current[key];
      }
    }
    delete state.previous[key];
  }
  for (const [key, value] of Object.entries(next)) {
    if (!Object.prototype.hasOwnProperty.call(state.previous, key)) {
      state.previous[key] = Object.prototype.hasOwnProperty.call(current, key)
        ? { present: true, value: current[key] }
        : { present: false };
    }
    current[key] = value;
  }
  state.lastApplied = { ...next };
  return { colors: current, state };
}

function planDetach(currentInput, stateInput) {
  const current = { ...currentInput };
  const state = {
    ...stateInput,
    previous: { ...(stateInput.previous || {}) },
    lastApplied: { ...(stateInput.lastApplied || {}) },
  };
  for (const [key, lastApplied] of Object.entries(state.lastApplied)) {
    if (current[key] !== lastApplied) {
      continue;
    }
    const previous = state.previous[key];
    if (previous && previous.present) {
      current[key] = previous.value;
    } else {
      delete current[key];
    }
  }
  state.attached = false;
  state.previous = {};
  state.lastApplied = {};
  const colors = !state.containerPresent && Object.keys(current).length === 0
    ? undefined
    : current;
  delete state.containerPresent;
  return { colors, state };
}

function runtimeRoot() {
  const configured = vscode.workspace
    .getConfiguration('vestiary')
    .get('runtimeRoot', '')
    .trim();
  if (!configured) {
    return path.join(os.homedir(), '.config', 'livery');
  }
  if (configured === '~') {
    return os.homedir();
  }
  if (configured.startsWith(`~${path.sep}`)) {
    return path.join(os.homedir(), configured.slice(2));
  }
  return path.resolve(configured);
}

function globalColorCustomizations() {
  const inspected = vscode.workspace
    .getConfiguration('workbench')
    .inspect('colorCustomizations');
  return { ...(inspected && inspected.globalValue ? inspected.globalValue : {}) };
}

function hasGlobalColorCustomizations() {
  const inspected = vscode.workspace
    .getConfiguration('workbench')
    .inspect('colorCustomizations');
  return Boolean(inspected && inspected.globalValue !== undefined);
}

function ownedState(context) {
  const state = context.globalState.get(STATE_KEY, {
    attached: true,
    previous: {},
    lastApplied: {},
  });
  state.previous = state.previous || {};
  state.lastApplied = state.lastApplied || {};
  return state;
}

async function writeIntegrationState(state) {
  const directory = path.dirname(INTEGRATION_STATE);
  const temporary = `${INTEGRATION_STATE}.${process.pid}.tmp`;
  const status = {
    schemaVersion: 1,
    attached: state.attached !== false,
    ownsColors: Object.keys(state.lastApplied || {}).length > 0,
  };
  await fs.promises.mkdir(directory, { recursive: true });
  await fs.promises.writeFile(temporary, `${JSON.stringify(status, null, 2)}\n`);
  await fs.promises.rename(temporary, INTEGRATION_STATE);
}

async function writeGlobalColors(colors) {
  await vscode.workspace
    .getConfiguration('workbench')
    .update('colorCustomizations', colors, vscode.ConfigurationTarget.Global);
}

async function applyManifest(context, manifest) {
  const next = colorsFor(manifest);
  const current = globalColorCustomizations();
  const state = ownedState(context);
  const planned = planApply(current, state, next, hasGlobalColorCustomizations());
  // Mark ownership before changing settings. A failed or interrupted apply may
  // leave a conservative attached marker; the reverse can strand colors.
  await writeIntegrationState(planned.state);
  await writeGlobalColors(planned.colors);
  await context.globalState.update(STATE_KEY, planned.state);
}

async function detach(context) {
  const state = ownedState(context);
  const current = globalColorCustomizations();
  const planned = planDetach(current, state);
  await writeGlobalColors(planned.colors);
  await context.globalState.update(STATE_KEY, planned.state);
  await writeIntegrationState(planned.state);
}

function activate(context) {
  const status = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    20,
  );
  const output = vscode.window.createOutputChannel('Vestiary');
  let watcher;
  let watchedPath;
  let refreshTimer;
  let rearmTimer;
  let operation = Promise.resolve();
  let disposed = false;

  function setStatus(label, tooltip, command = 'vestiary.reconnect') {
    status.text = `$(symbol-color) Vestiary: ${label}`;
    status.tooltip = tooltip;
    status.command = command;
    status.show();
  }

  function desiredWatchPath() {
    const root = runtimeRoot();
    if (fs.existsSync(root)) {
      return root;
    }
    const parent = path.dirname(root);
    return fs.existsSync(parent) ? parent : os.homedir();
  }

  function armWatcher() {
    if (disposed) {
      return;
    }
    const desired = desiredWatchPath();
    if (watcher && watchedPath === desired) {
      return;
    }
    if (watcher) {
      watcher.close();
    }
    watchedPath = desired;
    try {
      const nextWatcher = fs.watch(desired, () => {
        scheduleRefresh();
        clearTimeout(rearmTimer);
        rearmTimer = setTimeout(armWatcher, 250);
      });
      watcher = nextWatcher;
      nextWatcher.on('error', (error) => {
        if (disposed) {
          return;
        }
        output.appendLine(`watch failed: ${error.message}`);
        if (watcher === nextWatcher) {
          watcher.close();
          watcher = undefined;
          watchedPath = undefined;
          clearTimeout(rearmTimer);
          rearmTimer = setTimeout(armWatcher, 1000);
        }
      });
    } catch (error) {
      watcher = undefined;
      watchedPath = undefined;
      output.appendLine(`watch failed: ${error.message}`);
      clearTimeout(rearmTimer);
      rearmTimer = setTimeout(armWatcher, 1000);
    }
  }

  async function refresh() {
    if (disposed) {
      return;
    }
    const state = ownedState(context);
    if (!state.attached) {
      setStatus('detached', 'Vestiary colors are detached.', 'vestiary.reconnect');
      return;
    }

    const manifestPath = path.join(runtimeRoot(), 'current', 'manifest.json');
    try {
      const source = await fs.promises.readFile(manifestPath, 'utf8');
      const manifest = JSON.parse(source);
      const compatibilityError = manifestCompatibilityError(manifest);
      if (compatibilityError) {
        throw new Error(compatibilityError);
      }
      await applyManifest(context, manifest);
      const name = manifest.meta && manifest.meta.name
        ? manifest.meta.name
        : manifest.id || 'current';
      setStatus(name, `Following ${manifestPath}.`, 'vestiary.detach');
    } catch (error) {
      if (error.code !== 'ENOENT') {
        output.appendLine(`refresh failed: ${error.message}`);
      }
      setStatus('disconnected', `No readable Look at ${manifestPath}.`);
    }
  }

  function scheduleRefresh() {
    if (disposed) {
      return;
    }
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      enqueue(refresh);
    }, 150);
  }

  function enqueue(action) {
    operation = operation.then(action, action);
    return operation;
  }

  context.subscriptions.push(
    status,
    output,
    vscode.commands.registerCommand('vestiary.reconnect', () => enqueue(async () => {
      const state = ownedState(context);
      state.attached = true;
      await context.globalState.update(STATE_KEY, state);
      await writeIntegrationState(state);
      armWatcher();
      await refresh();
    })),
    vscode.commands.registerCommand('vestiary.detach', () => enqueue(async () => {
      await detach(context);
      setStatus('detached', 'Vestiary colors are detached.', 'vestiary.reconnect');
    })),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('vestiary.runtimeRoot')) {
        watchedPath = undefined;
        armWatcher();
        scheduleRefresh();
      }
    }),
    {
      dispose() {
        disposed = true;
        clearTimeout(refreshTimer);
        clearTimeout(rearmTimer);
        if (watcher) {
          watcher.close();
        }
      },
    },
  );

  armWatcher();
  writeIntegrationState(ownedState(context)).catch((error) => {
    output.appendLine(`ownership state failed: ${error.message}`);
  });
  scheduleRefresh();
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
  _test: {
    colorsFor,
    manifestCompatibilityError,
    planApply,
    planDetach,
  },
};
