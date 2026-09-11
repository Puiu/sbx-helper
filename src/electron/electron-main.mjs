// electron-main.mjs — desktop wrapper around server.mjs. Starts the same
// server the browser-mode (`node server.mjs`) flow uses, and opens a native
// window pointed at it instead of the system browser. No preload script, no
// IPC — public/app.js keeps talking to the same /api/* routes over fetch()
// either way; Electron's default security settings (contextIsolation: true,
// nodeIntegration: false) already match what a fetch-only renderer needs.

import { app, BrowserWindow } from 'electron';
import path from 'node:path';

let mainWindow;

async function createWindow() {
  // Must happen before server.mjs is evaluated — it reads this env var at
  // module top-level to decide where sbx-helper.json lives. A packaged app's
  // files sit in a read-only asar archive, so "beside the script" (the
  // browser-mode default) would fail to write there; app.getPath('userData')
  // is Electron's standard writable location instead.
  process.env.SBX_HELPER_CONFIG = path.join(app.getPath('userData'), 'sbx-helper.json');

  // A dynamic import (not a static one) so the line above runs first —
  // static imports are hoisted ahead of any other top-level code.
  const { startServer } = await import('./server.mjs');
  const { url } = await startServer({ openBrowser: false });

  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 900,
    minHeight: 560,
    title: 'sbx-helper',
    show: false,
  });
  mainWindow.once('ready-to-show', () => mainWindow.show());
  await mainWindow.loadURL(url);
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
