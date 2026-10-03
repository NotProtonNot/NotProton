// Exercise the emitted panel against quoted assignments and game arguments.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: launch-options.js <emit>'); process.exit(2); }

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = opts => walk(P({ details: details(opts) }));
  const last = () => written[written.length - 1].opts;
  const hud = opts => nodes(opts).find(x => x.props.label === 'Metal HUD');

  for (const assignment of ['MTL_HUD_ENABLED="1"', "MTL_HUD_ENABLED='1'",
                            'MTL_HUD_ENABLED=\\1']) {
    t.ok(hud(assignment + ' %command%').props.checked, `reads ${assignment}`);
    written.length = 0;
    hud(assignment + ' %command%').props.onChange(false);
    t.ok(last() === '', `removes the whole token ${assignment}`);
  }

  for (const tail of [
    'WINEDEBUG="err+all, trace+seh" %command% --name "two words"',
    "DXMT_CONFIG='d3d11.foo=1 d3d11.bar=2' %command% --name 'two words'",
    'WINEDEBUG=err+all,\\ trace+seh %command% --name two\\ words',
    'MTL_HUD_ENABLED_EXTRA=1 %command% --title "MTL_HUD_ENABLED=0 extra"',
    'DXMT_CONFIG="literal \\"quote\\" and \\\\slash" %command%',
    'WINEDEBUG="$(touch /tmp/notproton-panel-must-not-run)" %command%',
    '\tWINEDEBUG="a b"\t%command%\t--name "two words"  ',
  ]) {
    written.length = 0;
    hud(tail).props.onChange(true);
    t.ok(last() === 'MTL_HUD_ENABLED=1 ' + tail,
         `preserves unrelated text exactly: ${JSON.stringify(tail)}`);
  }

  // A shell only takes NAME=value as an assignment when the name is unquoted.
  t.ok(!hud('"MTL_HUD_ENABLED=1" %command%').props.checked, 'a quoted name is not an assignment');
  written.length = 0;
  hud('"MTL_HUD_ENABLED=0" %command%').props.onChange(true);
  t.ok(last() === 'MTL_HUD_ENABLED=1 "MTL_HUD_ENABLED=0" %command%', 'a quoted name is left alone');
  t.ok(!hud('%command% --title "MTL_HUD_ENABLED=1"').props.checked,
       'game arguments do not set the toggle');
  written.length = 0;
  hud('').props.onChange(true);
  let repeated = last();
  for (let i = 0; i < 3; i++) {
    hud(repeated).props.onChange(false);
    repeated = last();
    t.ok(repeated === '', 'removing the only assignment leaves empty options');
    hud(repeated).props.onChange(true);
    repeated = last();
    t.ok(repeated === 'MTL_HUD_ENABLED=1 %command%',
         'repeated edits do not accumulate whitespace');
  }
  written.length = 0;
  hud('WINEDEBUG=x MTL_HUD_ENABLED=1').props.onChange(false);
  t.ok(last() === 'WINEDEBUG=x', 'removing the last token leaves no trailing separator');

  const duplicates = 'MTL_HUD_ENABLED=1\tMTL_HUD_ENABLED="0" %command%';
  t.ok(!hud(duplicates).props.checked, 'the last assignment determines the toggle');
  written.length = 0;
  hud(duplicates).props.onChange(true);
  t.ok(last() === 'MTL_HUD_ENABLED=1 %command%', 'replaces all duplicate assignments');
  t.ok(!hud('MTL_HUD_ENABLED=1 MTL_HUD_ENABLED="" %command%').props.checked,
       'an empty final assignment overrides earlier values');

  const backendOptions = 'CX_GRAPHICS_BACKEND="dxmt" DXMT_CONFIG="a=1 b=2" '
                       + 'DXMT_METALFX_SPATIAL_SWAPCHAIN="1" %command% --title "a b"';
  written.length = 0;
  const backend = nodes(backendOptions).find(x => x.type === 'Dropdown');
  t.ok(backend.props.selectedOption === 'dxmt', 'reads a quoted backend');
  backend.props.onChange({ data: 'dxvk' });
  t.ok(last() === 'CX_GRAPHICS_BACKEND=dxvk %command% --title "a b"',
       'switching removes whole quoted assignments and keeps game arguments');

  const upscaled = 'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN="1" '
                 + 'DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.5" %command%';
  t.ok(nodes(upscaled).filter(x => x.type === 'Dropdown')[1].props.selectedOption === '1.5',
       'reads the factor from quoted DXMT_CONFIG');

  // Without %command%, Steam passes the options to the game as arguments.
  t.ok(!hud('MTL_HUD_ENABLED=1 -windowed').props.checked,
       'assignments without %command% do not set the toggle');
  for (const [before, after] of [
    ['-windowed', 'MTL_HUD_ENABLED=1 %command% -windowed'],
    ['MTL_HUD_ENABLED=0 -windowed', 'MTL_HUD_ENABLED=1 %command% -windowed'],
    ['-windowed MTL_HUD_ENABLED=0', 'MTL_HUD_ENABLED=1 %command% -windowed MTL_HUD_ENABLED=0'],
  ]) {
    written.length = 0;
    hud(before).props.onChange(true);
    t.ok(last() === after, `adds %command% to ${JSON.stringify(before)}`);
  }
  written.length = 0;
  hud('MTL_HUD_ENABLED=1 -windowed').props.onChange(false);
  t.ok(last() === '-windowed', 'removes leading assignments written without %command%');

  for (const malformed of ['WINEDEBUG="unfinished', "--title 'unfinished", '--title trailing\\',
                           'WINEDEBUG=1; %command%', 'WINEDEBUG=1 %command% | tee log',
                           'WINEDEBUG=1\n%command%', '# WINEDEBUG=1 %command%',
                           'WINEDEBUG=`id` %command%', 'WINEDEBUG=1 %command% >log']) {
    written.length = 0;
    const ns = nodes(malformed);
    const controls = ns.filter(x => x.type === 'Toggle' || x.type === 'Dropdown');
    t.ok(controls.every(x => x.props.disabled), `disables edits for ${JSON.stringify(malformed)}`);
    t.ok(ns.some(x => x.props.role === 'status' && x.props.children.includes('Launch Options')),
         'explains how to restore editing');
    controls.forEach(x => x.props.onChange(x.type === 'Toggle' ? true : { data: 'dxvk' }));
    t.ok(written.length === 0, 'callbacks leave malformed options untouched');
  }
  t.ok(nodes('WINEDEBUG="finished;" %command%').filter(x => x.type === 'Toggle' || x.type === 'Dropdown')
         .every(x => !x.props.disabled), 'editing resumes after quotes are closed');
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nquoted launch options pass in both shapes');
process.exit(failed ? 1 : 0);
