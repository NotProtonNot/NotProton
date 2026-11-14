// The script the store's pages are given, run against a page made of just enough to
// stand on: what it says about a game, where it puts it, and that it says the same
// thing advice.c says about a game that is not installed.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'feats/store_page.js'), 'utf8');
const advice = fs.readFileSync(path.join(root, 'feats/advice.c'), 'utf8');

let failed = 0;
const ok = (cond, what) => { if (!cond) failed++; console.log(`  ${cond ? 'ok  ' : 'FAIL'}  ${what}`); };

function node(tag) {
  const n = { tag, style: {}, children: [], dataset: {}, attrs: {}, isConnected: true, textContent: '',
    append(...c) { for (const x of c) { if (x && typeof x === 'object') x.parent = n; n.children.push(x); } },
    replaceChildren(...c) { n.children = []; n.append(...c); },
    setAttribute(k, v) { n.attrs[k] = v; },
    querySelector(sel) { return find(n, sel); },
  };
  return n;
}
function find(n, sel) {
  for (const c of n.children) {
    if (!c || typeof c !== 'object') continue;
    if (sel === '.Panel' && c.className === 'Panel') return c;
    if (sel === '.notproton-mac-chip' && c.className === 'notproton-mac-chip') return c;
    const deep = find(c, sel);
    if (deep) return deep;
  }
  return null;
}
const text = n => !n || typeof n !== 'object' ? '' : (n.textContent || '') + n.children.map(text).join(' ');

// A page: where it is, what the store marked up on it, and what its own endpoints say.
function page({ pathname, map = {}, mac = false, anticheat = null, deck = true, report = {}, platforms = {}, rows = [] }) {
  const inserted = [];
  const deckBlock = { parentNode: { insertBefore: b => inserted.push(b) } };
  const notice = anticheat && { textContent: anticheat.text,
    querySelector: s => s === '.anticheat_name' ? { firstChild: { textContent: anticheat.name } } : null };
  const fetched = [];
  const stored = {};
  const document = {
    documentElement: {}, getElementById: id => inserted.find(b => b.id === id) || null,
    createElement: node, createElementNS: (ns, tag) => node(tag), addEventListener() {},
    querySelector: s => s.includes('deck-verified-results') ? (deck ? deckBlock : null)
      : s === '.anticheat_section' ? notice : s === '.platform_img.mac' ? (mac ? {} : null) : null,
    querySelectorAll: s => s.includes('WishlistItem-') ? rows : [],
  };
  const window = { addEventListener() {} };
  const ctx = { window, document, location: { pathname }, getComputedStyle: () => ({ position: 'static' }),
    sessionStorage: { getItem: k => stored[k] || null, setItem: (k, v) => { stored[k] = v; } },
    MutationObserver: class { observe() {} }, setTimeout: f => { f(); return 1; },
    fetch: async url => { fetched.push(url); const id = /(\d+)/.exec(url)[1];
      return { json: async () => url.includes('deckapp') ? { results: report[id] || {} }
                                                         : { [id]: { data: { platforms: { mac: !!platforms[id] } } } } }; },
    JSON, Promise, Math, Map };
  vm.runInNewContext(src.split('__NP_MAP__').join(JSON.stringify(map)), ctx);
  return { window, inserted, fetched, settle: () => new Promise(r => setImmediate(() => setImmediate(r))) };
}

(async () => {
  console.log('== an app page ==');
  {
    const p = page({ pathname: '/app/480/Thing/', map: { 480: ['good', 'This game has run on this Mac 4 times without crashing.'] } });
    ok(p.window.__notprotonStore === true, 'the script marks itself once it has run');
    ok(p.inserted.length === 1 && p.inserted[0].id === 'notproton-mac-compat', 'one block goes in above the Deck one');
    ok(/Mac Compatibility/.test(text(p.inserted[0])), 'headed Mac Compatibility');
    ok(/Verified/.test(text(p.inserted[0])) && /4 times/.test(text(p.inserted[0])), 'saying what this Mac has seen of the game');
    ok(p.fetched.length === 0, 'and a game the catalogue knows is not asked about');
  }
  {
    const p = page({ pathname: '/app/7/X/', mac: true, anticheat: { text: 'Uses Kernel Level Anti-Cheat Easy Anti-Cheat', name: 'Easy Anti-Cheat' },
                     map: { 7: ['good', 'ran fine'] } });
    ok(/Unsupported/.test(text(p.inserted[0])) && /Easy Anti-Cheat/.test(text(p.inserted[0])),
       'a kernel anti-cheat outranks a macOS build and a clean history');
  }
  {
    const p = page({ pathname: '/app/8/X/', mac: true });
    ok(/Verified/.test(text(p.inserted[0])) && /native macOS/.test(text(p.inserted[0])), 'a macOS build the page lists is good');
  }
  {
    const p = page({ pathname: '/app/9/X/', report: { 9: { resolved_category: 3, resolved_items: [] } } });
    ok(/Unknown/.test(text(p.inserted[0])), 'a game the page says nothing about is drawn unknown at once');
    await p.settle();
    ok(/Likely/.test(text(p.inserted[0])) && /Steam Deck/.test(text(p.inserted[0])), "and redrawn with what Valve's testing found");
    ok(p.fetched.some(u => u === '/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=9'), "asked of the store's own endpoint");
    ok(p.fetched.every(u => u.startsWith('/')), 'and of nowhere but the page it is on');
  }
  {
    const p = page({ pathname: '/app/10/X/', report: { 10: { resolved_category: 3,
                     steamos_resolved_items: [{ loc_token: '#SteamOS_TestResult_UnsupportedAntiCheat_Other' }] } } });
    await p.settle();
    ok(/Unsupported/.test(text(p.inserted[0])), 'an anti-cheat Valve failed blocks it, whatever its category');
  }
  ok(page({ pathname: '/', deck: false }).inserted.length === 0, 'a page with no Deck block gets none of ours');
  ok(page({ pathname: '/search/' }).inserted.length === 0, 'and neither does a page that is not a game');

  console.log('== the wishlist ==');
  {
    const row = id => { const r = node('div'); r.dataset.rfdDraggableId = `WishlistItem-${id}-0`;
                        const panel = node('div'); panel.className = 'Panel'; r.append(panel); return r; };
    const rows = [row(480), row(55), row(56)];
    const p = page({ pathname: '/wishlist/id/someone/', deck: false, rows,
                     map: { 480: ['blocked', 'no'] }, report: { 55: { resolved_category: 2 } }, platforms: { 56: true } });
    await p.settle(); await p.settle();
    const chips = rows.map(r => text(r.querySelector('.notproton-mac-chip')));
    ok(/Mac: Unsupported/.test(chips[0]), `a game the catalogue knows says so (${chips[0].trim()})`);
    ok(/Mac: Likely/.test(chips[1]), `one Valve calls playable is likely (${chips[1].trim()})`);
    ok(/Mac: Verified/.test(chips[2]), `one with a macOS build is verified (${chips[2].trim()})`);
    ok(rows.every(r => r.dataset.notprotonMac === '1'), 'each row is marked once it is done');
    ok(rows[0].querySelector('.Panel').style.position === 'relative', 'and holds its chip in place');
  }

  console.log('== one answer, said the same way everywhere ==');
  // Every sentence advice.c gives a game that is not installed has to be in the page
  // script word for word, or a game would say one thing in the library and another here.
  const body = advice.slice(advice.indexOf('np_badge_t np_advice_from_valve'), advice.indexOf('const char *np_badge_name'));
  const sentences = [...body.matchAll(/snprintf\(reason, size, ((?:\s*"(?:[^"\\]|\\.)*")+)/g)]
    .map(m => [...m[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map(x => x[1]).join(''));
  ok(sentences.length === 6, `advice.c has six such sentences (${sentences.length})`);
  for (const s of sentences) ok(src.includes(s), `the page says: ${s.slice(0, 58)}...`);

  console.log(failed ? `==> store-page: ${failed} failure(s)` : '==> store-page: the store says what the library says, where the Deck block is');
  process.exit(failed ? 1 : 0);
})();
