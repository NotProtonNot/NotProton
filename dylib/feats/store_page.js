// The Mac compatibility block on a store page, beside the Steam Deck one.
//
// This runs inside store.steampowered.com, which is Valve's page and not a file NotProton
// serves, so it is put there through Steam's CEF debugger (see agent.js) rather than by
// the dylib. It reads only what the page already shows: the appid in the address, whether
// the page lists a macOS build, and the anti-cheat notice. The agent fills in the map
// below with the badges this Mac has worked out for its installed games.
(() => {
  if (window.__notprotonStore) return;

  const MAP = __NP_MAP__;
  const APPLE = 'M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57-155.5-127C46.7 790.7 0 663 0 541.8c0-194.4 126.4-297.5 250.8-297.5 66.1 0 121.2 43.4 162.7 43.4 39.5 0 101.1-46 176.3-46 28.5 0 130.9 2.6 198.3 99.2zm-234-181.5c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.5 32.4-55.1 83.6-55.1 135.5 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 135.5-71.3z';
  // The same four as the library's badge and the game page's stat.
  const TIERS = {
    good:    { bg: '#59bf40', fg: '#ffffff', bd: 'none', label: 'Verified' },
    issues:  { bg: '#ffc82c', fg: '#1b2838', bd: 'none', label: 'Playable' },
    blocked: { bg: '#d94126', fg: '#ffffff', bd: 'none', label: 'Unsupported' },
    likely:  { bg: 'transparent', fg: '#59bf40', bd: '2px solid #59bf40', label: 'Likely' },
    unknown: { bg: 'transparent', fg: '#c6d4df', bd: '1.5px dashed #8b929a', label: 'Unknown' },
  };

  // What is known about this game, most serious first. What this Mac has actually seen
  // of an installed game outranks what the page merely suggests, except that nothing
  // outranks an anti-cheat that cannot run here.
  function verdict() {
    const m = /^\/app\/(\d+)/.exec(location.pathname);
    if (!m) return null;
    const notice = document.querySelector('.anticheat_section');
    const name = notice && notice.querySelector('.anticheat_name');
    const what = name ? name.firstChild.textContent.trim() : 'an anti-cheat';
    if (notice && /kernel/i.test(notice.textContent))
      return ['blocked', `Uses ${what}, a kernel-level anti-cheat, which does not run under CrossOver on macOS.`];
    if (MAP[m[1]]) return MAP[m[1]];
    if (document.querySelector('.platform_img.mac'))
      return ['good', 'This game has a native macOS version, which Steam runs without CrossOver.'];
    if (notice)
      return ['issues', `Uses ${what}, which may not work under CrossOver on macOS.`];
    return ['unknown', 'Nothing has run this game on this Mac yet. Windows games run through CrossOver.'];
  }

  // The same reading of Valve's own Proton testing that advice.c gives a game in the
  // library that is not installed, word for word, so a game says one thing everywhere.
  function fromValve(mac, deck, anticheat) {
    if (anticheat)
      return ['blocked', "Valve's testing found this game's anti-cheat does not support Proton, so it will not run under CrossOver either."];
    if (mac) return ['good', 'This game has a native macOS version, which Steam runs without CrossOver.'];
    if (deck === 3) return ['likely', 'Verified on Steam Deck through Proton, which is a good sign for CrossOver. It has not run on this Mac yet.'];
    if (deck === 2) return ['likely', 'Playable on Steam Deck through Proton, which is a good sign for CrossOver. It has not run on this Mac yet.'];
    if (deck === 1) return ['issues', 'Valve marks this game unsupported on Steam Deck, so it may not run under CrossOver. It has not run on this Mac yet.'];
    return ['unknown', 'This game has not run on this Mac yet, and Valve has not tested it.'];
  }

  // A game this Mac's catalogue has nothing on is asked about where the store itself
  // asks: the same two endpoints this page's own Deck block and platform icons are fed
  // from. One answer per game per session, two requests at a time, so a long wishlist
  // is a trickle and not a burst.
  const asked = new Map();
  let running = 0;
  const waiting = [];
  function pump() {
    while (running < 2 && waiting.length) {
      running++;
      const job = waiting.shift();
      job().finally(() => { running--; pump(); });
    }
  }
  function lookup(appid) {
    if (MAP[appid]) return Promise.resolve(MAP[appid]);
    if (asked.has(appid)) return asked.get(appid);
    const key = 'notproton-mac-' + appid;
    try {
      const kept = JSON.parse(sessionStorage.getItem(key));
      if (kept) { const p = Promise.resolve(kept); asked.set(appid, p); return p; }
    } catch (e) { /* nothing kept, or nowhere to keep it */ }
    const p = new Promise(resolve => {
      waiting.push(async () => {
        let mac = 0, deck = 0, anticheat = 0;
        try {
          const r = await (await fetch('/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=' + appid)).json();
          const res = (r && r.results) || {};
          deck = [1, 2, 3].includes(res.resolved_category) ? res.resolved_category : 0;
          anticheat = [...(res.resolved_items || []), ...(res.steamos_resolved_items || [])]
            .some(i => /UnsupportedAntiCheat/.test(i.loc_token || '')) ? 1 : 0;
        } catch (e) { /* no report is an untested game */ }
        try {
          const d = await (await fetch('/api/appdetails?appids=' + appid + '&filters=platforms')).json();
          mac = d && d[appid] && d[appid].data && d[appid].data.platforms && d[appid].data.platforms.mac ? 1 : 0;
        } catch (e) { /* no answer is no macOS build known */ }
        const v = fromValve(mac, deck, anticheat);
        try { sessionStorage.setItem(key, JSON.stringify(v)); } catch (e) { /* not kept */ }
        resolve(v);
      });
      pump();
    });
    asked.set(appid, p);
    return p;
  }

  function el(tag, style, text) {
    const n = document.createElement(tag);
    Object.assign(n.style, style);
    if (text != null) n.textContent = text;
    return n;
  }

  function disc(tier, px) {
    const t = TIERS[tier] || TIERS.unknown;
    const d = el('div', { width: px + 'px', height: px + 'px', flex: '0 0 auto', boxSizing: 'border-box',
      display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: '50%',
      background: t.bg, color: t.fg, border: t.bd });
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    const w = Math.round(px * 0.46);
    svg.setAttribute('viewBox', '0 0 814 1000');
    svg.setAttribute('width', w);
    svg.setAttribute('height', Math.round(w * 1000 / 814));
    svg.style.display = 'block';
    svg.style.marginTop = '-1px';
    const path = document.createElementNS(NS, 'path');
    path.setAttribute('d', APPLE);
    path.setAttribute('fill', 'currentColor');
    svg.append(path);
    d.append(svg);
    return d;
  }

  // Laid out to the measurements of the Deck block it sits above, so the two read as a
  // pair: the same heading, the same row, a disc where the Deck has its icon.
  function draw() {
    const deck = document.querySelector('[data-featuretarget="deck-verified-results"]');
    if (!deck || document.getElementById('notproton-mac-compat')) return !!deck;
    const v = verdict();
    if (!v) return true;
    const t = TIERS[v[0]] || TIERS.unknown;
    const box = el('div', { padding: '12px 0 4px' });
    box.id = 'notproton-mac-compat';
    box.append(el('div', { color: '#fff', fontSize: '14px', letterSpacing: '0.42px', textTransform: 'uppercase',
      fontFamily: '"Motiva Sans", Arial, Helvetica, sans-serif', paddingBottom: '5px' }, 'Mac Compatibility'));
    const row = el('div', { display: 'flex', alignItems: 'center', gap: '10px', padding: '14px 24px',
      background: 'rgba(0, 0, 0, 0.2)' });
    row.title = v[1];
    row.append(disc(v[0], 22), el('span', { fontSize: '14px', color: '#c6d4df' }, t.label));
    const why = el('div', { fontSize: '12px', lineHeight: '16px', color: '#8f98a0', padding: '8px 24px 0' }, v[1]);
    box.append(row, why);
    deck.parentNode.insertBefore(box, deck);
    // What the page itself shows is drawn at once. A game it says nothing about is then
    // asked after, and the row is redrawn with whatever Valve's testing found.
    if (v[0] === 'unknown') {
      const id = /^\/app\/(\d+)/.exec(location.pathname)[1];
      lookup(id).then(found => {
        if (found[0] === 'unknown') return;
        row.replaceChildren(disc(found[0], 22), el('span', { fontSize: '14px', color: '#c6d4df' }, (TIERS[found[0]] || TIERS.unknown).label));
        row.title = found[1];
        why.textContent = found[1];
      });
    }
    return true;
  }

  // The wishlist: one small chip per row, on the right between the date and the price.
  // Rows come and go as the list scrolls, so each is marked when it has been done and
  // the list is watched for new ones.
  function chip(v) {
    const t = TIERS[v[0]] || TIERS.unknown;
    const c = el('div', { position: 'absolute', right: '20px', top: '50px', display: 'flex', alignItems: 'center',
      gap: '7px', padding: '4px 10px 4px 5px', borderRadius: '13px', background: 'rgba(0, 0, 0, 0.28)',
      fontSize: '12px', color: '#c6d4df', pointerEvents: 'auto' });
    c.className = 'notproton-mac-chip';
    c.title = v[1];
    c.append(disc(v[0], 18), el('span', {}, 'Mac: ' + t.label));
    return c;
  }
  function wishlist() {
    for (const item of document.querySelectorAll('[data-rfd-draggable-id^="WishlistItem-"]')) {
      if (item.dataset.notprotonMac) continue;
      const m = /^WishlistItem-(\d+)/.exec(item.dataset.rfdDraggableId);
      const panel = item.querySelector('.Panel') || item;
      if (!m) continue;
      item.dataset.notprotonMac = '1';
      if (getComputedStyle(panel).position === 'static') panel.style.position = 'relative';
      lookup(m[1]).then(v => { if (panel.isConnected && !panel.querySelector('.notproton-mac-chip')) panel.append(chip(v)); });
    }
  }
  function watchWishlist() {
    if (!/^\/wishlist\//.test(location.pathname)) return;
    let due = 0;
    const soon = () => { if (!due) due = setTimeout(() => { due = 0; wishlist(); }, 150); };
    new MutationObserver(soon).observe(document.documentElement, { childList: true, subtree: true });
    soon();
  }

  // Marked only once everything above has run, so a script that failed part-way is one
  // that can be put in again rather than one that claims to be there.
  window.__notprotonStore = true;
  if (document.documentElement) watchWishlist();
  else document.addEventListener('DOMContentLoaded', watchWishlist);
  if (!draw()) {
    const again = () => draw();
    document.addEventListener('DOMContentLoaded', again);
    window.addEventListener('load', again);
  }
})();
