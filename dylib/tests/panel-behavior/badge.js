// The Apple badge the library tiles get: that it only appears for a game the catalogue
// knows, that it carries the tier and the reason, and that it never throws into a render.
'use strict';
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

const emit = process.argv[2];
if (!emit) throw new Error('usage: badge.js <emit>');
const src = execFileSync(emit, ['badge-js'], { encoding: 'utf8' })
          + execFileSync(emit, ['stat-js'], { encoding: 'utf8' });

const mk = (type, props) => ({ type, props });
const React = { jsx: mk, jsxs: mk };

function world(compat) {
  const head = { children: [] };
  const byId = {};
  const doc = {
    getElementById: id => byId[id] || null,
    createElement: () => ({ set id(v) { byId[v] = this; }, get id() { return this._id; }, textContent: '' }),
    head: { appendChild: n => head.children.push(n) },
  };
  // The element records its own id the way the document would.
  doc.createElement = () => {
    const n = { textContent: '' };
    Object.defineProperty(n, 'id', { set(v) { n._id = v; byId[v] = n; }, get() { return n._id; } });
    return n;
  };
  const g = { document: doc, __NOTPROTON_COMPAT__: compat };
  g.window = g;   // the page's window is the global, as it is in Steam
  new Function('globalThis', 'window', 'document', src)(g, g, doc);
  return { g, head, styles: () => ({ SteamDeckCompatIcon: 'DeckIcon' }) };
}

const MAP = {
  480: ['good', 'This game has run on this Mac 4 times without crashing.'],
  620: ['blocked', 'This game uses Easy Anti-Cheat, which does not run under CrossOver on macOS.'],
  730: ['issues', 'This game starts through Ubisoft Connect.'],
  440: ['unknown', 'This game has not run on this Mac yet.'],
  550: ['likely', 'Verified on Steam Deck through Proton.'],
};

let failed = 0;
const ok = (cond, what) => { if (!cond) failed++; console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${what}`); };

{
  const w = world(MAP);
  const badge = w.g.window.__NOTPROTON_BADGE__({ appid: 480 }, React, w.styles);
  ok(!!badge, 'a game in the catalogue gets a badge');
  ok(/\bNPBadge-good\b/.test(badge.props.className), `the tier is on the class (${badge.props.className})`);
  ok(badge.props.title === MAP[480][1], 'the reason is the tooltip');

  // Everything the badge needs is on the elements. A stylesheet added to this page is
  // dropped without a word, and it would take the badge's place, size and colour with it.
  const st = badge.props.style;
  ok(st.position === 'absolute', 'the badge places itself');
  ok(st.left && st.bottom, 'in the corner the Deck badge uses');
  ok(Number(st.zIndex) > 0, 'above the art');
  ok(st.pointerEvents === 'none', 'and out of the way of clicks');

  // A filled disc in the tier's colour, the way the Deck's badges are drawn.
  const disc = badge.props.children;
  ok(disc.props.style.borderRadius === '50%', 'the badge is a disc');
  ok(disc.props.style.width === '26px' && disc.props.style.height === '26px', 'at a size of its own');
  ok(disc.props.style.background === '#59bf40', `filled with the tier's colour (${disc.props.style.background})`);
  const svg = disc.props.children;
  ok(svg.type === 'svg' && svg.props.viewBox === '0 0 814 1000', 'with the Apple mark inside');
  ok(svg.props.width > 0 && svg.props.height > 0, 'which carries its own size');
  ok(svg.props.children.props.fill === 'currentColor', 'and takes its colour from the disc');

  const FILL = { good: '#59bf40', issues: '#ffc82c', blocked: '#d94126' };
  for (const [id, [tier]] of Object.entries(MAP)) {
    const b = w.g.window.__NOTPROTON_BADGE__({ appid: +id }, React, w.styles);
    ok(b.props.className.includes('NPBadge-' + tier), `${tier} reads as ${tier}`);
    const d = b.props.children.props.style;
    if (FILL[tier]) ok(d.background === FILL[tier], `and ${tier} is filled ${FILL[tier]}`);
    // Unknown is the one that is not filled, the way the Deck's dashed circle is not.
    else if (tier === 'unknown') ok(/dashed/.test(d.border), 'and unknown is a dashed ring rather than a fill');
  }
}
{
  const w = world(MAP);
  ok(w.g.window.__NOTPROTON_BADGE__({ appid: 1 }, React, w.styles) === null,
     'a game the catalogue says nothing about gets no badge');
  ok(w.g.window.__NOTPROTON_BADGE__(null, React, w.styles) === null, 'and neither does no game');
}
{
  // Nothing here may throw: it runs inside Steam's own render.
  const w = world(undefined);
  ok(w.g.window.__NOTPROTON_BADGE__({ appid: 480 }, React, w.styles) === null,
     'no catalogue at all is no badge, not a crash');
  const w2 = world(MAP);
  const thrower = () => { throw new Error('no styles here'); };
  const b = w2.g.window.__NOTPROTON_BADGE__({ appid: 480 }, React, thrower);
  ok(b && !b.props.className.includes('undefined'),
     'a style module that throws still leaves a badge');
  ok(w2.g.window.__NOTPROTON_BADGE__({ appid: 480 }, null, w2.styles) === null,
     'and no React is no badge, not a crash');
}

// Passed Valve's Proton testing but not run here: a green ring, since the fill is kept
// for what this Mac has actually seen.
{
  const w = world(MAP);
  const d = w.g.window.__NOTPROTON_BADGE__({ appid: 550 }, React, w.styles).props.children.props.style;
  ok(/solid #59bf40/.test(d.border) && d.color === '#59bf40', 'likely is a green ring');
  ok(d.background !== '#59bf40', 'and not the fill a game that ran here gets');
  const stat = w.g.window.__NOTPROTON_STAT__({ details: { unAppID: 550 } }, React,
    () => ({ GameStat: 'GS', GameStatIcon: 'GSI', GameStatRight: 'GSR', PlayBarLabel: 'PBL', PlayBarDetailLabel: 'PBD' }));
  ok(stat.props.children[1].props.children[1].props.children === 'Likely', 'which the game page calls Likely');
}

// The switch in Settings: off is no badge and no stat, and on again brings both back
// without anything being loaded again.
{
  const w = world(MAP);
  w.g.window.__NOTPROTON_BADGES_OFF__ = true;
  ok(w.g.window.__NOTPROTON_BADGE__({ appid: 480 }, React, w.styles) === null, 'turned off, a tile gets no badge');
  ok(w.g.window.__NOTPROTON_STAT__({ details: { unAppID: 480 } }, React, w.styles) === null, 'and a game page no stat');
  w.g.window.__NOTPROTON_BADGES_OFF__ = false;
  ok(!!w.g.window.__NOTPROTON_BADGE__({ appid: 480 }, React, w.styles), 'turned on again, the badge is back');
}

// The wide featured tile keeps its Play button in the bottom corner, so the badge moves up.
{
  const w = world(MAP);
  const b = w.g.window.__NOTPROTON_BADGE__({ appid: 480 }, React, w.styles);
  const top = w.g.window.__NOTPROTON_PLACE__(b, true);
  ok(top.props.style.top === '8px' && top.props.style.bottom === 'auto', 'a featured tile gets the badge at the top');
  ok(top.props.style.left === b.props.style.left && top.props.children === b.props.children,
     'and nothing else about it changes');
  ok(b.props.style.bottom === '8px' && b.props.style.top === undefined, 'the element handed in is left as it was');
  ok(w.g.window.__NOTPROTON_PLACE__(b, false) === b, 'any other tile keeps it in the bottom corner');
  ok(w.g.window.__NOTPROTON_PLACE__(null, true) === null, 'and no badge is still no badge');
}

// The same verdict as a stat on the game's own page, built like the ones beside it.
{
  const w = world(MAP);
  const styles = () => ({ GameStat: 'GS', GameStatIcon: 'GSI', GameStatRight: 'GSR',
                          PlayBarLabel: 'PBL', PlayBarDetailLabel: 'PBD' });
  const stat = w.g.window.__NOTPROTON_STAT__({ details: { unAppID: 480 } }, React, styles);
  ok(!!stat, 'a game in the catalogue gets a stat on its page');
  ok(stat.props.className.includes('GS'), "it uses Steam's own stat class");
  ok(stat.props.className.includes('NPBadge-good'), 'and carries the tier');
  ok(stat.props.title === MAP[480][1], 'the reason is the tooltip');
  const [icon, right] = stat.props.children;
  const statDisc = icon.props.children;
  ok(statDisc.props.children.props.viewBox === '0 0 814 1000', 'the icon is the Apple mark');
  ok(statDisc.props.style.background === '#59bf40', 'on a disc filled with the tier colour');
  ok(right.props.children[0].props.children === 'MAC', 'the label reads MAC');
  ok(!right.props.style, "and leaves the label and value in Steam's own colours");
  ok(right.props.children[1].props.children === 'Verified', 'and the detail reads Verified');

  // The page knows the app by either name Steam gives it.
  const byOverview = w.g.window.__NOTPROTON_STAT__({ overview: { appid: 620 } }, React, styles);
  ok(byOverview.props.className.includes('NPBadge-blocked'), 'an overview names the app too');
  ok(byOverview.props.children[1].props.children[1].props.children === 'Unsupported',
     'and a blocked game reads Unsupported');

  ok(w.g.window.__NOTPROTON_STAT__({ details: { unAppID: 1 } }, React, styles) === null,
     'a game the catalogue says nothing about gets no stat');
  ok(w.g.window.__NOTPROTON_STAT__({}, React, styles) === null, 'and neither does no app');
  const thrower = () => { throw new Error('no styles'); };
  const safe = w.g.window.__NOTPROTON_STAT__({ details: { unAppID: 480 } }, React, thrower);
  ok(safe && !safe.props.className.includes('undefined'),
     'a style module that throws still leaves a stat');
}

console.log(failed ? `\nbadge: ${failed} failure(s)` : '\nPASS: the tile badge and the game page stat show the tier, the reason and nothing it should not');
process.exit(failed ? 1 : 0);
