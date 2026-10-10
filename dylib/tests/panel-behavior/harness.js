// Runs the injected panel as a component, with the barrel and react stubbed, so the
// checks exercise the payload the gates actually write rather than a copy of it.
//
// Capture bytes stand in for names the page assigns, and expanding them to names no
// Steam build would pick keeps a check from passing only for the letters one build
// happened to use.
'use strict';
const fs = require('fs');
const { execFileSync } = require('child_process');

const CAPS = { '\u0003': 'R0', '\u0004': 'B0' };
const expand = s => s.replace(/[\u0001-\u0008]/g, c => {
  if (!(c in CAPS)) throw new Error('payload uses unbound capture ' + c.charCodeAt(0));
  return CAPS[c];
});

const mk = (type, props) => ({ type, props });
const barrel = { XY: 'Section', m: 'Dropdown', Yh: 'Toggle' };

// The two shapes take the payload in different forms and bind different names, which
// is the whole of the difference between them.
const FORMS = {
  component: { arg: 'component', react: 'i',  barrel: 'c'  },
  statement: { arg: 'statement', react: 'R0', barrel: 'B0' },
};

function panel(emit, form, options = {}) {
  const raw = execFileSync(emit, [form], { encoding: 'utf8' }).trim();
  const src = form === 'component'
    ? 'var ' + raw.replace(/,$/, '')
    : expand(raw).replace(/;$/, '');
  const f = FORMS[form];
  let state;
  const react = {
    jsx: mk,
    jsxs: mk,
    Fragment: 'Fragment',
    useState: initial => [state === undefined ? (state = initial) : state, value => {
      state = typeof value === 'function' ? value(state) : value;
    }],
  };
  const written = [];
  const values = options.storage || new Map();
  const confirmations = options.confirmations || [];
  const alerts = [];
  const downloads = [];
  const objectURLs = new Map();
  let nextObjectURL = 0;
  const elements = new Map();
  const document = {
    body: { appendChild: () => {}, removeChild: () => {} },
    createElement: tag => ({ tagName: tag, click() { downloads.push(this); } }),
    getElementById: id => {
      if (!elements.has(id)) elements.set(id, { id, click() {} });
      return elements.get(id);
    },
  };
  class TestBlob {
    constructor(parts, metadata) { this.parts = parts; this.type = metadata.type; }
    text() { return Promise.resolve(this.parts.join('')); }
  }
  class TestFileReader {
    readAsText(file) { this.result = file.content; this.onload(); }
  }
  const URL = {
    createObjectURL: blob => {
      const id = `blob:test-${nextObjectURL++}`;
      objectURLs.set(id, blob);
      return id;
    },
    revokeObjectURL: id => objectURLs.delete(id),
  };
  const localStorage = {
    getItem: key => values.has(key) ? values.get(key) : null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: key => values.delete(key),
  };
  const window = {
    prompt: () => options.profileName || 'Balanced',
    alert: message => alerts.push(message),
    confirm: message => {
      confirmations.push(message);
      return true;
    },
  };
  const SteamClient = {
    Apps: { SetAppLaunchOptions: (appid, opts) => written.push({ appid, opts }) },
    User: { GetSteamID: () => options.account || 'test-account' },
  };
  const build = new Function(f.react, f.barrel, 'SteamClient', 'localStorage', 'window',
    'document', 'Blob', 'FileReader', 'URL',
    src + '\nreturn MSCXOpts;');
  return {
    render: build(react, barrel, SteamClient, localStorage, window, document, TestBlob,
      TestFileReader, URL), written, values, window, confirmations, alerts, downloads, objectURLs,
    elements,
  };
}

// Function components are resolved rather than recorded, so a check sees the nodes the
// page ends up with and not the wrappers on the way there.
function walk(node, out = []) {
  if (!node || typeof node !== 'object') return out;
  if (Array.isArray(node)) { node.forEach(c => walk(c, out)); return out; }
  if (typeof node.type === 'function') return walk(node.type(node.props), out);
  if (node.type) out.push(node);
  if (node.props && node.props.children) walk(node.props.children, out);
  return out;
}

function details(launchOptions, over) {
  return Object.assign({
    unAppID: 287700,
    vecPlatforms: ['windows'],
    strCompatToolName: 'notproton',
    strLaunchOptions: launchOptions,
  }, over || {});
}

function runner(name) {
  let failed = 0;
  return {
    ok(cond, what) {
      if (!cond) failed++;
      console.log(`  ${cond ? 'PASS' : 'FAIL'}  [${name}] ${what}`);
    },
    get failed() { return failed; },
  };
}

module.exports = { panel, walk, details, runner, expand, FORMS };
