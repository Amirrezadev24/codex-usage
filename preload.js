const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('pulse', {
  snapshot: () => ipcRenderer.invoke('usage:snapshot'),
  hide: () => ipcRenderer.send('window:hide'),
  compact: value => ipcRenderer.send('window:compact', value),
  onRefresh: callback => ipcRenderer.on('usage:refresh', callback)
});
