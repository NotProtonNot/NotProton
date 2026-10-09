'use strict';
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { panel, walk, details, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) throw new Error('usage: localization.js <emit>');
const doc = lang => ({ document: { documentElement: { lang } } });
const zhCases = [doc('zh-CN'), doc('zh-Hans'), doc('zh_Hans_CN'), doc('zh-SG'), doc('schinese'),
  { navigator: { language: 'zh-CN' } }, { ...doc(''), navigator: { language: 'zh-CN' } }];
const enCases = [doc('en'), doc('fr'), doc('zh-Hant'), doc('zh-TW'), doc('tchinese'), {},
  { ...doc('en'), navigator: { language: 'zh-CN' } }];

for (const form of Object.keys(FORMS)) {
  for (const [chinese, cases] of [[true, zhCases], [false, enCases]]) {
    for (const globals of cases) {
      const { render, written } = panel(emit, form, globals);
      const nodes = walk(render({ details: details('CX_GRAPHICS_BACKEND=dxmt %command%') }));
      const dropdowns = nodes.filter(n => n.type === 'Dropdown');
      assert.equal(dropdowns[0].props.rgOptions[0].label, chinese ? '自动' : 'Automatic');
      assert.equal(dropdowns[1].props.rgOptions[0].label, chinese ? '关闭' : 'Off');
      assert.deepEqual(dropdowns[0].props.rgOptions.map(o => o.data),
        ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']);
      assert(nodes.some(n => n.props.label === (chinese ? '图形' : 'Graphics')));
      assert(nodes.some(n => n.props.label === (chinese
        ? '控制器（可能导致 Steam Input 失效，不推荐）'
        : 'Controllers (May break Steam Input. Not recommended)')));
      const raw = nodes.find(n => n.props.label === (chinese
        ? '允许游戏直接读取控制器' : 'Let games read controllers directly'));
      raw.props.onChange(true);
      assert.equal(written.at(-1).opts, 'NOTPROTON_RAW_CONTROLLERS=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      const hud = nodes.find(n => n.props.label === (chinese ? 'Metal 性能监视器' : 'Metal HUD'));
      hud.props.onChange(true);
      assert.equal(written.at(-1).opts, 'MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      for (const [mode, en, zh] of [
        ['compat-hint', 'Enable CrossOver under Properties > Compatibility to install and run the Windows version.',
          '请在“属性 > 兼容性”中启用 CrossOver，以安装并运行 Windows 版本。'],
        ['image-files-label', 'Image Files (*.tga,*.png,*.exe)', '图像文件 (*.tga,*.png,*.exe)'],
      ]) {
        const src = execFileSync(emit, [mode], { encoding: 'utf8' });
        assert.equal(new Function('globalThis', `return ${src}`)(globals), chinese ? zh : en);
      }
    }
  }
}
console.log('PASS: both panel shapes, Chinese/English locales, fallback, labels and unchanged option values');
