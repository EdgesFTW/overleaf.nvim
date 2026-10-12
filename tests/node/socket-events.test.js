#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const SocketManager = require('../../node/socket');

const events = [];
const manager = new SocketManager('cookie', 'project', (event, data) => events.push({ event, data }));
manager.socket = new EventEmitter();
manager.socket.onevent = () => {};
manager._setupEventHandlers();

manager.socket.emit('reciveNewFolder', 'root', { _id: 'folder', name: 'drafts' }, {});
manager.socket.emit('reciveEntityRename', 'folder', 'chapters', {});
manager.socket.emit('reciveEntityMove', 'folder', 'target', {});
manager.socket.emit('reciveEntityMove', 'folder', 'old-parent', 'new-parent');

assert.deepEqual(events[0], {
  event: 'reciveNewFolder',
  data: { parentFolderId: 'root', folder: { _id: 'folder', name: 'drafts' }, meta: {} },
});
assert.deepEqual(events[1], {
  event: 'reciveEntityRename',
  data: { entityId: 'folder', newName: 'chapters', meta: {} },
});
assert.equal(events[2].event, 'reciveEntityMove');
assert.equal(events[2].data.parentFolderId, 'target');
assert.equal(events[3].data.newParentFolderId, 'new-parent');
console.log('Socket structure events: 4 passed');
