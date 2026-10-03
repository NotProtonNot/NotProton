// On the FEX build the panel drops the controls that cannot take effect there, and
// the Rosetta build keeps every one of them.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: fex.js <emit>'); process.exit(2); }

const AVX = 'Advertise AVX2 to Rosetta';

// One FEX tool and one Rosetta tool installed side by side, as the hook would list them.
const FEX_TOOLS = ['notproton-fex'];

let failed = 0;
for (const form of Object.keys(FORMS)) {
  for (const fex of [false, true]) {
    const { render: P, written } = panel(emit, form, { fexTools: FEX_TOOLS });
    const t = runner(`${form}, ${fex ? 'FEX' : 'Rosetta'}`);
    const tool = fex ? 'notproton-fex' : 'notproton-rosetta';
    const nodes = opts => walk(P({ details: details(opts, { strCompatToolName: tool }) }));
    const toggles = ns => ns.filter(x => x.type === 'Toggle').map(x => x.props.label);
    const backends = ns => ns.find(x => x.type === 'Dropdown').props.rgOptions.map(o => o.data);
    const note = ns => ns.some(x => x.props.className === 'MSCXNote');

    let r = nodes('');
    t.ok(backends(r).includes('d3dmetal') === !fex,
         `D3DMetal is ${fex ? 'not ' : ''}offered (${backends(r)})`);
    t.ok(toggles(r).includes(AVX) === !fex, `the AVX2 row is ${fex ? 'hidden' : 'shown'}`);
    t.ok(toggles(r).includes('DLSS') === !fex,
         `automatic ${fex ? 'hides' : 'shows'} the D3DMetal DLSS row`);
    t.ok(!note(r), 'automatic shows no note');

    // Kept as an entry so the dropdown still names what the options say, with a note
    // that the game is not getting it.
    r = nodes('CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1');
    t.ok(backends(r).includes('d3dmetal'), 'a game set to D3DMetal still shows it selected');
    t.ok(note(r) === fex, `the D3DMetal note is ${fex ? 'shown' : 'absent'}`);
    t.ok(toggles(r).includes('DLSS') === !fex,
         `D3DMetal ${fex ? 'hides' : 'shows'} its DLSS row`);

    // Everything the FEX build can run keeps its controls.
    r = nodes('CX_GRAPHICS_BACKEND=dxmt');
    t.ok(toggles(r).includes('DLSS') && r.some(x => x.type === 'Section' &&
         x.props.label.startsWith('MetalFX')), 'dxmt keeps its DLSS row and MetalFX');
    for (const l of ['Metal HUD', 'MSync', 'High Resolution'])
      t.ok(toggles(r).includes(l), `${l} stays`);

    // Leaving D3DMetal on FEX takes its flag along, same as on Rosetta.
    written.length = 0;
    nodes('CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1').find(x => x.type === 'Dropdown')
      .props.onChange({ data: 'dxmt' });
    const opts = written[written.length - 1].opts;
    t.ok(opts.includes('CX_GRAPHICS_BACKEND=dxmt') && !opts.includes('D3DM_ENABLE_METALFX'),
         `switching off D3DMetal drops its flag (${opts})`);

    // Hidden is not cleared: a value set under the Rosetta build is left for it.
    written.length = 0;
    const kept = 'ROSETTA_ADVERTISE_AVX=1 CX_GRAPHICS_BACKEND=dxvk';
    r = nodes(kept);
    r.find(x => x.type === 'Toggle' && x.props.label === 'Metal HUD').props.onChange(true);
    t.ok(written[written.length - 1].opts.includes('ROSETTA_ADVERTISE_AVX=1'),
         'editing another row keeps the AVX2 value');
    failed += t.failed;
  }

  // A game with no tool name runs under the first tool, which the hook lists as "".
  for (const first of [false, true]) {
    const { render: P } = panel(emit, form, { fexTools: first ? ['', ...FEX_TOOLS] : FEX_TOOLS });
    const t = runner(`${form}, unmapped, first tool ${first ? 'FEX' : 'Rosetta'}`);
    const r = walk(P({ details: details('', { strCompatToolName: '' }) }));
    const offered = r.find(x => x.type === 'Dropdown').props.rgOptions.map(o => o.data);
    t.ok(offered.includes('d3dmetal') === !first,
         `D3DMetal is ${first ? 'not ' : ''}offered (${offered})`);
    failed += t.failed;
  }
}
console.log(failed ? `\n${failed} failure(s)` : '\nFEX hides what it cannot run, Rosetta keeps everything');
process.exit(failed ? 1 : 0);
