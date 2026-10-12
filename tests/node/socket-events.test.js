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

manager.socket.emit('otUpdateApplied', { doc: 'doc', v: 2, op: [] });
manager.socket.emit('otUpdateApplied', { doc: 'doc', v: 3 });
assert.equal(Object.prototype.hasOwnProperty.call(events[0].data, 'op'), true);
assert.equal(Object.prototype.hasOwnProperty.call(events[1].data, 'op'), false);
events.length = 0;

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

// Overleaf emits otUpdateError(errorString, { project_id, doc_id, error, message }).
events.length = 0;
manager.socket.emit('otUpdateError', 'Delete component does not match', {
  project_id: 'project', doc_id: 'doc', error: 'Delete component does not match', message: 'Delete component does not match',
});
assert.deepEqual(events[0], {
  event: 'otUpdateError',
  data: { message: 'Delete component does not match', doc_id: 'doc' },
});

// applyOtUpdate passes dupIfSource through on a resend, and omits it otherwise.
(async () => {
  const sent = [];
  manager.socket.emit = (name, docId, update, cb) => { sent.push(update); cb(null); };
  await manager.applyOtUpdate('doc', [{ p: 0, i: 'x' }], 3, 'abc', false, ['s1', 's2']);
  await manager.applyOtUpdate('doc', [{ p: 0, i: 'x' }], 3, 'abc', false);
  assert.deepEqual(sent[0].dupIfSource, ['s1', 's2']);
  assert.equal(Object.prototype.hasOwnProperty.call(sent[1], 'dupIfSource'), false);
  console.log('Socket structure events: 6 passed');
})().catch((e) => { console.error(e); process.exit(1); });
