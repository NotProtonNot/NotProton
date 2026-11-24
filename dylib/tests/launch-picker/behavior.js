// Runs the patched plugin launch choices from gatecheck's output against a stand-in client.
'use strict';
const fs = require('fs');
const path = require('path');

const files = process.argv.slice(2);
if (!files.length) { console.error('usage: behavior.js <patched.js>...'); process.exit(2); }

let failed = 0;
const ok = (name, cond, what) => {
  if (!cond) failed++;
  if (!cond || process.env.VERBOSE) console.log(`  ${cond ? 'PASS' : 'FAIL'}  [${name}] ${what}`);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// The block that wraps the client sits between the picker's handle and the picker itself.
function wrapper(src) {
  const head = src.indexOf('globalThis.MSCXLaunchOptions=');
  if (head < 0) throw new Error('no picker handle');
  const from = src.indexOf('l);', head) + 3;
  const to = src.slice(from).search(/async function {2}[\w$]+\(/);
  if (to < 0) throw new Error('no picker after the wrapper');
  return src.slice(from, from + to);
}

const ID = 2189718462;
const GAME = ((BigInt(ID) << 32n) | 0x02000000n).toString();
const ENTRIES = [
  { k: 'NOTPROTON_HUB', on: '1', l: 'Launcher', a: '' },
  { k: 'NOTPROTON_HUB', on: '1', l: 'A game', a: '--game=a' },
];

// A client with one shortcut, the details store, NotProton's routes and Steam's picker.
function client(js, { opts = 'NOTPROTON_HUB=1 %command%', json = JSON.stringify(ENTRIES), picker = true,
                      route = true, details = 'now', keep = 'yes' } = {}) {
  const c = { runs: [], shown: [], asked: [], picks: [] };
  const d = { strLaunchOptions: opts };
  globalThis.SteamClient = { Apps: {
    RunGame(...a) { c.runs.push(a); },
    GetLaunchOptionsForApp(id) { c.asked.push(id); return Promise.resolve([{ nIndex: 0, strDescription: 'client' }]); },
  } };
  globalThis.appDetailsStore = { RegisterForAppData(id, cb) {
    cb(details === 'now' ? d : undefined);
    if (details === 'later') setTimeout(() => cb(d), 20);
    return { unregister() {} };
  } };
  globalThis.MSCXRoute = route ? () => Promise.resolve(json) : undefined;
  globalThis.MSCXSpecifyRoute = keep === 'none' ? undefined : (r, id, a) => {
    c.picks.push([r, id, a]);
    return keep === 'no' ? Promise.reject('no transport') : Promise.resolve({ BSuccess: () => keep === 'yes', GetEResult: () => 2 });
  };
  globalThis.MSCXLaunchOptions = picker ? (t, list) => c.shown.push({ t, list }) : undefined;
  (0, eval)(js);
  return c;
}

const settle = ms => new Promise(r => setTimeout(r, ms));

// The picker handle and the setting's factory, each run against stand-ins for what they wrap.
function handles(name, src) {
  const pick = /globalThis\.MSCXLaunchOptions=\(t,l\)=>([\w$]+)\((\{ownerWindow:[^}]*\}),l\);/.exec(src);
  ok(name, pick, 'the picker handle is there');
  if (pick) {
    const calls = [];
    const shown = (t, l) => calls.push({ t, l });
    globalThis.SteamUIStore = { ActiveWindowInstance: { BrowserWindow: 'main' } };
    const handle = new Function(pick[1], `return (t,l)=>${pick[1]}(${pick[2]},l)`)(shown);
    handle({ appid: 1 }, ['x']);
    ok(name, calls[0]?.t.ownerWindow === 'main' && calls[0]?.t.appid === 1 && same(calls[0]?.l, ['x']),
       'the picker opens over the window Steam is using, like its own launches');
    handle({ appid: 1, ownerWindow: 'mine' }, []);
    ok(name, calls[1]?.t.ownerWindow === 'mine', 'a caller\'s own window wins');
    globalThis.SteamUIStore = undefined;
    handle({ appid: 1 }, []);
    ok(name, calls[2] && calls[2].t.ownerWindow === undefined, 'no UI store yet still opens the picker');
  }

  const reg = /"DefaultLaunchOption",\{get:\(\)=>\(d=>([\w$]+)\.createElement\(([\w$]+),\{details:d\}\)\)/.exec(src);
  ok(name, reg, 'the default launch option setting is handed out');
  if (reg) {
    const react = { createElement: (type, props) => ({ type, props }) };
    const setting = function DefaultLaunchOption() {};
    const make = new Function(reg[1], reg[2], `return d=>${reg[1]}.createElement(${reg[2]},{details:d})`)(react, setting);
    const el = make({ unAppID: ID });
    ok(name, el.type === setting && el.props.details.unAppID === ID, 'it renders Steam\'s own setting for the details given');
  }
  ok(name, /globalThis\.MSCXUI\?\.DefaultLaunchOption\?\.\([\w$]+\)\?\?null,/.test(src),
     'the shortcut page asks for it, and renders nothing when it isn\'t there');
}

async function run(file) {
  const name = path.basename(file);
  const src = fs.readFileSync(file, 'utf8');
  handles(name, src);
  const js = wrapper(src);
  const quiet = console.error;

  let c = client(js);
  const list = await SteamClient.Apps.GetLaunchOptionsForApp(ID);
  ok(name, same(list.map(o => [o.nIndex, o.strDescription]), [[0, 'Launcher'], [1, 'A game']]),
     'a shortcut with its row on reports the choices as launch options');
  ok(name, same(await SteamClient.Apps.GetLaunchOptionsForApp(ID), list),
     'the same list each time, so the choice Steam remembers keeps its key');
  ok(name, same(await SteamClient.Apps.GetLaunchOptionsForApp(220240), [{ nIndex: 0, strDescription: 'client' }])
           && same(c.asked, [220240]), 'a Steam game asks the client');

  c = client(js);
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(5);
  ok(name, c.shown.length === 1 && c.runs.length === 0, 'Play opens Steam\'s picker and waits');
  ok(name, c.shown[0]?.t.appid === ID && same(c.shown[0]?.list, list), 'the picker gets the shortcut and its list');
  c.shown[0]?.t.continue(1);
  ok(name, c.runs.length === 0, 'nothing starts before NotProton has the pick');
  await settle(5);
  ok(name, same(c.picks, [['NotProton.PluginLaunchPick#1', ID, '--game=a']]) &&
           same(c.runs, [[GAME, '', -1, 7]]), 'the pick goes to NotProton, then the shortcut starts');
  c.shown[0]?.t.continue(0);
  await settle(5);
  ok(name, same(c.picks[1], ['NotProton.PluginLaunchPick#1', ID, '']) && same(c.runs[1], [GAME, '', -1, 7]),
     'a choice without arguments clears any earlier pick and starts');

  console.error = () => {};
  for (const keep of ['no', 'refused']) {
    c = client(js, { keep });
    SteamClient.Apps.RunGame(GAME, '', -1, 7);
    await settle(5);
    c.shown[0]?.t.continue(1);
    await settle(5);
    ok(name, same(c.runs, [[GAME, '', -1, 7]]), `a pick NotProton ${keep === 'no' ? 'never got' : 'refused'} still starts the shortcut`);
  }
  console.error = quiet;

  c = client(js, { details: 'later' });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(60);
  ok(name, c.shown.length === 1 && c.runs.length === 0, 'details still loading are waited for');

  // Details that never come give up after a few seconds; jump the clock rather than wait.
  const timer = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms, ...a) => timer(fn, ms >= 1000 ? 0 : ms, ...a);
  c = client(js, { details: 'never' });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(20);
  globalThis.setTimeout = timer;
  ok(name, c.shown.length === 0 && c.runs.length === 1, 'details that never come mean a plain launch');

  c = client(js, { opts: 'OTHER=1 %command%' });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(5);
  ok(name, c.shown.length === 0 && c.runs.length === 1 &&
           (await SteamClient.Apps.GetLaunchOptionsForApp(ID))[0].strDescription === 'client',
     'a row switched off changes nothing');

  c = client(js, { opts: '%command% NOTPROTON_HUB=1' });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(5);
  ok(name, c.shown.length === 0, 'KEY=1 after %command% is an argument, not the row');

  c = client(js, { opts: "NOTPROTON_HUB='1' %command%", json: JSON.stringify([ENTRIES[0]]) });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(5);
  ok(name, c.shown.length === 0 && c.runs.length === 1, 'a single choice is a plain launch');

  c = client(js);
  SteamClient.Apps.RunGame('220240', '', -1, 7);
  ok(name, c.shown.length === 0 && same(c.runs, [['220240', '', -1, 7]]), 'a Steam game starts straight away');

  c = client(js);
  SteamClient.Apps.RunGame(GAME, '-x', -1, 7);
  ok(name, same(c.runs, [[GAME, '-x', -1, 7]]), 'a launch that already has arguments starts straight away');

  c = client(js, { picker: false });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  ok(name, c.runs.length === 1, 'no picker to hand means a plain launch');

  c = client(js, { keep: 'none' });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  ok(name, c.runs.length === 1 && c.shown.length === 0, 'nowhere to hand the pick means a plain launch');

  c = client(js, { route: false });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(5);
  ok(name, c.shown.length === 0 && c.runs.length === 1, 'no NotProton route means a plain launch');

  console.error = () => {};
  c = client(js, { json: 'not json' });
  SteamClient.Apps.RunGame(GAME, '', -1, 7);
  await settle(5);
  console.error = quiet;
  ok(name, c.shown.length === 0 && c.runs.length === 1, 'a bad answer means a plain launch');

  c = client(js);
  const wrapped = SteamClient.Apps.RunGame;
  (0, eval)(js);
  ok(name, SteamClient.Apps.RunGame === wrapped, 'a second copy of the script wraps nothing twice');
}

(async () => {
  for (const f of files) await run(f);
  if (failed) process.exit(1);
  console.log(`==> launch picker: ${files.length} patched file(s) behave`);
})();
