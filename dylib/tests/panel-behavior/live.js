'use strict';
const assert = require('node:assert/strict');
const { panel, walk, details, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) throw new Error('usage: live.js <emit>');

const row = (k, l) => ({ k, l, on: '1', off: '', dep: '', d: '' });
const BAKED = JSON.stringify([row('NOTPROTON_OLD', 'Old plugin')]).replace(/"(\w+)":/g, '$1:');
const NEW = { s: 0, r: { NOTPROTON_NEW: 1 }, f: [row('NOTPROTON_NEW', 'New plugin')], v: [] };
const labels = ns => ns.filter(x => x.props && x.props.label).map(x => x.props.label);
const settle = () => new Promise(r => setImmediate(r));

function hooks() {
  const state = [];
  let at = 0;
  return {
    use: init => {
      const i = at++;
      if (!(i in state)) state[i] = init;
      return [state[i], v => { state[i] = typeof v === 'function' ? v(state[i]) : v; }];
    },
    effect: fn => {
      const i = at++;
      if (!(i in state)) { state[i] = true; fn(); }
    },
    render: fn => { at = 0; return walk(fn()); },
  };
}

function page(form, reply) {
  const h = hooks(), events = new EventTarget(), calls = [], errors = [];
  const g = {
    document: { documentElement: { lang: 'en' } },
    MSCXUseState: h.use, MSCXUseEffect: h.effect,
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    dispatchEvent: events.dispatchEvent.bind(events),
    MSCXRoute: (route, id) => { calls.push([route, id]); return reply(); },
  };
  const { render } = panel(emit, form, g, { feats: BAKED });
  const show = () => labels(h.render(() => render({ details: details('') })));
  return { g, calls, errors, show };
}

(async () => {
  const error = console.error;
  for (const form of Object.keys(FORMS)) {
    {
      const g = { document: { documentElement: { lang: 'en' } } };
      const { render } = panel(emit, form, g, { feats: BAKED });
      const show = () => labels(walk(render({ details: details('') })));
      assert(show().includes('Old plugin'), `${form}: without hooks the list Steam started with renders`);
      g.MSCXLive = NEW;
      assert(show().includes('New plugin') && !show().includes('Old plugin'),
             `${form}: a refetched list replaces it`);
    }
    {
      const p = page(form, () => Promise.resolve(JSON.stringify(NEW)));
      assert(p.show().includes('Old plugin'), `${form}: the first render shows the list Steam started with`);
      assert.deepEqual(p.calls, [['NotProton.GetPlugins#1', 0]], `${form}: opening asks for the list once`);
      await settle();
      const now = p.show();
      assert(now.includes('New plugin') && !now.includes('Old plugin'), `${form}: the answer re-renders the panel`);
      assert.equal(p.calls.length, 1, `${form}: a re-render does not ask again`);
    }
    {
      const p = page(form, () => Promise.reject('result 2'));
      const logged = [];
      console.error = (...a) => logged.push(a.join(' '));
      p.show();
      await settle();
      console.error = error;
      assert(p.show().includes('Old plugin'), `${form}: a failed refetch keeps the list it had`);
      assert(logged.some(l => l.includes('the plugin list was not refreshed')), `${form}: and says so`);
      assert(!p.g.MSCXLiveBusy, `${form}: and can ask again`);
    }
  }
  console.log('PASS: the panel refetches plugins when it opens and re-renders with the answer');
})().catch(e => { console.error(e); process.exit(1); });
