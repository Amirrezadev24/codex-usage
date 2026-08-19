const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage, screen } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { snapshot } = require('./usage');

let window, tray, quitting = false;
function createWindow() {
  window = new BrowserWindow({ width: 320, height: 245, minWidth: 280, minHeight: 190, frame: false, transparent: true, alwaysOnTop: true, resizable: true, show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
  window.loadFile(path.join(__dirname, 'src', 'index.html'));
  if (process.env.CODEX_PULSE_CAPTURE) setTimeout(async () => { fs.writeFileSync(process.env.CODEX_PULSE_CAPTURE, (await window.webContents.capturePage()).toPNG()); quitting = true; app.quit(); }, 5000);
  window.once('ready-to-show', () => { const area = screen.getPrimaryDisplay().workArea; window.setPosition(area.x + area.width - 340, area.y + 20); window.show(); });
  window.on('close', e => { if (!quitting) { e.preventDefault(); window.hide(); } });
}
function showWindow() { window.show(); window.focus(); }
app.whenReady().then(() => {
  ipcMain.handle('usage:snapshot', () => snapshot());
  ipcMain.on('window:hide', () => window.hide());
  ipcMain.on('window:compact', (_, compact) => window.setSize(window.getBounds().width, compact ? 165 : 245, true));
  createWindow();
  tray = new Tray(nativeImage.createFromPath(path.join(__dirname, 'assets', 'tray.svg'))); tray.setToolTip('Codex Pulse');
  tray.setContextMenu(Menu.buildFromTemplate([{ label: 'Show Codex Pulse', click: showWindow }, { label: 'Refresh now', click: () => window.webContents.send('usage:refresh') }, { type: 'separator' }, { label: 'Quit', click: () => { quitting = true; app.quit(); } }]));
  tray.on('double-click', showWindow);
}).catch(error => { console.error(error); if (process.env.CODEX_PULSE_CAPTURE) fs.writeFileSync(`${process.env.CODEX_PULSE_CAPTURE}.error`, error.stack); app.quit(); });
app.on('window-all-closed', e => e.preventDefault());
