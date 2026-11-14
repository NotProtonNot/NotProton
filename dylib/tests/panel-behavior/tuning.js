// The row that applies what this Mac asks for: that it offers the current runner's set,
// writes every line of it, says so once the game already has them, and stays off the page
// when the probe had nothing to say.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: tuning.js <emit>'); process.exit(2); }

const MAC = 'Apple M4 Max, 40 GPU cores, 64 GB, 3456x2234 at 120 Hz';
// A value holding a semicolon is quoted on its way into the launch options, the same way
// the MetalFX row beneath already writes one.
const ROSETTA = ['CX_GRAPHICS_BACKEND=dxmt', 'NOTPROTON_RETINA=1',
                 "DXMT_CONFIG='d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=120'"];
const FEX = ['CX_GRAPHICS_BACKEND=dxmt', 'FEX_X87REDUCEDPRECISION=1'];
const FEX_TOOLS = ['notproton-fex'];

const section = (ns, label) => ns.find(x => x.type === 'Section' && x.props.label === label);
const button = ns => ns.find(x => x.type === 'Button');

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const t = runner(form);

  for (const fex of [false, true]) {
    const want = fex ? FEX : ROSETTA;
    const { render: P, written } = panel(emit, form, undefined, { data: true, fexTools: FEX_TOOLS });
    const tool = fex ? 'notproton-fex' : 'notproton-rosetta';
    const nodes = opts => walk(P({ details: details(opts + ' %command%', { strCompatToolName: tool }) }));
    const kind = fex ? 'FEX' : 'Rosetta';

    const r = nodes('');
    const mac = section(r, 'This Mac');
    t.ok(!!mac, `${kind}: the Mac section is on the page`);
    const field = walk(mac).find(x => x.type === 'Field');
    t.ok(field && field.props.description === MAC, `${kind}: it names the Mac (${field && field.props.description})`);
    t.ok(button(walk(mac)).props.children === 'Use Recommended', `${kind}: the button offers the set`);

    written.length = 0;
    button(walk(mac)).props.onClick();
    const opts = written[written.length - 1].opts;
    for (const pair of want) t.ok(opts.includes(pair), `${kind}: it writes ${pair}`);
    // The other runner's set is not this one's to write.
    const other = fex ? 'NOTPROTON_RETINA=1' : 'FEX_X87REDUCEDPRECISION=1';
    t.ok(!opts.includes(other), `${kind}: and nothing from the other runner (${other})`);
    t.ok(opts.includes('%command%'), `${kind}: the command itself is kept (${opts})`);

    // A row the hardware does not decide keeps whatever the game had.
    written.length = 0;
    button(walk(section(nodes('NOTPROTON_RAW_CONTROLLERS=1'), 'This Mac'))).props.onClick();
    t.ok(written[written.length - 1].opts.includes('NOTPROTON_RAW_CONTROLLERS=1'),
         `${kind}: a setting it has no opinion on is left alone`);

    // Applying it twice is applying it once, and the button says as much.
    const already = nodes(want.join(' '));
    t.ok(button(walk(section(already, 'This Mac'))).props.children === 'In Use',
         `${kind}: a game already on the set reads In Use`);
    t.ok(button(walk(section(nodes(want[0]), 'This Mac'))).props.children === 'Use Recommended',
         `${kind}: part of the set is not the set`);
  }

  // No probe, no row: the page cannot say what this Mac wants, so it offers nothing.
  const { render: P0 } = panel(emit, form, undefined, { data: false });
  t.ok(!section(walk(P0({ details: details('%command%') })), 'This Mac'),
       'without a recommendation there is no Mac section');

  // A summary is a label, not an expression: one that could close the string is dropped
  // in C, which costs the row its line and not the page its syntax.
  const { render: PE } = panel(emit, form, undefined,
                               { data: true, env: { NP_TEST_MAC: 'Evil"});alert(1);({' } });
  const evil = section(walk(PE({ details: details('%command%') })), 'This Mac');
  t.ok(!!evil, 'a summary that could break out still leaves the row');
  t.ok(!walk(evil).find(x => x.type === 'Field').props.description,
       'and the row names no Mac at all');

  failed += t.failed;
}

console.log(failed ? `\ntuning: ${failed} failure(s)` : '\ntuning rows pass in both shapes');
process.exit(failed ? 1 : 0);
