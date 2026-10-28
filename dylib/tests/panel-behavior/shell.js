'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: shell.js <emit>'); process.exit(2); }

const TOGGLES = {
  'Metal HUD': 'MTL_HUD_ENABLED',
  'MSync': 'WINEMSYNC',
  'High Resolution': 'NOTPROTON_RETINA',
  'Advertise AVX2 to Rosetta': 'ROSETTA_ADVERTISE_AVX',
  'Let games read controllers directly (May break Steam Input. Not recommended)': 'NOTPROTON_RAW_CONTROLLERS',
  'Disable hidraw': 'NOTPROTON_DISABLE_HIDRAW',
};
const ON_UNLESS_0 = { ROSETTA_ADVERTISE_AVX: true };
const PANEL_KEYS = ['CX_GRAPHICS_BACKEND', 'MTL_HUD_ENABLED', 'D3DM_ENABLE_METALFX', 'DXMT_ENABLE_NVEXT',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'DXMT_CONFIG', 'ROSETTA_ADVERTISE_AVX', 'WINEMSYNC', 'NOTPROTON_RETINA',
  'NOTPROTON_RAW_CONTROLLERS', 'NOTPROTON_DISABLE_HIDRAW'];
const OTHER_KEYS = ['WINEDEBUG', 'DXVK_HUD', 'FOO', 'SteamAppId', 'STEAM_COMPAT_DATA_PATH'];

const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'np-shell-')));
const probe = path.join(dir, 'probe');
fs.writeFileSync(probe, '#!' + process.execPath + '\n' +
  `const k=${JSON.stringify(PANEL_KEYS.concat(OTHER_KEYS))};const e={};` +
  'k.forEach(n=>{if(n in process.env)e[n]=process.env[n]});' +
  'require("fs").appendFileSync(process.env.NP_PROBE_OUT,' +
  'JSON.stringify({argv:process.argv.slice(2),env:e,cwd:process.cwd()})+"\\n");\n', { mode: 0o755 });
fs.writeFileSync(path.join(dir, 'gamemoderun'), '#!/bin/sh\nexec "$@"\n', { mode: 0o755 });

const quote = s => "'" + s.replace(/'/g, "'\\''") + "'";
// Steam expands %command% to the tool, its verb and the game.
const COMMAND = quote(probe) + " waitforexitandrun  'game.exe'";

function steamLine(options, command = COMMAND) {
  const o = options.trim();
  return /%command%/i.test(o) ? o.replace(/%command%/gi, () => command) : command + (o ? ' ' + o : '');
}

const shells = ['/bin/sh', '/bin/dash'].filter(s => fs.existsSync(s));

function launch(shell, options, command) {
  const out = path.join(dir, 'runs');
  fs.rmSync(out, { force: true });
  spawnSync(shell, ['-c', steamLine(options, command)], {
    env: { PATH: dir + ':/usr/bin:/bin', HOME: process.env.HOME, NP_PROBE_OUT: out, SteamAppId: '287700', STEAM_COMPAT_DATA_PATH: '/steam/prefix/287700' },
    cwd: dir, timeout: 10000, stdio: 'ignore',
  });
  return fs.existsSync(out) ? fs.readFileSync(out, 'utf8').trim().split('\n').map(JSON.parse) : [];
}

function view(form, options) {
  const P = panel(emit, form);
  const nodes = walk(P.render({ details: details(options, { strInstallFolder: dir }) }));
  const toggles = {};
  nodes.filter(n => n.type === 'Toggle' && n.props.label in TOGGLES)
       .forEach(n => { toggles[TOGGLES[n.props.label]] = n; });
  const backend = nodes.find(n => n.type === 'Dropdown' && n.props.rgOptions.some(o => o.data === 'dxvk'));
  const upscale = nodes.find(n => n.type === 'Dropdown' && n.props.rgOptions.some(o => o.data === '1.5'));
  return { toggles, backend, upscale, written: P.written, files: P.files, dialogs: P.dialogs,
           buttons: nodes.filter(n => n.type === 'Button'),
           section: nodes.find(n => n.type === 'Section' && n.props.label === 'Launch Executable'),
           target: nodes.find(n => n.type === 'Field' && n.props.label === 'Executable'),
           start: nodes.find(n => n.type === 'Field' && n.props.label === 'Start Executable From') };
}

function dxmt(conf) {
  const out = {};
  for (const line of (conf || '').split(';')) {
    let n = 0;
    const ws = () => { while (n < line.length && ' \t\r'.includes(line[n])) n++; };
    ws();
    let key = '';
    while (n < line.length && /[0-9A-Za-z._]/.test(line[n])) key += line[n++];
    ws();
    if (line[n] !== '=') continue;
    n++; ws();
    let value = '', str = false;
    for (; n < line.length; n++) {
      if (!str && ' \t\r'.includes(line[n])) break;
      if (line[n] === '"') str = !str; else value += line[n];
    }
    out[key] = value;
  }
  return out;
}
const FACTOR = 'd3d11.metalSpatialUpscaleFactor';
const userDxmt = env => { const c = dxmt(env.DXMT_CONFIG); delete c[FACTOR]; return JSON.stringify(c); };

function agrees(t, v, env, what) {
  if (v.upscale) {
    const f = Math.max(parseFloat(dxmt(env.DXMT_CONFIG)[FACTOR] || '2'), 1);
    const want = env.DXMT_METALFX_SPATIAL_SWAPCHAIN === '1' ? f : '';
    const got = v.upscale.props.selectedOption;
    t.ok(got === '' ? want === '' : parseFloat(got) === want,
         `${what}: upscale shows "${got}", DXMT uses ${want}`);
  }
  for (const [key, node] of Object.entries(v.toggles)) {
    const on = key in ON_UNLESS_0 ? env[key] !== '0' : env[key] === '1';
    t.ok(node.props.checked === on, `${what}: ${key} shows ${node.props.checked}, game gets ${env[key]}`);
  }
  const backend = env.CX_GRAPHICS_BACKEND === 'auto' ? '' : env.CX_GRAPHICS_BACKEND || '';
  t.ok(v.backend.props.selectedOption === backend,
       `${what}: backend shows "${v.backend.props.selectedOption}", game gets ${env.CX_GRAPHICS_BACKEND}`);
}

const ACTIONS = [
  { name: 'Metal HUD', run: v => v.toggles.MTL_HUD_ENABLED.props.onChange(!v.toggles.MTL_HUD_ENABLED.props.checked),
    want: (v0, v1) => v1.toggles.MTL_HUD_ENABLED.props.checked === !v0.toggles.MTL_HUD_ENABLED.props.checked },
  { name: 'MSync', run: v => v.toggles.WINEMSYNC.props.onChange(!v.toggles.WINEMSYNC.props.checked),
    want: (v0, v1) => v1.toggles.WINEMSYNC.props.checked === !v0.toggles.WINEMSYNC.props.checked },
  { name: 'AVX2', run: v => v.toggles.ROSETTA_ADVERTISE_AVX.props.onChange(!v.toggles.ROSETTA_ADVERTISE_AVX.props.checked),
    want: (v0, v1) => v1.toggles.ROSETTA_ADVERTISE_AVX.props.checked === !v0.toggles.ROSETTA_ADVERTISE_AVX.props.checked },
  { name: 'raw controllers', run: v => v.toggles.NOTPROTON_RAW_CONTROLLERS.props.onChange(!v.toggles.NOTPROTON_RAW_CONTROLLERS.props.checked),
    want: (v0, v1) => v1.toggles.NOTPROTON_RAW_CONTROLLERS.props.checked === !v0.toggles.NOTPROTON_RAW_CONTROLLERS.props.checked },
  { name: 'backend dxvk', run: v => v.backend.props.onChange({ data: 'dxvk' }),
    want: (v0, v1) => v1.backend.props.selectedOption === 'dxvk' },
  { name: 'backend automatic', run: v => v.backend.props.onChange({ data: '' }),
    want: (v0, v1) => v1.backend.props.selectedOption === '' },
  { name: 'upscale 1.5', run: v => v.upscale && v.upscale.props.onChange({ data: '1.5' }),
    want: (v0, v1) => !v0.upscale || v1.upscale.props.selectedOption === '1.5' },
  { name: 'upscale off', run: v => v.upscale && v.upscale.props.onChange({ data: '' }),
    want: (v0, v1) => !v0.upscale || v1.upscale.props.selectedOption === '' },
];

const CASES = [
  "CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG='d3d11.preferredMaxFrameRate=60' %command%",
  'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.preferredMaxFrameRate=60;" %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor = 1.5 ; d3d11.preferredMaxFrameRate=30" %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=3.0;d3d11.metalSpatialUpscaleFactor=1.5" %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=0.5 %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=2" %command% --offline',
  "DXMT_CONFIG='d3d11.preferredMaxFrameRate=60' %command% --offline",
  '',
  '--offline',
  '%command%',
  '%command% --offline',
  'MTL_HUD_ENABLED=1 %command%',
  'MTL_HUD_ENABLED="1" %command% --offline',
  "MTL_HUD_ENABLED='1' WINEMSYNC=0 %command%",
  'MTL_HUD_ENABLED=1 %COMMAND%',
  'MTL_HUD_ENABLED=1 %Command% -windowed',
  'MTL_HUD_ENABLED=1 %command%%command%',
  'DXVK_HUD=1 %command% --offline',
  'WINEDEBUG="err+all, trace+seh" MTL_HUD_ENABLED=1 %command% --name "two words"',
  "DXMT_CONFIG='d3d11.foo=1 d3d11.bar=2' %command% --name 'two words'",
  'WINEDEBUG=err+all,\\ trace+seh %command% --name two\\ words',
  '%command% --title MTL_HUD_ENABLED=1',
  'MTL_HUD_ENABLED_EXTRA=1 %command% --title "MTL_HUD_ENABLED=0 extra"',
  'MTL_HUD_ENABLED=1\tMTL_HUD_ENABLED="0" %command%',
  'MTL_HUD_ENABLED=1 MTL_HUD_ENABLED="" %command%',
  'MTL_HUD_ENABLED=1 -windowed',
  'MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt',
  '-windowed MTL_HUD_ENABLED=1',
  'MTL_HUD_ENABLED=1 gamemoderun %command%',
  'gamemoderun MTL_HUD_ENABLED=1 %command%',
  'gamemoderun %command% --offline',
  'MTL_HUD_ENABLED=1; %command%',
  'MTL_HUD_ENABLED=1 true && %command%',
  'true && MTL_HUD_ENABLED=1 %command% --offline',
  'true; CX_GRAPHICS_BACKEND=dxmt %command%',
  'MTL_HUD_ENABLED=1 %command% | cat',
  'MTL_HUD_ENABLED=1 %command% > /dev/null 2>&1',
  'MTL_HUD_ENABLED=1 2>/dev/null %command%',
  'MTL_HUD_ENABLED=1>/dev/null %command%',
  'MTL_HUD_ENABLED=1 %command% # MTL_HUD_ENABLED=0',
  '( MTL_HUD_ENABLED=1 %command% )',
  '{ MTL_HUD_ENABLED=1 %command%; }',
  'if true; then MTL_HUD_ENABLED=1 %command%; fi',
  'FOO=$(echo a b) MTL_HUD_ENABLED=1 %command%',
  'FOO="$(echo "a)b")" MTL_HUD_ENABLED=1 %command%',
  'FOO=`echo a b` MTL_HUD_ENABLED=1 %command%',
  'FOO=${HOME:-a b} MTL_HUD_ENABLED=1 %command%',
  'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2.0 %command%',
  'MTL_HUD_ENABLED="1 %command%',
  'MTL_HUD_ENABLED=1 "%command%"',
  'MTL_HUD_ENABLED=1 \\%command%',
  '  MTL_HUD_ENABLED=1   %command%  --offline  ',
];

let failed = 0;
for (const shell of shells) {
  for (const form of Object.keys(FORMS)) {
    const t = runner(`${path.basename(shell)} ${form}`);
    for (const options of CASES) {
      const before = launch(shell, options);
      const v0 = view(form, options);
      const label = JSON.stringify(options);
      if (before.length) agrees(t, v0, before[0].env, label);
      for (const a of ACTIONS) {
        const v = view(form, options);
        a.run(v);
        const next = v.written.length ? v.written[v.written.length - 1].opts : options;
        const after = launch(shell, next);
        const what = `${label} ${a.name} -> ${JSON.stringify(next)}`;
        t.ok(after.length === before.length, `${what}: game runs ${after.length}x, was ${before.length}x`);
        const v1 = view(form, next);
        t.ok(a.want(v0, v1), `${what}: panel shows the change`);
        if (!after.length || after.length !== before.length) continue;
        agrees(t, v1, after[0].env, what);
        before.forEach((run, n) => {
          t.ok(JSON.stringify(after[n].argv) === JSON.stringify(run.argv),
               `${what}: game arguments kept ${JSON.stringify(after[n].argv)}`);
          for (const k of OTHER_KEYS)
            t.ok(after[n].env[k] === run.env[k], `${what}: ${k} kept`);
          t.ok(userDxmt(after[n].env) === userDxmt(run.env),
               `${what}: DXMT_CONFIG entries kept ${userDxmt(after[n].env)}`);
        });
      }
    }
    failed += t.failed;
  }
}

// The Launch Executable section, driven through Steam's file dialog and read back from what the game gets.
const TARGETS = ['Mod Engine 2/launchmod_eldenring.bat',
  `Jeux/Café "d" l'été/ゲーム.EXE`, 'AssassinsCreed_Dx10.exe', '$HOME `id` \\x.bat',
  'braces{a,b}[*]?/%command%\n.exe'].map(p => path.join(dir, p));
for (const exe of TARGETS) fs.mkdirSync(path.dirname(exe), { recursive: true });
const startDir = path.join(dir, 'start in/ü');
fs.mkdirSync(startDir, { recursive: true });
const otherExe = path.join(dir, 'other.exe');
const STARTS = ['', '-windowed', 'MTL_HUD_ENABLED=1 %command% --offline',
  'WINEDEBUG="a b" gamemoderun %command% -t er',
  '"/Users/test/Games/Mod Engine 2/launchmod_eldenring.bat"',
  `bash -c 'exec "\${@/game.exe/launchmod_eldenring.bat}"' -- %command%`];
for (const shell of shells) {
  for (const form of Object.keys(FORMS)) {
    const t = runner(`${path.basename(shell)} ${form} executable`);
    const click = (v, n, file) => {
      if (file !== undefined) v.files.push(file);
      v.buttons[n].props.onClick();
      return v.written.length ? v.written[v.written.length - 1].opts : null;
    };
    for (const start of STARTS) {
      const before = launch(shell, start);
      let v = view(form, start);
      t.ok(v.section && v.target && !v.start && v.target.props.description === undefined &&
           JSON.stringify(v.buttons.map(b => b.props.children)) === '["Browse..."]',
           `${JSON.stringify(start)}: only Executable and its Browse show without a pick`);
      t.ok(click(v, 0, '') === null, `${JSON.stringify(start)}: an empty answer writes nothing`);
      v = view(form, start);
      t.ok(click(v, 0, undefined) === null, `${JSON.stringify(start)}: a cancelled dialog writes nothing`);
      for (const exe of TARGETS) {
        const what = `${JSON.stringify(start)} + ${JSON.stringify(exe)}`;
        const folder = path.dirname(exe);
        v = view(form, start);
        const picked = click(v, 0, exe);
        t.ok(JSON.stringify(v.dialogs[0].rgFilters[0].rFilePatterns) === '["*.exe","*.bat"]' &&
             v.dialogs[0].strInitialFile === dir, `${what}: the dialog offers .exe and .bat from the game folder`);
        const run = launch(shell, picked);
        t.ok(run.length === before.length && run.length > 0, `${what}: the game runs once -> ${JSON.stringify(picked)}`);
        if (!run.length || run.length !== before.length) continue;
        t.ok(run[0].argv[1] === exe && run[0].cwd === folder, `${what}: tool receives the pick and starts in its folder`);
        t.ok(JSON.stringify(run[0].argv) === JSON.stringify(before[0].argv.map((a, i) => i === 1 ? exe : a)),
             `${what}: game arguments kept ${JSON.stringify(run[0].argv)}`);
        t.ok(['WINEDEBUG', 'MTL_HUD_ENABLED', 'SteamAppId', 'STEAM_COMPAT_DATA_PATH'].every(k => run[0].env[k] === before[0].env[k]),
             `${what}: other settings kept`);

        if (start === STARTS[0] && exe === TARGETS[0]) {
          const native = launch(shell, picked, quote(probe) + " run 'game.exe'");
          t.ok(native.length === 1 && JSON.stringify(native[0].argv) === '["run","game.exe"]' && native[0].cwd === dir,
               `${what}: without waitforexitandrun the command runs unchanged`);
          v = view(form, picked);
          v.toggles.MTL_HUD_ENABLED.props.onChange(true);
          const toggled = v.written.at(-1).opts;
          const toggleRun = launch(shell, toggled);
          t.ok(toggleRun.length === 1 && toggleRun[0].env.MTL_HUD_ENABLED === '1' &&
               toggleRun[0].argv[1] === exe, `${what}: settings edits retain the generated wrapper`);
          const F = panel(emit, form, undefined, { fexTools: ['fex'] });
          F.pick(details('CX_GRAPHICS_BACKEND=d3dmetal ' + toggled), 'fex');
          const fexRun = launch(shell, F.written.at(-1).opts);
          t.ok(fexRun.length === 1 && !fexRun[0].env.CX_GRAPHICS_BACKEND &&
               fexRun[0].argv[1] === exe, `${what}: FEX cleanup retains the generated wrapper`);
          v = view(form, picked);
          t.ok(launch(shell, click(v, 2, path.join(dir, 'missing'))).length === 0,
               `${what}: a start folder that is gone does not launch`);
          v = view(form, picked);
          t.ok(click(v, 2, folder) === picked, `${what}: choosing the program's own folder keeps the default`);
        }
        v = view(form, picked);
        t.ok(JSON.stringify(v.buttons.map(b => b.props.children)) === '["Remove","Browse...","Browse..."]' &&
             v.target.props.description === exe && v.start.props.description === folder,
             `${what}: the pick and the folder it starts in show as full paths`);
        const withDir = click(v, 2, startDir);
        t.ok(v.dialogs[0].bChooseDirectory === true && v.dialogs[0].strInitialFile === folder,
             `${what}: the start folder dialog opens on the program's folder`);
        const dirRun = launch(shell, withDir);
        t.ok(dirRun.length && dirRun[0].cwd === startDir && dirRun[0].argv[1] === exe, `${what}: the start folder is used and the pick kept`);
        v = view(form, withDir);
        t.ok(v.target.props.description === exe && v.start.props.description === startDir &&
             JSON.stringify(v.buttons.map(b => b.props.children)) === '["Remove","Browse...","Reset","Browse..."]',
             `${what}: the chosen start folder shows, with Reset beside its Browse`);
        const dirReset = launch(shell, click(v, 2));
        t.ok(dirReset.length && dirReset[0].cwd === folder && dirReset[0].argv[1] === exe,
             `${what}: Reset starts the program in its own folder again`);
        v = view(form, withDir);

        const again = launch(shell, click(v, 1, otherExe));
        t.ok(again.length && again[0].argv[1] === otherExe && again[0].cwd === dir,
             `${what}: picking another program starts it in its own folder`);

        v = view(form, withDir);
        const removed = click(v, 0);
        const removedRun = launch(shell, removed);
        t.ok(removedRun.length === before.length && removedRun.every((r, n) =>
               r.cwd === before[n].cwd && JSON.stringify(r.argv) === JSON.stringify(before[n].argv)),
             `${what}: Remove launches the game as before -> ${JSON.stringify(removed)}`);
        t.ok(removed === (/%command%/.test(start) || !start ? start : '%command% ' + start),
             `${what}: Remove restores the original text`);
      }
    }
    failed += t.failed;
  }
}

// A %command% the wrapper cannot stand in for is left alone rather than rewritten.
for (const form of Object.keys(FORMS)) {
  const t = runner(`${form} executable, unsupported options`);
  for (const start of ['MTL_HUD_ENABLED=1 "%command%"', 'MTL_HUD_ENABLED=1 \\%command%',
                       "bash -c 'run %command%'", '# %command%']) {
    const v = view(form, start);
    v.files.push(otherExe);
    v.buttons[0].props.onClick();
    t.ok(v.written.length === 0, `${JSON.stringify(start)}: Browse writes nothing`);
  }
  const lookalike = "sh -c 'exec \"$@\"' sh '/g/a.exe' '' %command%";
  const v = view(form, lookalike);
  t.ok(v.buttons.length === 1, 'a hand-written wrapper is not read as a chosen executable');
  failed += t.failed;
}

fs.rmSync(dir, { recursive: true, force: true });
console.log(failed ? `\n${failed} failure(s)` : `\npanel agrees with ${shells.join(' and ')}`);
process.exit(failed ? 1 : 0);
