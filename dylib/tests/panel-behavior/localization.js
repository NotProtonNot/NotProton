'use strict';
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { panel, walk, details, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) throw new Error('usage: localization.js <emit>');
const doc = lang => ({ document: { documentElement: { lang } } });
const zhCases = [doc('zh-CN'), doc('zh-Hans'), doc('zh_Hans_CN'), doc('zh-SG'), doc('schinese'),
  { navigator: { language: 'zh-CN' } }, { ...doc(''), navigator: { language: 'zh-CN' } }];
const itCases = [doc('it'), doc('it-IT'), doc('it_CH'), doc('italian'),
  { navigator: { language: 'it-IT' } }, { ...doc(''), navigator: { language: 'it' } }];
const enCases = [doc('en'), doc('fr'), doc('zh-Hant'), doc('zh-TW'), doc('tchinese'), doc('ita'), doc('iw'), {},
  { ...doc('en'), navigator: { language: 'zh-CN' } }, { ...doc('en'), navigator: { language: 'it-IT' } }];
// The same label in English, Chinese and Italian; t() picks the one for the locale under test.
const lang = { en: 0, zh: 1, it: 2 };

for (const form of Object.keys(FORMS)) {
  for (const [language, cases] of [['zh', zhCases], ['it', itCases], ['en', enCases]]) {
    const t = (...labels) => labels[lang[language]];
    for (const globals of cases) {
      const { render, files, dialogs, written } = panel(emit, form, globals);
      const nodes = walk(render({ details: details('CX_GRAPHICS_BACKEND=dxmt %command%') }));
      const dropdowns = nodes.filter(n => n.type === 'Dropdown');
      assert.equal(dropdowns[0].props.rgOptions[0].label, t('Automatic', '自动', 'Automatico'));
      assert.equal(dropdowns[1].props.rgOptions[0].label, t('Off', '关闭', 'Disattivato'));
      assert.deepEqual(dropdowns[0].props.rgOptions.map(o => o.data),
        ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']);
      assert(nodes.some(n => n.props.label === t('Graphics', '图形', 'Grafica')));
      assert(nodes.some(n => n.props.label === t('Controllers', '控制器', 'Controller')));
      const raw = nodes.find(n => n.props.label === t(
        'Let Games Read Controllers Directly (May break Steam Input. Not recommended)',
        '允许游戏直接读取控制器（可能导致 Steam Input 失效，不推荐）',
        'Lascia che i giochi leggano direttamente i controller (può interferire con Steam Input, sconsigliato)'));
      assert(nodes.some(n => n.props.label === t('Disable hidraw', '停用 hidraw', 'Disattiva hidraw')));
      assert(nodes.some(n => n.props.label === 'Launch Executable'));
      const browse = nodes.find(n => n.type === 'Button');
      assert.equal(browse.props.children, 'Browse...');
      files.push('/g/a.exe');
      browse.props.onClick();
      assert.equal(dialogs.at(-1).strTitle, t('Choose a Program to Launch', '选择要启动的程序', 'Scegli il programma da avviare'));
      const target = walk(render({ details: details(written.at(-1).opts) }));
      assert.deepEqual(target.filter(n => n.type === 'Button').map(n => n.props.children), ['Remove', 'Browse...', 'Browse...']);
      assert.deepEqual(target.filter(n => n.type === 'Field').map(n => n.props.label), ['Executable', 'Start Executable From']);
      target.filter(n => n.type === 'Button')[2].props.onClick();
      assert.equal(dialogs.at(-1).bChooseDirectory, true);
      assert.equal(dialogs.at(-1).strTitle, 'Choose Start Directory');
      // Steam's own strings, when its localizer is there.
      const steam = { ...globals, LocalizationManager: { LocalizeString: k => ({
        '#AppProperties_Shortcut_BrowseFiles': 'B', '#Button_Remove': 'R',
        '#AppProperties_Shortcut_ChooseStartDirectoryDialogTitle': 'C' })[k] } };
      const S = panel(emit, form, steam);
      const sn = walk(S.render({ details: details(written.at(-1).opts) }));
      assert.deepEqual(sn.filter(n => n.type === 'Button').map(n => n.props.children), ['R', 'B', 'B']);
      assert.deepEqual(sn.filter(n => n.type === 'Field').map(n => n.props.label), ['Executable', 'Start Executable From']);
      sn.filter(n => n.type === 'Button')[2].props.onClick();
      assert.equal(S.dialogs.at(-1).strTitle, 'C');
      const feats = panel(emit, form, globals, {
        ready: '{"NOTPROTON_X":0}', feats: '[{k:"NOTPROTON_X",l:"X",on:"1",off:"",dep:"",d:""}]' });
      const fnodes = walk(feats.render({ details: details('') }));
      assert(fnodes.some(n => n.props.label === t('Developer', '开发者', 'Developer')));
      assert(fnodes.some(n => n.props.label === 'X' + t(' (Not Installed)', ' (未安装)', ' (Not Installed)')));
      raw.props.onChange(true);
      assert.equal(written.at(-1).opts, 'NOTPROTON_RAW_CONTROLLERS=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      const hud = nodes.find(n => n.props.label === t('Metal HUD', 'Metal 性能监视器', 'Metal HUD'));
      hud.props.onChange(true);
      assert.equal(written.at(-1).opts, 'MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      for (const [mode, ...labels] of [
        ['compat-hint', 'Enable CrossOver under Properties > Compatibility to install and run the Windows version.',
          '请在“属性 > 兼容性”中启用 CrossOver，以安装并运行 Windows 版本。',
          'Abilita CrossOver in Proprietà > Compatibilità per installare e avviare la versione Windows.'],
        ['image-files-label', 'Image Files (*.tga,*.png,*.exe)', '图像文件 (*.tga,*.png,*.exe)',
          'File immagine (*.tga,*.png,*.exe)'],
        ['library-windows-hint', 'Show only games that run on Windows and do not have a macOS version',
          'Show only games that run on Windows and do not have a macOS version',
          'Mostra solo i giochi che funzionano su Windows e non hanno una versione macOS'],
        ['library-windows-summary', 'Runs on Windows, no Mac OS version', 'Runs on Windows, no Mac OS version',
          'Funziona su Windows, nessuna versione macOS'],
      ]) {
        const src = execFileSync(emit, [mode], { encoding: 'utf8' });
        assert.equal(new Function('globalThis', `return ${src}`)(globals), t(...labels));
      }
    }
  }
}
console.log('PASS: both panel shapes, Chinese/Italian/English locales, fallback, labels and unchanged option values');
