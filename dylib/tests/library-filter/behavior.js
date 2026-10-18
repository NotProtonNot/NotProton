// Runs the patched library filter and Windows button from gatecheck's output.
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

function grab(src, re, what) {
  const m = re.exec(src);
  if (!m) throw new Error(`no ${what}`);
  return m;
}

const english = () => { globalThis.document = { documentElement: { lang: 'en' } }; };

function filter(src) {
  const head = grab(src, /case"notprotonWindows":return\(0,([\w$]+)\.Pr\)\(\)&&window\.__NOTPROTON_NATIVE_PLATFORM__\.windows\.has\(([\w$]+)\.appid\)/,
                    'filter fix');
  const apple = grab(src.slice(head.index), /;case ([\w$]+)\.([\w$]+):return /, 'Apple case');
  const end = src.indexOf('.is_invalid_os_type;', head.index + apple.index + apple[0].length);
  const stmt = src.slice(head.index, end + '.is_invalid_os_type;'.length);
  const [, platform, app] = head;
  const [, group, option] = apple;
  const device = /\.mP\)\(\)\?([\w$]+)\(/.exec(stmt);
  const run = new Function('window', group, platform, app, device ? device[1] : '__device', '__k',
                           `switch(__k){${stmt}}`);
  return (key, win, os, a) => run(win, { [option]: 'Apple' }, os, a, () => 'device', key);
}

function lists(src) {
  const win = {};
  new Function('window', src.slice(0, src.indexOf('\n') + 1))(win);
  return win;
}

function check(file, name, t) {
  const src = fs.readFileSync(file, 'latin1');
  const win = lists(src);
  const run = filter(src);
  const mac = { Pr: () => true, td: () => false, CI: () => false, mP: () => false };
  const windows = { Pr: () => false, td: () => true, CI: () => false, mP: () => false };
  const app = (appid, { old = false, available = true } = {}) =>
    ({ appid, is_available_on_current_platform: available, is_invalid_os_type: false,
       most_available_per_client_data: { is_invalid_os_type: old } });
  const apple = (a, os = mac) => run('Apple', win, os, a);
  const wonly = (a, os = mac) => run('notprotonWindows', win, os, a);

  t(apple(app(1)) && !wonly(app(1)), 'a Mac game is under Apple only');
  t(!apple(app(2)) && wonly(app(2)), 'a Windows game is under Windows only');
  t(apple(app(4)) && !wonly(app(4)), 'a game with both builds is under Apple only');
  t(!apple(app(4, { old: true })) && wonly(app(4, { old: true })),
    'a game whose Mac build is 32-bit is under Windows only');
  t(!apple(app(1, { old: true })) && !wonly(app(1, { old: true })),
    'a 32-bit Mac game with no Windows build is under neither');
  t(apple(app(3)) && !apple(app(3, { available: false })) && !wonly(app(3)),
    "a game missing from appinfo.vdf gets Steam's answer under Apple and is not under Windows");
  t(!apple(app(3, { old: true })) && !wonly(app(3, { old: true })),
    'a missing 32-bit Mac game stays excluded even though the top-level invalid flag is false');
  const otherPlatform = { ...mac, Pr: () => false };
  t(!apple({ ...app(3), is_invalid_os_type: true }, otherPlatform) && apple(app(3), otherPlatform),
    'the fallback on other platforms still uses the original invalid flag');
  t(apple(app(2), windows) && !wonly(app(2), windows), "on Windows the filter is Steam's");

  if (!src.includes('SelectCollectionsAppFilterOption("notprotonWindows"')) return;

  grab(src, /filterGroups:\[([\w$]+)\(!0,([\w$]+)&&\2\.filterGroups\[0\]\),\1\(!1,\2&&\2\.filterGroups\[1\]\)/,
       "Steam's default intersection for the state group");
  const checks = [...src.matchAll(/if\(!(.+?)\|\|!([\w$]+)\(([\w$]+)\[([\w$]+)\.sc\],/g)];
  t(checks.length === 2, 'both matching paths include the platform check');
  for (const [, expr, match, groups, enums] of checks) {
    const [, predicate, argument] = grab(expr, /,([\w$]+)\(([\w$]+)\)\)\)*$/, 'platform predicate');
    const evaluate = new Function(match, groups, enums, predicate, argument, `return ${expr}`);
    const matches = (g, p) => !g.rgOptions.length || (g.bAcceptUnion ? g.rgOptions.some(p) : g.rgOptions.every(p));
    const test = (options, windowsOn, a, union = false) => {
      const state = [{ rgOptions: [], bAcceptUnion: true }, { rgOptions: options, bAcceptUnion: union }];
      const before = JSON.stringify(state);
      const result = evaluate.call({ m_filterSpec: { notprotonWindows: windowsOn } }, matches, state,
        { W6: 1, Pu: 'Apple' }, a => key => key === 'installed' ? !!a.installed : run(key, win, mac, a), a);
      t(JSON.stringify(state) === before, 'matching leaves the saved filter unchanged');
      return result;
    };
    for (const id of [1, 2, 4]) {
      t(test([], false, app(id)), 'neither platform button filters games');
      t(test(['Apple'], false, app(id)) === (id !== 2), 'Apple alone keeps its platform check');
      t(test([], true, app(id)) === (id === 2), 'Windows alone keeps its platform check');
      t(test(['Apple'], true, app(id)), 'both buttons show both platforms with the default intersection');
      t(test(['Apple'], true, app(id), true), 'both buttons show both platforms with a union');
      t(!test(['Apple', 'installed'], true, app(id)) &&
        test(['Apple', 'installed'], true, { ...app(id), installed: true }),
        'installed stays an intersection with the combined platforms');
    }
    t(!test(['Apple'], true, app(3, { available: false })), 'neither platform admits an unavailable unknown game');
    t(test(['installed'], true, { ...app(1), installed: true }, true), 'other union options still admit games');
  }

  const saved = grab(src, /notprotonWindows:(!!([\w$]+)\?\.notprotonWindows),/, 'saved flag');
  const restore = new Function(saved[2], `return ${saved[1]}`);
  t(restore(undefined) === false && restore({}) === false && restore({ notprotonWindows: true }) === true,
    'a saved filter brings the Windows button back');

  const select = grab(src, /SelectOption\(([\w$]+),([\w$]+),([\w$]+)\)\{(if\(\1==="notprotonWindows"\)\{this\.m_filterSpec\.notprotonWindows=!!\3;return\})/,
                      'option setter');
  const set = new Function(select[1], select[2], select[3], `${select[4]}return"steam"`);
  const self = { m_filterSpec: { notprotonWindows: false } };
  const r1 = set.call(self, 'notprotonWindows', null, true);
  const was = self.m_filterSpec.notprotonWindows;
  set.call(self, 'notprotonWindows', null, false);
  t(r1 === undefined && was === true && self.m_filterSpec.notprotonWindows === false &&
    set.call(self, 0, 'Apple', true) === 'steam', 'the Windows option toggles the flag and nothing else');

  t(/Reset\(\)\{this\.m_filterSpec\.notprotonWindows=!1,/.test(src), 'Reset turns the Windows button off');
  t(/get bIsEmpty\(\)\{return!this\.m_filterSpec\.notprotonWindows&&/.test(src),
    'a filter with only Windows on does not count as empty');

  english();
  const summary = grab(src, /if\(([\w$]+)==="notprotonWindows"\)return (.*?);if\(\1==/, 'summary');
  t(new Function(`return ${summary[2]}`)() === 'Runs on Windows, no Mac OS version',
    'the filter summary names the Windows filter');

  const button = grab(src, /children:\[(([\w$]+)&&!([\w$]+)&&([\w$]+)\.Xz0&&\(0,([\w$]+)\.jsxs\)\(([\w$]+)\.he,\{.*?\(0,\5\.jsx\)\(\4\.Xz0,\{\}\)\]\}\)),\2&&\(0,\5\.jsxs\)\(\6\.he,\{direction:"top",nDelayShowMS:240,toolTipContent:\3\?(?:\(0,[\w$]+\.we\)\()?"#GameList_View_Platform_Linux"/,
                      'Windows button before Apple');
  const [, expr, shown, linux, icons, rt, tip] = button;
  const cls = /className:\(0,([\w$]+)\.A\)\(([\w$]+)\(\)\.CheckboxWithImage,([\w$]+)&&/.exec(expr);
  const draw = new Function(shown, linux, icons, rt, tip, cls[1], cls[2], cls[3], 'npWindows', 'npStore',
                            `return ${expr}`);
  const press = ({ visible = true, onLinux = false, icon = true, disabled = false, active = false } = {}) => {
    const calls = [];
    const node = draw(visible, onLinux, icon ? { Xz0: 'Windows' } : {}, { jsx: (type, p) => ({ type, p }), jsxs: (type, p) => ({ type, p }) },
                      { he: 'Tooltip' }, { A: (...c) => c.filter(Boolean).join(' ') },
                      () => ({ CheckboxWithImage: 'box', Disabled: 'off', Active: 'on' }), disabled, active,
                      { SelectCollectionsAppFilterOption: (...a) => calls.push(a) });
    if (node) node.p.onClick();
    return { node, calls };
  };
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const lit = press({ active: true });
  t(same(press().calls, [['notprotonWindows', null, true]]) && same(lit.calls, [['notprotonWindows', null, false]]),
    'a click toggles the Windows button');
  t(lit.node.p.className === 'box on' && press().node.p.className === 'box' &&
    lit.node.p.children[1].type === 'Windows' && lit.node.p.nDelayShowMS === 240 &&
    lit.node.p.children[0].type === 'style' &&
    lit.node.p.children[0].p.children === '.box .SVGIcon_WindowsLogo{width:13px;height:13px}.box .SVGIcon_WindowsLogo rect{fill:inherit}' &&
    lit.node.p.toolTipContent === 'Show only games that run on Windows and do not have a macOS version',
    "the Windows button looks and times like Steam's Apple button");
  t(press({ disabled: true }).calls.length === 0, 'a disabled Windows button does nothing');
  t(!press({ onLinux: true }).node && !press({ icon: false }).node && !press({ visible: false }).node,
    'no Windows button on Linux, without the icon, or when Steam hides the Apple one');
}

for (const file of files) {
  const name = path.basename(file, '.out.js');
  const t = (cond, what) => ok(name, cond, what);
  try { check(file, name, t); } catch (e) { t(false, e.message); }
}
console.log(failed ? `\n${failed} failure(s)` : `==> library filter: ${files.length} patched files behave`);
process.exit(failed ? 1 : 0);
