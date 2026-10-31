// What the panel renders, checked against both forms of the one payload.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: behavior.js <emit>'); process.exit(2); }

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = opts => walk(P({ details: details(opts + ' %command%') }));
  const toggles = ns => ns.filter(x => x.type === 'Toggle').map(x => x.props.label);
  const sections = ns => ns.filter(x => x.type === 'Section').map(x => x.props.label.split(' ')[0]);
  const last = () => (written.length ? written[written.length - 1].opts : '');

  t.ok(P({ details: details('', { vecPlatforms: ['osx'], strCompatToolName: '' }) }) === null,
       'a mac build with nothing pinned renders no panel');
  t.ok(P({ details: details('', { unAppID: 3420702832, vecPlatforms: ['osx'],
                                  strCompatToolName: '' }) }) !== null,
       'a shortcut renders the panel before a tool name reaches the page');

  // Another tool can sit in the same folder -- FEXMac runs macOS on macOS -- and these
  // settings are CrossOver's, so it gets nothing from us rather than the wrong page.
  t.ok(P({ details: details('', { strCompatToolName: 'fexmac' }) }) === null,
       'a tool NotProton did not install renders no panel');
  t.ok(P({ details: details('', { vecPlatforms: ['osx'], strCompatToolName: 'fexmac' }) }) === null,
       'including on the mac builds that tool is for');
  t.ok(P({ details: details('', { strCompatToolName: 'notproton-26.3' }) }) !== null,
       'while one of ours still renders');
  t.ok(panel(emit, form, undefined, { tools: [] }).render({ details: details('', { strCompatToolName: '' }) }) !== null,
       'an unpinned game renders with no tool list');

  // For a tool we did not install there is no run script of ours in the launch, so the
  // panel writes what that script would have exported: the dylib on the insert list and
  // the plugin's own env, in the form that carries a variable without our launch hook.
  const PORTABLE = JSON.stringify([
    { k: 'NOTPROTON_HUD', l: 'Hud', on: '1', off: '', dep: '', d: '',
      rq: '/lib/libhud.dylib', ev: ['HUD=1'] },
    { k: 'NOTPROTON_WINEY', l: 'Winey', on: '1', off: '', dep: '', d: '',
      rq: '/lib/libwine.dylib', rn: 1 },
    { k: 'NOTPROTON_NOTHING', l: 'Nothing', on: '1', off: '', dep: '', d: '' },
  ]).replace(/"(\w+)":/g, '$1:');
  {
    const { render: PO, written: owritten } = panel(emit, form, undefined, { feats: PORTABLE });
    const row = (tool, opts) => walk(PO({ details: details(opts, { strCompatToolName: tool }) }))
      .find(x => x.props && x.props.label === 'Hud');
    const labels = tool => walk(PO({ details: details('', { strCompatToolName: tool }) }))
      .filter(x => x.props && x.props.label).map(x => x.props.label);

    t.ok(labels('fexmac').includes('Hud'), 'a plugin a launch option can carry is offered');
    t.ok(!labels('fexmac').includes('Winey'),
         'one wanting a staged DLL or an override is not, since only our runner does those');
    t.ok(!labels('fexmac').includes('Nothing'), 'and neither is one with nothing to deliver');
    t.ok(!labels('fexmac').includes('Graphics'), 'the CrossOver sections stay behind');

    owritten.length = 0;
    row('fexmac', '').props.onChange(true);
    t.ok(owritten[0].opts ===
         'env DYLD_INSERT_LIBRARIES=/lib/libhud.dylib HUD=1 %command%',
         'switching it on writes the dylib and the env through env');
    t.ok(!row('fexmac', '').props.checked, 'it reads as off before any of that is there');
    t.ok(row('fexmac', 'env DYLD_INSERT_LIBRARIES=/lib/libhud.dylib HUD=1 %command%').props.checked,
         'and as on once it is');
    owritten.length = 0;
    row('fexmac', 'env DYLD_INSERT_LIBRARIES=/lib/libhud.dylib:/other.dylib HUD=1 %command%')
      .props.onChange(false);
    t.ok(owritten[0].opts === 'env DYLD_INSERT_LIBRARIES=/other.dylib %command%',
         'switching it off takes its own entry out and leaves the rest');
    t.ok(row('notproton-26.3', '').props.checked === false,
         'and under one of ours the row is the toggle it always was');
    owritten.length = 0;
    row('notproton-26.3', '').props.onChange(true);
    t.ok(owritten[0].opts === 'NOTPROTON_HUD=1 %command%',
         'writing the key our own run script reads');
  }

  // A value row's key is what our run script strips the prefix off. With no run script in
  // the launch the panel writes the stripped name itself, and the rows that hang off a
  // toggle have to read that toggle the same way the toggle is written.
  const PVALUES = JSON.stringify([
    { k: 'NOTPROTON_HUD', l: 'Hud', on: '1', off: '', dep: '', d: '',
      rq: '/lib/libhud.dylib', ev: ['HUD=1'] },
    { k: 'NOTPROTON_ENV_HUD_POS', l: 'HUD position', on: '1', off: '', d: '',
      dep: 'NOTPROTON_HUD', ty: 'choice', ch: [{ v: 'tl', l: 'Top left' }] },
    { k: 'NOTPROTON_PRIVATE', l: 'Private', on: '1', off: '', dep: '', d: '',
      ty: 'choice', ch: [{ v: 'x', l: 'Ex' }] },
  ]).replace(/"(\w+)":/g, '$1:');
  {
    const { render: PV, written: vwritten } = panel(emit, form, undefined, { feats: PVALUES });
    const nodesFor = (tool, opts) =>
      walk(PV({ details: details(opts, { strCompatToolName: tool }) }));
    const labelsFor = (tool, opts) => nodesFor(tool, opts)
      .filter(x => x.props && x.props.label).map(x => x.props.label);
    const on = 'env DYLD_INSERT_LIBRARIES=/lib/libhud.dylib HUD=1 %command%';

    t.ok(!labelsFor('fexmac', '').includes('HUD position'),
         'a row under a toggle stays hidden while the toggle is off');
    t.ok(labelsFor('fexmac', on).includes('HUD position'),
         'and appears once the toggle reads as on from the launch options');
    t.ok(!labelsFor('fexmac', '').includes('Private'),
         'a value row with a key of ours is not offered, having no run script to strip it');
    vwritten.length = 0;
    nodesFor('fexmac', on).find(x => x.props.label === 'HUD position')
      .props.onChange({ data: 'tl' });
    // A new assignment goes at the front of the run, as it does for every other row.
    t.ok(vwritten[0].opts === on.replace('env ', 'env HUD_POS=tl '),
         'picking a value writes the stripped name inside the env call');
    t.ok(nodesFor('fexmac', on.replace('env ', 'env HUD_POS=tl '))
           .find(x => x.props.label === 'HUD position').props.selectedOption === 'tl',
         'and reads it back from there');
    t.ok(nodesFor('notproton-26.3', 'NOTPROTON_HUD=1 NOTPROTON_ENV_HUD_POS=tl %command%')
           .find(x => x.props.label === 'HUD position').props.selectedOption === 'tl',
         'while under one of ours the key keeps its prefix');
  }

  let r = nodes('');
  t.ok(toggles(r).length === 9 && sections(r).length === 4, 'automatic shows nine toggles in four sections');
  t.ok(r.filter(x => x.type === 'Dropdown').length === 3, 'three dropdowns');
  t.ok(!('label' in r.find(x => x.type === 'Dropdown').props), 'the backend dropdown carries no label column');

  r = nodes('CX_GRAPHICS_BACKEND=dxmt');
  t.ok(toggles(r).filter(l => l === 'DLSS').length === 1 && sections(r).includes('MetalFX'),
       'dxmt keeps one DLSS and keeps MetalFX');
  r = nodes('CX_GRAPHICS_BACKEND=d3dmetal');
  t.ok(toggles(r).filter(l => l === 'DLSS').length === 1 && !sections(r).includes('MetalFX'),
       'd3dmetal keeps one DLSS and hides MetalFX');
  // Both flags are labeled DLSS, so a backend showing its own and its neighbor's
  // would put the same word on two rows.
  for (const b of ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']) {
    const ls = toggles(nodes(b ? 'CX_GRAPHICS_BACKEND=' + b : ''));
    t.ok(ls.filter(l => l === 'DLSS').length === (b === 'dxvk' || b === 'wined3d' ? 0 : 1),
         `${b || 'automatic'} shows DLSS at most once (${ls.join(',')})`);
  }
  // The row that writes the flag the chosen backend actually reads.
  const dlss = (b, key) => {
    written.length = 0;
    nodes('CX_GRAPHICS_BACKEND=' + b).find(x => x.props.label === 'DLSS').props.onChange(true);
    t.ok(last().includes(key + '=1'), `${b} DLSS writes ${key} (${last()})`);
  };
  dlss('d3dmetal', 'D3DM_ENABLE_METALFX');
  dlss('dxmt', 'DXMT_ENABLE_NVEXT');
  t.ok(nodes('CX_GRAPHICS_BACKEND=dxmt DXMT_ENABLE_NVEXT=1')
         .find(x => x.props.label === 'DLSS').props.checked === true,
       'the dxmt DLSS toggle reads as on from its argument');

  t.ok(nodes('CX_GRAPHICS_BACKEND=dxmt').find(x => x.type === 'Dropdown').props.selectedOption === 'dxmt',
       'the backend dropdown reflects the current value');
  t.ok(nodes('MTL_HUD_ENABLED=1').find(x => x.props.label === 'Metal HUD').props.checked === true,
       'a toggle reads as on from its argument');

  nodes('CX_GRAPHICS_BACKEND=dxmt').filter(x => x.type === 'Dropdown')[1].props.onChange({ data: '2.0' });
  t.ok(last().includes('metalSpatialUpscaleFactor=2.0'), 'the upscaler writes its factor');

  // The section names the factor, so a label promising a resolution to go and set in
  // the game is the wording this replaced.
  const upscaler = nodes('CX_GRAPHICS_BACKEND=dxmt').find(x => x.type === 'Section' &&
    x.props.label.indexOf('MetalFX') === 0);
  t.ok(/Samples from the resolution the game is set to/.test(upscaler.props.label),
       'the upscaler section says where it samples from');
  const factors = nodes('CX_GRAPHICS_BACKEND=dxmt').filter(x => x.type === 'Dropdown')[1]
    .props.rgOptions.map(o => o.label);
  t.ok(factors.join(',') === 'Off,1.5x,1.72x,2x,3x', `the factors name themselves (${factors.join(',')})`);

  const fpsOptions = nodes('').find(x => x.type === 'Dropdown' && x.props.rgOptions.some(o => o.data === '60'))
    .props.rgOptions.map(o => o.label);
  t.ok(fpsOptions.join(',') === 'Off,30 FPS,60 FPS,90 FPS,120 FPS,144 FPS,240 FPS', `the fps options name themselves (${fpsOptions.join(',')})`);
  written.length = 0;
  nodes('').find(x => x.type === 'Dropdown' && x.props.rgOptions.some(o => o.data === '60')).props.onChange({ data: '60' });
  t.ok(last().includes('D3DM_MAX_FPS=60'), `the fps cap writes its value (${last()})`);

  written.length = 0;
  nodes('').find(x => x.props.label === 'DirectX Raytracing (DXR)').props.onChange(true);
  t.ok(last().includes('D3DM_SUPPORT_DXR=1'), `DXR toggle writes D3DM_SUPPORT_DXR=1 (${last()})`);

  written.length = 0;
  nodes('').find(x => x.props.label === 'Metal 4 Backend').props.onChange(false);
  t.ok(last().includes('D3DM_MTL4=0'), `Metal 4 toggle writes D3DM_MTL4=0 (${last()})`);

  // The value is the name wine gives the library, which is lower case, and the label is
  // the name in a list of four the reader picks from.
  const backends = nodes('').find(x => x.type === 'Dropdown').props.rgOptions;
  t.ok(backends.map(o => o.label).join(',') === 'Automatic,D3DMetal,DXMT,DXVK,WineD3D',
       `the backends name themselves (${backends.map(o => o.label).join(',')})`);
  t.ok(backends.map(o => o.data).join(',') === ',d3dmetal,dxmt,dxvk,wined3d',
       'the backend values stay as the tool reads them');

  const root = P({ details: details('') });
  t.ok(root.props.className === 'MSCXPanel', 'the panel root carries its own class');
  const classes = nodes('').filter(x => x.type === 'Toggle').map(x => x.props.className);
  t.ok(classes.length === 9 && classes.every(c => c === 'MSCXRow'), 'every checkbox carries the row class');
  const raw = o => nodes(o).find(x => x.props.label === 'Let games read controllers directly (May break Steam Input. Not recommended)');
  t.ok(sections(nodes('')).includes('Controllers') && raw('').props.checked === false,
       'controller hiding is on unless the game says otherwise');
  written.length = 0;
  nodes('').find(x => x.props.label === 'Disable hidraw').props.onChange(true);
  t.ok(last().trim() === 'NOTPROTON_DISABLE_HIDRAW=1 %command%', `hidraw (${last()})`);
  written.length = 0;
  raw('').props.onChange(true);
  t.ok(last().trim() === 'NOTPROTON_RAW_CONTROLLERS=1 %command%', `the controller row writes its flag (${last()})`);
  t.ok(raw('NOTPROTON_RAW_CONTROLLERS=1').props.checked === true, 'the controller row reads its flag');
  written.length = 0;
  raw('NOTPROTON_RAW_CONTROLLERS=1 WINEMSYNC=1').props.onChange(false);
  t.ok(last().trim() === 'WINEMSYNC=1 %command%', `turning the controller row off removes its flag (${last()})`);
  const css = nodes('').filter(x => x.type === 'style');
  t.ok(css.length === 1 && css[0].props.children.includes('.MSCXPanel .MSCXRow{'),
       'the panel carries one stylesheet defining the row rule');
  t.ok(css[0].props.children.includes('.MSCXPanel .MSCXRowDesc>:last-child{flex-basis:100%}'),
       'and the rule that drops a description onto its own line');

  const FEATS = JSON.stringify([
    { k: 'NOTPROTON_ALPHA', l: 'Alpha', on: '1', off: '', dep: '', d: '' },
    { k: 'NOTPROTON_BETA', l: 'Beta', on: '1', off: '0', dep: '', d: 'Why Beta.' },
    { k: 'NOTPROTON_BETA_SUB', l: 'Beta: extra', on: '1', off: '0',
      dep: 'NOTPROTON_BETA', d: '' },
  ]).replace(/"(\w+)":/g, '$1:');

  t.ok(!sections(nodes('')).includes('Developer'),
       'no plugins means no Developer section');
  // rows.length && <jsx> puts a stray "0" on the page when there are no rows.
  const hasZero = n => {
    if (n === 0) return true;
    if (!n || typeof n !== 'object') return false;
    if (Array.isArray(n)) return n.some(hasZero);
    if (typeof n.type === 'function') return hasZero(n.type(n.props));
    return !!(n.props && n.props.children) && hasZero(n.props.children);
  };
  t.ok(hasZero({ props: { children: [1 && 'x', 0 && 'y'] } }),
       'the stray-zero scanner finds a zero when there is one');
  t.ok(!hasZero(P({ details: details('') })),
       'no plugins renders nothing rather than a literal 0');

  // A plugin can name the tools it is for, which is how one meant for an arm64 runner
  // stays off a Rosetta one. The filter runs before anything else reads the rows, so a
  // sub-option of a row that was filtered out goes with it.
  const PICKY = JSON.stringify([
    { k: 'NOTPROTON_FEXONLY', l: 'FEX only', on: '1', off: '', dep: '', d: '',
      tl: ['notproton-fex*'] },
    { k: 'NOTPROTON_FEXSUB', l: 'FEX sub', on: '1', off: '', dep: 'NOTPROTON_FEXONLY', d: '' },
    { k: 'NOTPROTON_EITHER', l: 'Either', on: '1', off: '', dep: '', d: '' },
    { k: 'NOTPROTON_NAMED', l: 'Named', on: '1', off: '', dep: '', d: '',
      tl: ['notproton-26.3'] },
  ]).replace(/"(\w+)":/g, '$1:');
  const labelsFor = (tool, opts) => {
    const { render: PP } = panel(emit, form, undefined, { feats: PICKY });
    return walk(PP({ details: details(opts, { strCompatToolName: tool }) }))
      .filter(x => x.props && x.props.label).map(x => x.props.label);
  };
  t.ok(!labelsFor('notproton-26.3', '').includes('FEX only'),
       'a row for another tool is not shown');
  t.ok(labelsFor('notproton-fex-rosetta', '').includes('FEX only'),
       'and is shown on one its pattern matches');
  t.ok(labelsFor('notproton-26.3', '').includes('Named'), 'an exact name matches too');
  t.ok(labelsFor('notproton-fex-rosetta', '').includes('Either'),
       'a row naming no tools is shown everywhere');
  t.ok(!labelsFor('notproton-26.3', 'NOTPROTON_FEXONLY=1 %command%').includes('FEX sub'),
       'a sub-option of a filtered row goes with it, whatever the launch options say');

  // Lines that only appear once the row is on.
  const KEYS = JSON.stringify([
    { k: 'NOTPROTON_HUD', l: 'Hud', on: '1', off: '', dep: '', d: 'Draws a HUD.',
      dn: ['Ctrl+Opt+H hides it.', 'Ctrl+Opt+G draws the graph.'] },
  ]).replace(/"(\w+)":/g, '$1:');
  const { render: PK } = panel(emit, form, undefined, { feats: KEYS });
  const hud = opts => walk(PK({ details: details(opts) }))
    .find(x => x.props && x.props.label === 'Hud');
  const text = n => typeof n === 'string' ? n
    : !n || typeof n !== 'object' ? ''
    : [].concat(n.props && n.props.children).map(text).join('|');

  t.ok(hud('').props.description === 'Draws a HUD.',
       'an off row shows its description alone');
  t.ok(text(hud('NOTPROTON_HUD=1 %command%').props.description)
       === 'Draws a HUD.|Ctrl+Opt+H hides it.|Ctrl+Opt+G draws the graph.',
       'and an on row shows the extra lines under it, in order');

  // A slider given values instead of a range snaps to them, and a row can hang off one
  // holding a value at all -- which is what makes a sub-option of a dropdown or slider work.
  const LADDER = JSON.stringify([
    { k: 'NOTPROTON_ENV_HZ', l: 'Target', on: '1', off: '', dep: '', d: 'Rate.',
      ty: 'slider', df: 'off',
      ch: [{ v: 'off', l: 'Off' }, { v: '30', l: '30 Hz' }, { v: '60', l: '60 Hz' }] },
    { k: 'NOTPROTON_ENV_MODE', l: 'Mode', on: '1', off: '', dep: 'NOTPROTON_ENV_HZ', d: '',
      ty: 'choice', ch: [{ v: 'attime', l: 'Scheduled' }] },
  ]).replace(/"(\w+)":/g, '$1:');
  const { render: PL, written: lwritten } = panel(emit, form, undefined, { feats: LADDER });
  const lnodes = opts => walk(PL({ details: details(opts) }));
  const snap = opts => lnodes(opts).find(x => x.type === 'SnapSlider');

  t.ok(snap('') !== undefined, 'a slider with values renders as a snapping slider');
  t.ok(snap('').props.rValues.join(',') === 'off,30,60',
       'stepping through the declared values');
  t.ok(snap('').props.value === 'off', 'an unset key sits at the declared default');
  t.ok(snap('NOTPROTON_ENV_HZ=60 %command%').props.value === '60',
       'a launch option picks its notch');
  // vr() logs an error of its own and jumps to the first value when it cannot find one.
  t.ok(snap('NOTPROTON_ENV_HZ=57 %command%').props.value === 'off',
       'a value that is not on the ladder falls back to the default');
  t.ok(snap('').props.renderValue('30') === '30 Hz', 'the notch reads as its label');
  t.ok(snap('').props.notchCount === 3 && snap('').props.notchTicksVisible === true,
       'a tick is drawn for every value');
  t.ok(snap('').props.notchLabels.map(n => n.notchIndex + ':' + n.label).join(',')
       === '0:Off,1:30 Hz,2:60 Hz',
       'each tick carries its own label, matched by notch index');
  lwritten.length = 0;
  snap('').props.onChangeComplete('30');
  t.ok(lwritten[0].opts === 'NOTPROTON_ENV_HZ=30 %command%', 'moving it writes the value');
  lwritten.length = 0;
  snap('NOTPROTON_ENV_HZ=30 %command%').props.onChangeComplete('off');
  t.ok(lwritten[0].opts === '', 'and sliding back to the default clears the key');

  const labels = opts => lnodes(opts).filter(x => x.props && x.props.label)
                                     .map(x => x.props.label);
  t.ok(!labels('').includes('Mode'),
       'a row under a value-holding parent is hidden while that parent is on Default');
  t.ok(labels('NOTPROTON_ENV_HZ=30 %command%').includes('Mode'),
       'and appears once the parent holds a value');
  t.ok(lnodes('NOTPROTON_ENV_HZ=30 %command%')
         .find(x => x.props.label === 'Mode').props.indentLevel === 1,
       'indented under it');
  // The parent is itself hidden with FrameScope off, so the child cannot outlive it.
  const DEEP = JSON.stringify([
    { k: 'NOTPROTON_HUD', l: 'Hud', on: '1', off: '', dep: '', d: '' },
    { k: 'NOTPROTON_ENV_HZ', l: 'Target', on: '1', off: '', dep: 'NOTPROTON_HUD', d: '',
      ty: 'slider', df: 'off',
      ch: [{ v: 'off', l: 'Off' }, { v: '30', l: '30 Hz' }] },
    { k: 'NOTPROTON_ENV_MODE', l: 'Mode', on: '1', off: '', dep: 'NOTPROTON_ENV_HZ', d: '',
      ty: 'choice', ch: [{ v: 'attime', l: 'Scheduled' }] },
  ]).replace(/"(\w+)":/g, '$1:');
  const { render: PD } = panel(emit, form, undefined, { feats: DEEP });
  const dlabels = opts => walk(PD({ details: details(opts) }))
    .filter(x => x.props && x.props.label).map(x => x.props.label);
  t.ok(!dlabels('NOTPROTON_ENV_HZ=30 %command%').includes('Target')
       && !dlabels('NOTPROTON_ENV_HZ=30 %command%').includes('Mode'),
       'a whole chain stays hidden while the row at the top of it is off');
  t.ok(dlabels('NOTPROTON_HUD=1 NOTPROTON_ENV_HZ=30 %command%').includes('Mode'),
       'and the chain appears once the top is on');
  t.ok(walk(PD({ details: details('NOTPROTON_HUD=1 NOTPROTON_ENV_HZ=30 %command%') }))
         .find(x => x.props.label === 'Mode').props.indentLevel === 2,
       'a sub-option of a sub-option indents twice');

  const { render: PF } = panel(emit, form, undefined,
                              { ready: '{"NOTPROTON_ALPHA":0}', feats: FEATS });
  const fnodes = opts => walk(PF({ details: details(opts) }));
  const frows = opts => fnodes(opts).filter(x => x.type === 'ToggleField');
  const grows = opts => fnodes(opts).filter(x => x.type === 'Toggle');
  const flabels = opts => frows(opts).map(x => x.props.label);
  const alpha = o => frows(o).find(x => x.props.label.startsWith('Alpha'));

  t.ok(fnodes('').filter(x => x.type === 'Section')
         .some(x => x.props.label === 'Developer'),
       'plugins add a Developer section');
  // y4 is the theme's ToggleField, the switch Steam's own settings rows use. Yh is
  // DialogCheckbox, which nothing in Steam's UI renders any more.
  t.ok(frows('').length > 0 && frows('').every(x => x.type === 'ToggleField'),
       'Developer rows render as toggles, not checkboxes');
  t.ok(grows('').length > 0,
       'the Graphics and Controllers rows keep the checkbox they always had');
  t.ok(!flabels('').some(l => l.startsWith('Beta:')),
       'a dependent row stays hidden while its parent is off');
  t.ok(flabels('NOTPROTON_BETA=1 %command%').some(l => l.startsWith('Beta:')),
       'a dependent row appears once its parent is on');
  t.ok(!flabels('NOTPROTON_BETA=0 %command%').some(l => l.startsWith('Beta:')),
       'a parent at its off value does not count as on');
  t.ok(alpha('') && alpha('').props.disabled === true,
       'a plugin whose assets are missing renders disabled');
  t.ok(alpha('').props.label.endsWith('(not installed)'),
       'it says why it cannot be used');
  t.ok(alpha('NOTPROTON_ALPHA=1 %command%').props.checked === false,
       'a stale launch option does not show it as on');
  t.ok(frows('').filter(x => x.props.disabled === true).length === 1,
       'only that one is disabled');
  t.ok(frows('').find(x => x.props.label === 'Beta').props.disabled === false,
       'a plugin with no readiness entry stays enabled');
  // The ToggleField lays out label, description and the switch itself, so a Developer
  // row carries no class of ours -- the row CSS used to wrap the control onto its own
  // line, which is what made the switch sit under the description.
  t.ok(frows('').every(x => x.props.className === undefined),
       'Developer rows bring no styling of their own');
  // Without this provider BARREL.m resolves to a bare fallback that ignores layout,
  // description and the fixed-width container -- which is what TODO 19 was chasing.
  t.ok(fnodes('').some(x => x.type === 'FieldProvider'),
       'the Developer section is wrapped in the field provider');
  t.ok(!nodes('').some(x => x.type === 'FieldProvider'),
       'and the Graphics dropdowns are left outside it');
  // A row that only exists while its parent is on is a sub-setting, and the field
  // indents it the way Steam's own nested settings are shown.
  t.ok(frows('NOTPROTON_BETA=1 %command%')
         .find(x => x.props.label.startsWith('Beta:')).props.indentLevel === 1,
       'a dependent row is indented under its parent');
  t.ok(frows('NOTPROTON_BETA=1 %command%')
         .find(x => x.props.label === 'Beta').props.indentLevel === undefined,
       'and a top-level row is not');
  t.ok(frows('').find(x => x.props.label === 'Beta').props.description === 'Why Beta.',
       "a plugin's description reaches the row");
  t.ok(frows('').find(x => x.props.label.startsWith('Alpha')).props.description === undefined,
       'a plugin without one passes no description at all');

  const CHAIN = JSON.stringify([
    { k: 'NOTPROTON_BETA', l: 'Beta', on: '1', off: '0', dep: '', d: '' },
    { k: 'NOTPROTON_BETA_SUB', l: 'Beta: extra', on: '1', off: '0',
      dep: 'NOTPROTON_BETA', d: '' },
    { k: 'NOTPROTON_BETA_SUB_SUB', l: 'Beta: more', on: '1', off: '0',
      dep: 'NOTPROTON_BETA_SUB', d: '' },
  ]).replace(/"(\w+)":/g, '$1:');
  const chain = ready => {
    const { render } = panel(emit, form, undefined, { ready, feats: CHAIN });
    return o => walk(render({ details: details(o) }))
      .filter(x => x.type === 'ToggleField').map(x => x.props.label);
  };
  t.ok(chain('{}')('NOTPROTON_BETA_SUB=1 NOTPROTON_BETA_SUB_SUB=1 %command%')
         .every(l => !l.startsWith('Beta:')),
       'a row stays hidden while any plugin above it is off');
  t.ok(chain('{}')('NOTPROTON_BETA=1 NOTPROTON_BETA_SUB=1 %command%').includes('Beta: more'),
       'and appears once the whole chain is on');
  t.ok(!chain('{"NOTPROTON_BETA":0}')('NOTPROTON_BETA=1 %command%').includes('Beta: extra'),
       'a parent that is not installed does not count as on');
  const { render: PB } = panel(emit, form, undefined,
                              { ready: '{"NOTPROTON_RAW_CONTROLLERS":0}', feats: CHAIN });
  t.ok(walk(PB({ details: details('') })).filter(x => x.type === 'Toggle')
         .every(x => x.props.disabled !== true),
       'readiness never disables a built-in row');

  const rowless = nodes('').filter(x => x.type === 'div' && typeof x.props.ref === 'function');
  t.ok(rowless.length === 0, 'no prefix row before the page defines one');
  const rowsFor = [];
  global.MSCXPrefixRow = (e, id) => rowsFor.push(id);
  const prefix = nodes('').filter(x => x.type === 'div' && typeof x.props.ref === 'function');
  if (prefix.length === 1) prefix[0].props.ref({});
  delete global.MSCXPrefixRow;
  t.ok(prefix.length === 1 && rowsFor[0] === 287700, 'the panel hosts the prefix row for its game');

  // Runner variants are a single choice per dimension, so they render as a dropdown
  // rather than as toggles: nothing has to keep two rows from being on at once, and the
  // value written is the one compat_run.sh resolves.
  const VARS = JSON.stringify([
    { k: 'one', l: 'Build one', v: 'Backend', t: ['notproton'] },
    { k: 'two', l: 'Build two', v: 'Backend', t: ['notproton', 'notproton-26.3'] },
    { k: 'three', l: 'Build three', v: 'Loader', t: ['notproton'] },
    { k: 'elsewhere', l: 'For another runner', v: 'Backend', t: ['notproton-26.3'] },
  ]).replace(/"(\w+)":/g, '$1:');

  const { render: PV, written: vwritten } = panel(emit, form, undefined, { vars: VARS });
  const vnodes = opts => walk(PV({ details: details(opts) }));
  // The picker is the DropDownField itself: it lays out its own label, so there is no
  // wrapper row to look inside.
  const vpicks = opts => vnodes(opts).filter(
    x => x.type === 'Dropdown' && typeof x.props.label === 'string'
         && x.props.label.endsWith(' Variant'));
  const vdrop = (opts, id) =>
    vpicks(opts).find(x => x.props.label === id + ' Variant');
  const vwrite = (opts, id, data) => {
    vwritten.length = 0;
    vdrop(opts, id).props.onChange({ data });
    return vwritten.length ? vwritten[0].opts : null;
  };

  t.ok(vpicks('').length === 2, 'one row per variant the tool has builds for');
  t.ok(vpicks('').map(x => x.props.label).join(',') === 'Backend Variant,Loader Variant',
       'each row is labelled for the variant it chooses');
  // Inside the provider the field lays itself out, so none of the hard spaces or row
  // CSS that stood in for that survives.
  t.ok(vpicks('').every(x => !/\u00a0/.test(x.props.label)),
       'with no hard spaces faking a gap');
  t.ok(vpicks('').every(x => x.props.layout === 'inline'),
       'the label sits beside the control rather than above it');
  t.ok(vpicks('').every(x => x.props.strClassName === undefined),
       'and no row class faking a flex row');
  t.ok(vnodes('').filter(x => x.type === 'Section')
         .some(x => x.props.label === 'Developer'),
       'variants alone are enough for a Developer section');
  t.ok(vdrop('', 'Backend').props.rgOptions.map(o => o.data).join(',') === ',one,two',
       'it offers the default and that variant’s builds, in descriptor order');
  t.ok(vdrop('', 'Backend').props.rgOptions[1].label === 'Build one',
       'a build is named by its label, not its key');
  t.ok(!vdrop('', 'Backend').props.rgOptions.some(o => o.data === 'elsewhere'),
       'a variant that does not fit this tool is not offered');
  t.ok(vdrop('', 'Backend').props.rgOptions[0].label === 'Default',
       'the empty choice is named for what it means: whatever the runner ships');
  t.ok(vdrop('', 'Loader').props.rgOptions.map(o => o.data).join(',') === ',three',
       'the other variant offers only its own');
  t.ok(vdrop('', 'Backend').props.selectedOption === '',
       'nothing selected shows as the default');
  t.ok(vdrop('NOTPROTON_RUNNER_VARIANT=two %command%', 'Backend')
         .props.selectedOption === 'two',
       'a launch option selects its variant');
  t.ok(vdrop('NOTPROTON_RUNNER_VARIANT=two %command%', 'Loader')
         .props.selectedOption === '',
       'and leaves another variant alone');

  t.ok(vwrite('', 'Backend', 'one') === 'NOTPROTON_RUNNER_VARIANT=one %command%',
       'picking one writes the launch option');
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=one %command%', 'Backend', '') === '',
       'picking the default clears it');
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=one %command%', 'Backend', 'two')
         === 'NOTPROTON_RUNNER_VARIANT=two %command%',
       'picking another build of the same variant replaces it');
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=one %command%', 'Loader', 'three')
         === 'NOTPROTON_RUNNER_VARIANT=one+three %command%',
       'a second variant joins rather than replaces');
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=one+three %command%', 'Backend', '')
         === 'NOTPROTON_RUNNER_VARIANT=three %command%',
       'clearing one variant keeps the other');
  // compat_run.sh sorts the names before naming the runner, so the panel sorts too and
  // one combination cannot end up with two runner directories.
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=three %command%', 'Backend', 'one')
         === 'NOTPROTON_RUNNER_VARIANT=one+three %command%',
       'the written order is sorted, whichever order it was picked in');
  // A build that exists but belongs to another runner is kept: switching the compat tool
  // back has to restore it.
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=elsewhere %command%', 'Loader', 'three')
         === 'NOTPROTON_RUNNER_VARIANT=elsewhere+three %command%',
       'a build for another runner is left in place');
  // One no descriptor exists for is not: it can never be chosen or restored here, and
  // leaving it in made every later choice resolve to nothing at all.
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=missing %command%', 'Backend', 'one')
         === 'NOTPROTON_RUNNER_VARIANT=one %command%',
       'a name with no descriptor is dropped');
  t.ok(vwrite('NOTPROTON_RUNNER_VARIANT=elsewhere %command%', 'Backend', 'one')
         === 'NOTPROTON_RUNNER_VARIANT=one %command%',
       'and so is another runner\u2019s build of the variant being set');

  t.ok(!css[0].props.children.includes('MSCXRowPick'),
       'no hand-rolled picker row styling survives');
  // layout:"inline" does not reach this field in the compat page -- without MSCXRow's
  // display:flex the label stacks above the control -- so the flex row has to stay.
  t.ok(/\.MSCXRow\{[^}]*display:flex/.test(css[0].props.children),
       'the row keeps the flex that actually puts label and control on one line');
  t.ok(!sections(nodes('')).includes('Developer'),
       'no variants and no descriptors still means no Developer section');

  const { render: S } = panel(emit, form, undefined, { names: ['o', 't'] });
  const shadowed = walk(S({ details: details('CX_GRAPHICS_BACKEND=dxmt %command%') }));
  t.ok(JSON.stringify(shadowed) === JSON.stringify(nodes('CX_GRAPHICS_BACKEND=dxmt')),
       'a page naming its runtime and barrel o and t renders the same panel');

  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nboth shapes pass');
process.exit(failed ? 1 : 0);
