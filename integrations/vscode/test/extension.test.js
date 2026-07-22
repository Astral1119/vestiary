const assert = require('node:assert/strict');
const Module = require('node:module');

const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (request === 'vscode') {
    return {};
  }
  return originalLoad.call(this, request, parent, isMain);
};
const { _test } = require('../extension');
Module._load = originalLoad;

const color = (hex) => ({ hex, rgb: [0, 0, 0] });
const manifest = {
  schemaVersion: 3,
  kind: 'look-manifest',
  variant: 'dark',
  ui: {
    background: color('#101010'),
    text: color('#eeeeee'),
    textMuted: color('#aaaaaa'),
    primary: color('#ff0000'),
    secondary: color('#00ff00'),
    onPrimary: color('#000000'),
  },
  signals: {
    error: color('#ff0000'),
  },
  terminal: {
    background: color('#101010'),
    foreground: color('#eeeeee'),
    ansi: Array.from({ length: 16 }, () => color('#202020')),
  },
};

assert.equal(_test.manifestCompatibilityError(manifest), undefined);
assert.match(
  _test.manifestCompatibilityError({ ...manifest, schemaVersion: 99 }),
  /unsupported/,
);
assert.match(
  _test.manifestCompatibilityError({ ...manifest, terminal: [] }),
  /domain/,
);
assert.match(
  _test.manifestCompatibilityError({ ...manifest, ui: {} }),
  /required color role/,
);

const mapped = _test.colorsFor(manifest);
assert.equal(mapped['editor.background'], '#101010');
assert.equal(mapped['badge.background'], '#00ff00');
assert.equal(mapped['badge.foreground'], '#000000');
assert.equal(mapped['terminal.ansiBrightWhite'], '#202020');

const applied = _test.planApply(
  { 'editor.background': '#ffffff', 'user.color': '#123456' },
  { attached: true, previous: {}, lastApplied: {} },
  { 'editor.background': '#101010', 'editor.foreground': '#eeeeee' },
  true,
);
assert.deepEqual(applied.state.previous['editor.background'], {
  present: true,
  value: '#ffffff',
});
assert.deepEqual(applied.state.previous['editor.foreground'], { present: false });
assert.equal(applied.colors['user.color'], '#123456');

const userChanged = {
  ...applied.colors,
  'editor.foreground': '#abcdef',
};
const detached = _test.planDetach(userChanged, applied.state);
assert.equal(detached.colors['editor.background'], '#ffffff');
assert.equal(detached.colors['editor.foreground'], '#abcdef');
assert.equal(detached.colors['user.color'], '#123456');
assert.equal(detached.state.attached, false);

const shrunk = _test.planApply(
  applied.colors,
  applied.state,
  { 'editor.foreground': '#dddddd' },
  true,
);
assert.equal(shrunk.colors['editor.background'], '#ffffff');
assert.equal(shrunk.state.previous['editor.background'], undefined);
assert.equal(shrunk.state.lastApplied['editor.background'], undefined);

const created = _test.planApply(
  {},
  { attached: true, previous: {}, lastApplied: {} },
  { 'editor.background': '#101010' },
  false,
);
assert.equal(_test.planDetach(created.colors, created.state).colors, undefined);

console.log('VS Code extension checks passed');
