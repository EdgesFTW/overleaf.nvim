#!/usr/bin/env node
'use strict';

const assert = require('assert').strict;
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const zlib = require('zlib');
const { spawn } = require('child_process');
const { rewrite } = require('../../node/synctex');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-synctex-'));
const body = Buffer.concat([
  Buffer.from('SyncTeX Version:1\nInput:1:/compile/./main.tex\nInput:2:/compile/chapters/intro.tex\nInput:3:/usr/texlive/article.cls\n', 'latin1'),
  Buffer.from([0x21, 0x35, 0x3a, 0xff, 0x00, 0x0a]),
  Buffer.from('Postamble:\n', 'latin1'),
]);
const gz = zlib.gzipSync(body);

async function main() {
  const mirror = "/tmp/mirror space/it's-é";
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/gzip' });
    res.end(gz);
  });
  const expected = Buffer.from(body.toString('latin1').replace(/^Input:(\d+):\/compile\/(?:\.\/)?/gm,
    (_match, number) => `Input:${number}:${Buffer.from(mirror).toString('latin1')}/`), 'latin1');
  assert.deepEqual(zlib.gunzipSync(rewrite(gz, mirror)), expected);
  assert(expected.includes(Buffer.from('/usr/texlive/article.cls')));
  assert(expected.includes(Buffer.from([0x21, 0x35, 0x3a, 0xff, 0x00, 0x0a])));
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
  } catch (error) {
    if (error.code !== 'EPERM') throw error;
    console.log('SyncTeX rewrite: 1 passed; bridge integration skipped (sandbox denies local sockets)');
    fs.rmSync(root, { recursive: true, force: true });
    return;
  }
  const bridge = spawn('node', [path.join(__dirname, '../../node/bridge.js')], { stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  const pending = new Map();
  bridge.stdout.on('data', chunk => {
    buffer += chunk.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      if (!line) continue;
      const message = JSON.parse(line);
      if (pending.has(message.id)) {
        pending.get(message.id)(message);
        pending.delete(message.id);
      }
    }
  });
  let nextId = 1;
  function request(params) {
    const id = nextId++;
    return new Promise(resolve => {
      pending.set(id, resolve);
      bridge.stdin.write(JSON.stringify({ id, method: 'downloadUrl', params }) + '\n');
    });
  }
  try {
    const url = `http://127.0.0.1:${server.address().port}/output.synctex.gz`;
    const rewritten = await request({ cookie: 'test=1', url, fileName: 'rewrite.synctex.gz', outputDir: root, synctexRoot: mirror });
    assert(!rewritten.error, JSON.stringify(rewritten.error));
    assert.deepEqual(zlib.gunzipSync(fs.readFileSync(rewritten.result.path)), expected);
    const plain = await request({ cookie: 'test=1', url, fileName: 'plain.synctex.gz', outputDir: root });
    assert(!plain.error, JSON.stringify(plain.error));
    assert.deepEqual(fs.readFileSync(plain.result.path), gz);
    console.log('SyncTeX rewrite: 2 passed');
  } finally {
    bridge.kill();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
