#!/usr/bin/env node
// Puts dylib/feats/store_page.js into Steam's store pages through the CEF debugger, for
// as long as this runs. NotProton's dylib does this itself (dylib/feats/store.c); this is
// the same thing as a script, for working on the page script without building the dylib:
// edit store_page.js, restart this, reload the store page.
//
//   NP_CEF_PORT=27101 node tools/store-badge/agent.js      (Steam running under NotProton)
//   open -a Steam --args -cef-enable-debugging && node tools/store-badge/agent.js   (stock, port 8080)
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORT = process.env.NP_CEF_PORT || 8080;
const BADGES = path.join(os.homedir(), 'Library/Application Support/notproton/badges');

// "appid tier reason" per line, as the catalogue writes it.
function readMap() {
  const map = {};
  let text = '';
  try { text = fs.readFileSync(BADGES, 'utf8'); } catch { return map; }
  for (const line of text.split('\n')) {
    const m = /^(\d+) (good|likely|issues|blocked|unknown) (.+)$/.exec(line);
    if (m) map[m[1]] = [m[2], m[3]];
  }
  return map;
}

const page = fs.readFileSync(path.join(__dirname, '../../dylib/feats/store_page.js'), 'utf8');
// Exactly one place takes the map. More than one, or none, is a page.js this was not
// written for, and injecting it would only throw inside Valve's page.
if (page.split('__NP_MAP__').length !== 2) {
  console.error('page.js must name __NP_MAP__ exactly once');
  process.exit(1);
}
// The switch in Steam's Settings is a file, and it turns this off with the rest.
const OFF = path.join(os.homedir(), 'Library/Application Support/notproton/no-mac-badges');
const source = () => fs.existsSync(OFF) ? '/* Mac badges are turned off */'
                                        : page.split('__NP_MAP__').join(JSON.stringify(readMap()));
const attached = new Set();

function attach(target) {
  attached.add(target.id);
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0;
  const send = (method, params) => ws.send(JSON.stringify({ id: ++id, method, params }));
  ws.onopen = () => {
    const js = source();
    send('Page.enable');
    // Once for every page this view goes on to load, and once for the one it is on.
    send('Page.addScriptToEvaluateOnNewDocument', { source: js });
    send('Runtime.evaluate', { expression: js });
    console.log(`store view ${target.id.slice(0, 8)}: attached`);
  };
  ws.onclose = () => attached.delete(target.id);
  ws.onerror = () => attached.delete(target.id);
}

async function tick() {
  let targets;
  try {
    targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
  } catch {
    console.log('Steam\'s debugger is gone, stopping.');
    process.exit(0);
  }
  for (const t of targets)
    if (t.type === 'page' && /^https:\/\/store\.steampowered\.com\//.test(t.url) && !attached.has(t.id))
      attach(t);
}

tick();
setInterval(tick, 3000);
