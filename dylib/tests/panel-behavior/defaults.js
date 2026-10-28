'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: defaults.js <emit>'); process.exit(2); }

const FEX_TOOLS = ['notproton-fex'];
const AVX = 'Advertise AVX2 to Rosetta';
const X87 = 'Reduced x87 Precision (Reducing precision improves game performance, is enabled by default in CrossOver Preview)';
const SAVED = {
  rosetta: { CX_GRAPHICS_BACKEND: 'dxmt', MTL_HUD_ENABLED: '1', ROSETTA_ADVERTISE_AVX: '0',
             DXMT_METALFX_SPATIAL_SWAPCHAIN: '1', DXMT_CONFIG: 'd3d11.metalSpatialUpscaleFactor=1.5' },
  fex: { WINEMSYNC: '1', FEX_X87REDUCEDPRECISION: '0' },
};
const globalsWith = data => ({ document: { documentElement: { lang: 'en' } },
                               MSCXDefaultsData: JSON.parse(JSON.stringify(data)) });
const settle = () => new Promise(res => setImmediate(res));
const OK = { BSuccess: () => true, GetEResult: () => 1 };
const REFUSED = { BSuccess: () => false, GetEResult: () => 2 };
const PARTLY = { BSuccess: () => false, GetEResult: () => 129 };

function hooks() {
  const state = [];
  const cleanups = [];
  let at = 0;
  return {
    use: init => {
      const i = at++;
      if (!(i in state)) state[i] = init;
      return [state[i], v => { state[i] = typeof v === 'function' ? v(state[i]) : v; }];
    },
    effect: fn => {
      const i = at++;
      if (!(i in state)) { state[i] = true; cleanups.push(fn() || (() => {})); }
    },
    render: fn => { at = 0; return walk(fn({})); },
    unmount: () => cleanups.splice(0).forEach(f => f()),
  };
}

function connect(g, h, reply = () => OK) {
  const events = new EventTarget();
  const sent = [];
  g.addEventListener = events.addEventListener.bind(events);
  g.removeEventListener = events.removeEventListener.bind(events);
  g.dispatchEvent = events.dispatchEvent.bind(events);
  g.MSCXUseState = h.use;
  g.MSCXUseEffect = h.effect;
  g.MSCXSpecifyRoute = (route, appid, text) => {
    sent.push({ route, appid, text });
    return Promise.resolve(reply(route));
  };
  return sent;
}

const BUILDS = [
  { id: 'notproton-26.1', build: '26.1', runner: 'rosetta', label: 'CrossOver 26.1', override: null },
  { id: 'notproton-26.1-fex', build: '26.1', runner: 'fex', label: 'CrossOver 26.1 (FEX)',
    override: { WINEMSYNC: '0' } },
  { id: 'notproton-25.0', build: '25.0', runner: 'rosetta', label: 'CrossOver 25', override: null },
];

const settingsRow = (ns, re) => ns.find(x => x.type === 'Field' && re.test(x.props.label) &&
  x.props.childrenContainerWidth === 'min' && x.props.children && x.props.children.type === 'Button' &&
  x.props.children.props.className === 'MSCXSetBtn');
const fieldButton = (ns, re) => { const f = settingsRow(ns, re); return f && f.props.children; };
const field = (ns, label) => ns.find(x => x.type === 'FieldDropdown' && x.props.label === label);
const row = (ns, label) => ns.find(x => x.type === 'Toggle' && x.props.label === label);

function openPage(form, builds, { tool, reply, data, lang } = {}) {
  const g = data ? { document: { documentElement: { lang: 'en' } } } : globalsWith(SAVED);
  if (lang) g.document.documentElement.lang = lang;
  if (builds) g.MSCXBuilds = JSON.parse(JSON.stringify(builds));
  if (tool !== undefined) g.MSCXDefaultTool = tool;
  const h = hooks();
  const sent = connect(g, h, reply);
  const page = panel(emit, form, g, { fexTools: FEX_TOOLS, data }).defaultsPage;
  return { g, h, sent, r: () => h.render(page) };
}

function oneKindCases(form) {
  const t = runner(form + ' one kind');
  if (form === 'component') return t.failed;
  const label = ns => (ns.find(x => x.type === 'Field' && /^Apply as defaults/.test(x.props.label)) || {}).props;

  let { r } = openPage(form, BUILDS.filter(x => x.runner === 'rosetta'));
  t.ok(label(r()).label === 'Apply as defaults for all CrossOver Compatibility Tools',
       `only Rosetta installed says CrossOver (${label(r()).label})`);

  ({ r } = openPage(form, BUILDS.filter(x => x.runner === 'fex')));
  t.ok(row(r(), X87), 'only FEX installed opens on FEX');
  t.ok(label(r()).label === 'Apply as defaults for all CrossOver Compatibility Tools', 'and says CrossOver');

  ({ r } = openPage(form, BUILDS));
  t.ok(label(r()).label === 'Apply as defaults for all Rosetta Compatibility Tools', 'both kinds name the runner');
  return t.failed;
}

function defaultToolCases(form) {
  const t = runner(form + ' default tool');
  if (form === 'component') return t.failed;
  const ver = ns => field(ns, 'CrossOver version').props.selectedOption;
  const kind = ns => (row(ns, X87) ? 1 : 0);
  const told = (g, tool) => g.dispatchEvent(new CustomEvent('mscxdefaulttool', { detail: tool }));

  let o = openPage(form, BUILDS, { tool: 'notproton-25.0' });
  t.ok(ver(o.r()) === 'notproton-25.0' && kind(o.r()) === 0, 'opens on the default tool');
  o = openPage(form, BUILDS, { tool: 'notproton-26.1-fex' });
  t.ok(ver(o.r()) === 'notproton-26.1-fex' && kind(o.r()) === 1, 'a FEX default tool opens on FEX');
  o = openPage(form, BUILDS, { tool: 'proton_9' });
  t.ok(ver(o.r()) === 'notproton-26.1', 'a default that is not CrossOver opens on the first version');
  o = openPage(form, BUILDS);
  t.ok(ver(o.r()) === 'notproton-26.1', 'so does no default at all');

  o = openPage(form, BUILDS, { tool: 'notproton-26.1' });
  o.r();
  told(o.g, 'notproton-26.1-fex');
  t.ok(ver(o.r()) === 'notproton-26.1-fex' && kind(o.r()) === 1, 'changing the default tool above follows along');
  told(o.g, 'proton_9');
  t.ok(ver(o.r()) === 'notproton-26.1-fex', 'and a tool that is not CrossOver leaves it where it is');
  o.h.unmount();
  told(o.g, 'notproton-25.0');
  t.ok(ver(o.r()) === 'notproton-26.1-fex', 'a page that has gone stops listening');
  return t.failed;
}

async function italianCases(form) {
  const t = runner(form + ' italian');
  if (form === 'component') return t.failed;
  const { r } = openPage(form, BUILDS.filter(x => x.runner === 'rosetta'), { lang: 'it' });
  const head = r().find(x => x.type === 'Section' && x.props.label === 'Impostazioni di compatibilit\u00e0 predefinite');
  t.ok(head, 'the heading is in Italian');
  t.ok(field(r(), 'Versione di CrossOver'), 'so is the version menu');
  const applyRow = () => settingsRow(r(), /^Applica come predefinite/);
  t.ok(applyRow() && applyRow().props.label ===
       'Applica come predefinite a tutti gli strumenti di compatibilit\u00e0 CrossOver' &&
       applyRow().props.children.props.children === 'Applica', 'and the apply row');
  applyRow().props.children.props.onClick();
  await settle(); await settle();
  t.ok(applyRow().props.description ===
       'Applicate. Ora tutti gli strumenti di compatibilit\u00e0 CrossOver usano queste impostazioni.',
       `and the note after applying (${applyRow().props.description})`);
  return t.failed;
}

function splicedCases(form) {
  const t = runner(form + ' spliced');
  if (form === 'component') return t.failed;
  const { g, r } = openPage(form, null, { data: true });
  r();
  t.ok(JSON.stringify(g.MSCXDefaultsData) === '{"rosetta":{"MTL_HUD_ENABLED":"1"},"fex":{"WINEMSYNC":"1"}}',
       `the page parses the defaults C wrote, without the lines it left out (${JSON.stringify(g.MSCXDefaultsData)})`);
  t.ok(g.MSCXBuilds.map(b => b.id).join(',') === 'notproton-26.1,notproton-26.1-fex,notproton-empty',
       `and the builds, without the one whose label could break out (${g.MSCXBuilds.map(b => b.id)})`);
  t.ok(g.MSCXBuilds[0].override === null && g.MSCXBuilds[1].override.WINEMSYNC === '0' &&
       JSON.stringify(g.MSCXBuilds[2].override) === '{}' && g.MSCXBuilds[1].runner === 'fex',
       'a build has null, its own set, or an empty one');
  return t.failed;
}

async function buildCases(form) {
  const t = runner(form + ' builds');
  const g = globalsWith(SAVED);
  g.MSCXBuilds = JSON.parse(JSON.stringify(BUILDS));
  const h = hooks();
  const page = panel(emit, form, g, { fexTools: FEX_TOOLS }).defaultsPage;
  if (form === 'component') return t.failed;

  t.ok(h.render(page).length === 0, 'the page waits for its gates');
  let reply = () => OK;
  const sent = connect(g, h, route => reply(route));
  let p = h.render(page);
  t.ok(field(p, 'CrossOver version'), 'the page mounts once its gates show up');
  t.ok(!field(p, 'Select default settings for'), 'there is no Rosetta or FEX picker, the version picks the runner');

  const version = () => field(h.render(page), 'CrossOver version');
  const applyRow = () => settingsRow(h.render(page), /^Apply as defaults for all Rosetta Compatibility Tools$/);
  const apply = () => fieldButton(h.render(page), /^Apply as defaults for all Rosetta Compatibility Tools$/);
  const last = () => sent[sent.length - 1];
  t.ok(version().props.selectedOption === 'notproton-26.1' && !row(p, X87),
       'the page opens on the first installed version and its runner');
  t.ok(version().props.rgOptions.map(o => o.data).join(',') === 'notproton-26.1,notproton-26.1-fex,notproton-25.0',
       `version lists every build and nothing else (${version().props.rgOptions.map(o => o.label)})`);
  t.ok(apply() && !apply().props.disabled && !applyRow().props.disabled, 'the apply row is on from the start');
  t.ok(applyRow().props.description === undefined, 'nothing says it was applied before it is');

  version().props.onChange({ data: 'notproton-26.1-fex' });
  t.ok(row(h.render(page), X87), 'picking a FEX build switches the runner to FEX');

  version().props.onChange({ data: 'notproton-26.1' });
  p = h.render(page);
  t.ok(row(p, 'Metal HUD').props.checked === true, 'a build without its own set shows the runner\'s');

  row(p, 'MSync').props.onChange(true);
  await settle();
  const lines = () => last().text.split('\n');
  t.ok(last().route === 'NotProton.SetToolDefaults#1' && lines()[0] === 'notproton-26.1',
       `it saves to that tool (${JSON.stringify(last())})`);
  t.ok(lines().slice(1).sort().join(';') ===
       'CX_GRAPHICS_BACKEND=dxmt;DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5;' +
       'DXMT_METALFX_SPATIAL_SWAPCHAIN=1;MTL_HUD_ENABLED=1;ROSETTA_ADVERTISE_AVX=0;WINEMSYNC=1',
       'starting from the runner\'s set');
  t.ok(g.MSCXBuilds[0].override.WINEMSYNC === '1' && !('WINEMSYNC' in g.MSCXDefaultsData.rosetta),
       'the build gets its own set and the runner\'s is left alone');
  t.ok(version().props.rgOptions.every(o => !/own settings/.test(o.label)) && !fieldButton(h.render(page), /^Use /),
       'nothing marks a build as having its own set, and nothing offers to undo it');

  g.MSCXDefaultsData.rosetta.NOTPROTON_RETINA = '1';
  t.ok(row(h.render(page), 'High Resolution').props.checked === false,
       'a build with its own set no longer follows the runner\'s');

  const gp = panel(emit, form, g, { fexTools: FEX_TOOLS.concat('notproton-26.1-fex') }), games = gp.render;
  const g2written = () => (gp.written.length ? gp.written[gp.written.length - 1].opts : '');
  const game = tool => walk(games({ details: details('%command%', { strCompatToolName: tool }) }));
  t.ok(row(game('notproton-26.1'), 'MSync').props.checked === true &&
       row(game('notproton-25.0'), 'MSync').props.checked === false,
       'a game shows its own build\'s defaults');
  t.ok(row(game('notproton-26.1-fex'), 'MSync').props.checked === false &&
       row(game('notproton-fex'), 'MSync').props.checked === true,
       'a FEX build\'s set beats the FEX defaults only for that build');

  version().props.onChange({ data: 'notproton-25.0' });
  t.ok(row(h.render(page), 'High Resolution').props.checked === true,
       'a build nobody changed follows a change to the runner\'s');
  row(h.render(page), 'Metal HUD').props.onChange(false);
  await settle();
  t.ok(g.MSCXBuilds[2].override, 'and 25 its own set');

  version().props.onChange({ data: 'notproton-26.1' });
  reply = () => REFUSED;
  const quiet = console.error; console.error = () => {};
  apply().props.onClick();
  await settle(); await settle();
  console.error = quiet;
  t.ok(g.MSCXBuilds[0].override && g.MSCXBuilds[2].override && !('WINEMSYNC' in g.MSCXDefaultsData.rosetta),
       'a refused apply leaves every set as it was');
  t.ok(applyRow().props.description === undefined, 'and does not say it was applied');

  reply = () => OK;
  const before = sent.length;
  apply().props.onClick();
  await settle(); await settle();
  t.ok(sent.length === before + 1 && last().route === 'NotProton.ApplyToolDefaults#1' &&
       last().text === 'notproton-26.1', `apply is one request for the tool shown (${JSON.stringify(last())})`);
  t.ok(g.MSCXDefaultsData.rosetta.WINEMSYNC === '1', 'the runner defaults now include what the build had');
  t.ok(g.MSCXBuilds[0].override === null && g.MSCXBuilds[2].override === null && g.MSCXBuilds[1].override,
       'every Rosetta build follows them again and the FEX one keeps its own');
  t.ok(applyRow().props.description === 'Applied. Every Rosetta Compatibility Tool now uses these settings.',
       `the row says it was applied (${applyRow().props.description})`);
  row(h.render(page), 'Metal HUD').props.onChange(false);
  await settle();
  t.ok(applyRow().props.description === undefined, 'changing a setting clears that note');
  version().props.onChange({ data: 'notproton-25.0' });
  apply().props.onClick();
  await settle(); await settle();
  version().props.onChange({ data: 'notproton-26.1' });
  t.ok(applyRow().props.description === undefined, 'so does picking another version');

  let release;
  reply = route => route === 'NotProton.ApplyToolDefaults#1' ? new Promise(res => { release = () => res(OK); }) : OK;
  apply().props.onClick();
  await settle();
  version().props.onChange({ data: 'notproton-26.1-fex' });
  release();
  await settle(); await settle();
  const fexRow = settingsRow(h.render(page), /^Apply as defaults for all FEX Compatibility Tools$/);
  t.ok(fexRow && fexRow.props.description === undefined,
       `switching runner while it is on its way keeps the note off the other runner (${fexRow && fexRow.props.description})`);
  version().props.onChange({ data: 'notproton-26.1' });
  apply().props.onClick();
  await settle();
  row(h.render(page), 'MSync').props.onChange(false);
  release();
  await settle(); await settle(); await settle();
  t.ok(applyRow().props.description === undefined, 'and so does a change made while it is on its way');

  reply = () => PARTLY;
  const said = [];
  console.error = (...a) => said.push(a.join(' '));
  const shown = g.MSCXBuilds[0].override || g.MSCXDefaultsData.rosetta;
  apply().props.onClick();
  await settle(); await settle();
  console.error = quiet;
  t.ok(h.render(page).length === 0, 'a partial apply hides the page, so nothing stale saves over it');
  t.ok(said.length === 1 && /until Steam restarts/.test(said[0]), `and says so once (${said.join(' | ')})`);
  t.ok(JSON.stringify(g.MSCXDefaultsData.rosetta) === JSON.stringify(shown),
       'game panels get the set that did save');
  g.MSCXBuilds[0].override = { WINEMSYNC: '1' };
  const after = tool => walk(games({ details: details('%command%', { strCompatToolName: tool }) }));
  t.ok(row(after('notproton-26.1'), 'MSync').props.checked === false,
       'game panels stop showing build sets that may be gone');
  row(after('notproton-26.1'), 'Metal HUD').props.onChange(false);
  t.ok(/MTL_HUD_ENABLED=0/.test(g2written()), `and a choice saves to the game itself (${g2written()})`);
  delete g.MSCXDefaultsLost;
  return t.failed;
}

async function main() {
let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form, globalsWith(SAVED), { fexTools: FEX_TOOLS });
  const t = runner(form);
  const nodes = (opts, tool = 'notproton') =>
    walk(P({ details: details(opts, { strCompatToolName: tool }) }));
  const dropdowns = ns => ns.filter(x => x.type === 'Dropdown');
  const last = () => (written.length ? written[written.length - 1].opts : null);

  let r = nodes('%command%');
  t.ok(dropdowns(r)[0].props.selectedOption === 'dxmt', 'an unset backend shows the default');
  t.ok(row(r, 'Metal HUD').props.checked === true, 'an unset row shows the default');
  t.ok(row(r, AVX).props.checked === false, 'the AVX2 default of 0 shows off');
  t.ok(dropdowns(r)[1].props.selectedOption === '1.5', 'an unset upscaler shows the default factor');
  t.ok(!r.some(x => (x.type === 'Button' || x.type === 'button') && x.props.children === 'Reset to defaults'),
       'a game has no Reset to defaults');

  r = nodes('MTL_HUD_ENABLED=0 CX_GRAPHICS_BACKEND=auto %command%');
  t.ok(row(r, 'Metal HUD').props.checked === false, "the game's 0 wins over the default");
  t.ok(dropdowns(r)[0].props.selectedOption === '', "the game's Automatic wins over the default");

  r = nodes("DXMT_CONFIG='d3d11.preferredMaxFrameRate=60' %command%");
  t.ok(dropdowns(r)[1].props.selectedOption === '1.5',
       'a DXMT_CONFIG without a factor shows the default factor');
  r = nodes("DXMT_CONFIG='d3d11.metalSpatialUpscaleFactor=3.0' %command%");
  t.ok(dropdowns(r)[1].props.selectedOption === '3.0', "the game's factor wins over the default");

  r = nodes('WINEDEBUG=x %command%', 'notproton-fex');
  t.ok(row(r, 'MSync').props.checked === true && row(r, X87).props.checked === false,
       'a FEX game shows the FEX defaults');
  t.ok(row(r, 'Metal HUD').props.checked === false && dropdowns(r)[0].props.selectedOption === '',
       'a FEX game ignores the Rosetta defaults');

  written.length = 0;
  row(nodes('MTL_HUD_ENABLED=1 %command%'), 'MSync').props.onChange(true);
  t.ok(last() === 'WINEMSYNC=1 MTL_HUD_ENABLED=1 %command%',
       `a value set by hand that matches the default stays (${last()})`);
  written.length = 0;
  row(nodes('%command%'), 'Metal HUD').props.onChange(false);
  t.ok(last() === 'MTL_HUD_ENABLED=0 %command%', `turning a default off writes 0 (${last()})`);
  written.length = 0;
  dropdowns(nodes('%command%'))[0].props.onChange({ data: '' });
  t.ok(last() === 'CX_GRAPHICS_BACKEND=auto %command%', `Automatic writes auto (${last()})`);

  written.length = 0;
  row(nodes('WINEDEBUG=x MTL_HUD_ENABLED=0 %command%'), 'Metal HUD').props.onChange(true);
  t.ok(last() === 'WINEDEBUG=x %command%', `turning a row back to its default follows it again (${last()})`);
  written.length = 0;
  dropdowns(nodes('CX_GRAPHICS_BACKEND=dxvk %command%'))[0].props.onChange({ data: 'dxmt' });
  t.ok(last() === '', `so does picking the default backend (${last()})`);
  written.length = 0;
  dropdowns(nodes('DXMT_METALFX_SPATIAL_SWAPCHAIN=0 %command%'))[1].props.onChange({ data: '1.5' });
  t.ok(last() === '', `and the default upscaler (${last()})`);
  written.length = 0;
  row(nodes('FEX_X87REDUCEDPRECISION=1 %command%', 'notproton-fex'), X87).props.onChange(false);
  t.ok(last() === '', `and a FEX row turned back to its default (${last()})`);
  written.length = 0;
  row(nodes('ROSETTA_ADVERTISE_AVX=1 %command%'), AVX).props.onChange(false);
  t.ok(last() === '', `and a row whose default is 0 (${last()})`);

  const D = panel(emit, form, globalsWith(SAVED)).defaultsPage;
  if (form === 'component') {
    t.ok(D === null, 'the old page has no Settings page');
    failed += t.failed;
    continue;
  }
  t.ok(D && D({}) === null, 'the Settings page shows nothing without its gates');

  {
    const h = hooks();
    const g = globalsWith(SAVED);
    let reply = OK;
    const sent = connect(g, h, () => reply);
    const page = panel(emit, form, g).defaultsPage;
    const quiet = console.error;
    let warned = '';
    {
      const bare = hooks();
      const g2 = globalsWith(SAVED);
      connect(g2, bare);
      const renamed = panel(emit, form, g2, { drop: ['D0'] }).defaultsPage;
      const said = [];
      console.error = (...a) => { said.push(a.join(' ')); };
      const first = bare.render(renamed), again = bare.render(renamed);
      console.error = quiet;
      t.ok(first.length === 0 && again.length === 0, 'the page hides when Steam renames a component it takes');
      t.ok(said.length === 1 && /renamed its settings components/.test(said[0]),
           `and says so once (${said.join(' | ')})`);
    }
    {
      const bare = hooks();
      const g2 = globalsWith({ rosetta: SAVED.rosetta, fex: null });
      const sent2 = connect(g2, bare);
      const unread = panel(emit, form, g2).defaultsPage;
      const said = [];
      console.error = (...a) => { said.push(a.join(' ')); };
      const first = bare.render(unread), again = bare.render(unread);
      console.error = quiet;
      t.ok(first.length === 0 && again.length === 0 && sent2.length === 0,
           'the page hides when the saved defaults could not be read, so nothing saves over them');
      t.ok(said.length === 1 && /could not be read/.test(said[0]), `and says so once (${said.join(' | ')})`);
      const P2 = panel(emit, form, g2, { fexTools: FEX_TOOLS }).render;
      const game = walk(P2({ details: details('%command%', { strCompatToolName: FEX_TOOLS[0] }) }));
      t.ok(row(game, 'MSync') && row(game, 'MSync').props.checked === false,
           'game panels still show, with nothing defaulted');
    }
    console.error = (...a) => { warned = a.join(' '); };

    let p = h.render(page);
    t.ok(p.some(x => x.type === 'Section' && x.props.label === 'Default Compatibility Settings'),
         'the page is headed Default Compatibility Settings');
    t.ok(row(p, 'Metal HUD').props.checked === true && row(p, AVX).props.checked === false,
         'Rosetta shows its saved defaults');
    t.ok(!p.some(x => x.props && x.type === 'Button' && x.props.children === 'Reset to defaults'),
         'the page has no Reset to defaults');
    t.ok(!p.some(x => x.type === 'Section' && x.props.label === 'Launch Executable'), 'the page has no Launch Executable section');

    const runnerLines = i => sent[i].text.split('\n').sort().join(';');
    row(p, 'MSync').props.onChange(true);
    await settle();
    t.ok(sent.length === 1 && sent[0].route === 'NotProton.SetDefaults#1' && sent[0].appid === 0,
         'with no version installed a change sends the Rosetta defaults');
    t.ok(runnerLines(0) ===
         'CX_GRAPHICS_BACKEND=dxmt;DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=1.5;' +
         'DXMT_METALFX_SPATIAL_SWAPCHAIN=1;MTL_HUD_ENABLED=1;ROSETTA_ADVERTISE_AVX=0;WINEMSYNC=1',
         `it sends every saved line plus the change (${JSON.stringify(sent[0].text)})`);
    t.ok(g.MSCXDefaultsData.rosetta.WINEMSYNC === '1', 'a saved change reaches the game panels');
    t.ok(row(h.render(page), 'MSync').props.checked === true, 'the page shows the saved change');

    dropdowns(h.render(page))[0].props.onChange({ data: '' });
    await settle();
    t.ok(!/CX_GRAPHICS_BACKEND/.test(sent[1].text), 'Automatic takes the backend out of the defaults');
    t.ok(!('CX_GRAPHICS_BACKEND' in g.MSCXDefaultsData.rosetta), 'and out of the panels');

    const upscaler = dropdowns(h.render(page)).find(x => x.props.rgOptions.some(o => o.data === '1.5'));
    upscaler.props.onChange({ data: '' });
    await settle();
    t.ok(/DXMT_METALFX_SPATIAL_SWAPCHAIN=0/.test(sent[2].text) && !/DXMT_CONFIG/.test(sent[2].text),
         `upscaling off saves 0 and drops the factor (${JSON.stringify(sent[2].text)})`);

    reply = REFUSED;
    const before = JSON.stringify(g.MSCXDefaultsData);
    let logged = '';
    console.error = (...a) => { logged = a.join(' '); warned = /renamed/.test(a.join(' ')) ? a.join(' ') : warned; };
    row(h.render(page), 'Metal HUD').props.onChange(false);
    await settle();
    console.error = (...a) => { warned = a.join(' '); };
    t.ok(JSON.stringify(g.MSCXDefaultsData) === before, 'a failed save changes nothing');
    t.ok(/not saved, result 2/.test(logged), `a failed save is logged (${logged})`);

    g.MSCXBuilds = [{ id: 'notproton-fex', build: '26.1', runner: 'fex', label: 'CrossOver 26.1 (FEX)', override: null }];
    field(h.render(page), 'CrossOver version').props.onChange({ data: 'notproton-fex' });
    p = h.render(page);
    t.ok(row(p, X87) && !row(p, AVX), 'FEX shows the FEX rows');
    t.ok(row(p, 'MSync').props.checked === true && row(p, X87).props.checked === false,
         'FEX shows its saved defaults');
    t.ok(!dropdowns(p)[0].props.rgOptions.some(o => o.data === 'd3dmetal'), 'FEX offers no D3DMetal');
    reply = OK;
    row(p, X87).props.onChange(true);
    await settle();
    const toolLines = i => sent[i].text.split('\n').slice(1).sort().join(';');
    t.ok(sent[sent.length - 1].route === 'NotProton.SetToolDefaults#1' &&
         sent[sent.length - 1].text.split('\n')[0] === 'notproton-fex' &&
         toolLines(sent.length - 1) === 'FEX_X87REDUCEDPRECISION=1;WINEMSYNC=1',
         `a FEX version starts from the FEX defaults (${JSON.stringify(sent[sent.length - 1])})`);
    t.ok(g.MSCXDefaultsData.rosetta.MTL_HUD_ENABLED === '1', 'saving FEX leaves Rosetta alone');

    p = h.render(page);
    row(p, 'Metal HUD').props.onChange(true);
    row(p, 'High Resolution').props.onChange(true);
    await settle();
    await settle();
    t.ok(toolLines(sent.length - 1) === 'FEX_X87REDUCEDPRECISION=1;MTL_HUD_ENABLED=1;NOTPROTON_RETINA=1;WINEMSYNC=1',
         `two quick changes both get saved (${JSON.stringify(sent[sent.length - 1].text)})`);
    t.ok(g.MSCXBuilds[0].override.MTL_HUD_ENABLED === '1' && g.MSCXBuilds[0].override.NOTPROTON_RETINA === '1',
         'and both reach the game panels');
    console.error = quiet;
    t.ok(!/renamed/.test(warned), 'nothing says a component is missing while Steam has them all');
    failed += t.failed;
  }
  failed += await buildCases(form);
  failed += oneKindCases(form);
  failed += defaultToolCases(form);
  failed += splicedCases(form);
  failed += await italianCases(form);
}
return failed;
}

main().then(failed => {
  console.log(failed ? `\n${failed} failure(s)` : '\ndefaults pass in both shapes');
  process.exit(failed ? 1 : 0);
}, e => { console.error(e); process.exit(1); });
