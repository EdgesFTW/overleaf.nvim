#!/usr/bin/env node
'use strict';

const assert = require('assert').strict;
const fixture = require('../fixtures/join_ranges_encoded.json');
const SocketManager = require('../../node/socket');

async function main() {
  for (const asString of [false, true]) {
    const manager = new SocketManager('', '', () => {});
    manager._promisifiedEmit = async (event, docId, version, options) => {
      assert.equal(event, 'joinDoc');
      assert.equal(docId, 'doc');
      assert.equal(version, -1);
      assert.deepEqual(options, { encodeRanges: true });
      const ranges = JSON.parse(JSON.stringify(fixture.ranges));
      return [fixture.lines, 4, [], asString ? JSON.stringify(ranges) : ranges];
    };
    const result = await manager.joinDoc('doc');
    assert.deepEqual(result.lines, ['é😀']);
    assert.equal(result.ranges.comments[0].op.c, 'é😀');
    assert.equal(result.ranges.changes[0].op.i, '日😀');
    assert.equal(result.ranges.changes[1].op.d, 'é𝔸');
    console.log(`  [PASS] joinDoc decodes encoded range text (${asString ? 'JSON' : 'object'})`);
  }
}
main().catch(err => { console.error(err); process.exitCode = 1; });
