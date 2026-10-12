#!/usr/bin/env node
'use strict';

const assert = require('assert').strict;
const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const { PassThrough } = require('stream');
const { _internal: { redirectPolicy, downloadPath, fetchToFile } } = require('../../node/bridge');
const { _internal: { withCopiedCookieDb } } = require('../../node/chrome-cookie');

async function test(name, fn) {
  await fn();
  console.log(`  [PASS] ${name}`);
}

async function main() {
  console.log('\nBridge Security Tests:');

  await test('same-origin redirect keeps the cookie', () => {
    const next = redirectPolicy('https://www.overleaf.com/a', '/b');
    assert.equal(next.url, 'https://www.overleaf.com/b');
    assert.equal(next.sendCookie, true);
  });

  await test('cross-origin redirect drops the cookie, including a CDN', () => {
    const next = redirectPolicy('https://www.overleaf.com/a', 'https://pdf.example.com/b');
    assert.equal(next.sendCookie, false);
    assert.equal(next.url, 'https://pdf.example.com/b');
  });

  await test('HTTPS to HTTP redirect is refused', () => {
    assert.throws(() => redirectPolicy('https://www.overleaf.com/a', 'http://www.overleaf.com/b'),
      error => error.code === 'DOWNLOAD_FAILED' && /HTTPS to HTTP/.test(error.message));
  });

  await test('download sends cookie only to the original origin across redirects', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-redirect-test-'));
    const originalGet = https.get;
    const seen = [];
    let location = '/output.pdf';
    try {
      https.get = (options, callback) => {
        seen.push(options);
        const req = new EventEmitter();
        req.setTimeout = () => {};
        req.destroy = () => {};
        const res = new PassThrough();
        res.setTimeout = () => {};
        res.statusCode = seen.length % 2 === 1 ? 302 : 200;
        res.headers = res.statusCode === 302 ? { location } : {};
        process.nextTick(() => {
          callback(res);
          res.end(res.statusCode === 200 ? 'PDF' : undefined);
        });
        return req;
      };
      for (const target of ['/output.pdf', 'https://pdf.example.com/output.pdf']) {
        location = target;
        seen.length = 0;
        await fetchToFile('https://www.overleaf.com/start', 'secret=1', path.join(dir, 'output.pdf'));
        assert.equal(seen.length, 2);
        assert.equal(seen[0].headers.Cookie, 'secret=1');
        assert.equal(seen[1].headers.Cookie, target.startsWith('/') ? 'secret=1' : undefined);
        assert.equal(fs.readFileSync(path.join(dir, 'output.pdf'), 'utf8'), 'PDF');
      }
    } finally {
      https.get = originalGet;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  await test('download names are contained and invalid names are rejected', () => {
    const dir = path.join(os.tmpdir(), 'bridge-security-output');
    assert.equal(downloadPath(dir, 'x/../../out.pdf'), path.join(dir, 'overleaf_out.pdf'));
    for (const name of ['', '.', '..', 'x/..', 'bad\0name']) {
      assert.throws(() => downloadPath(dir, name), error => error.code === 'INVALID_PARAM');
    }
  });

  await test('cookie DB, WAL and SHM copies are private and removed on success or failure', () => {
    const sourceDir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-cookie-test-'));
    const db = path.join(sourceDir, 'Cookies');
    fs.writeFileSync(db, 'db');
    fs.writeFileSync(db + '-wal', 'wal');
    fs.writeFileSync(db + '-shm', 'shm');
    let copyDir;
    try {
      withCopiedCookieDb(db, copy => {
        copyDir = path.dirname(copy);
        assert.equal(fs.statSync(copyDir).mode & 0o777, 0o700);
        assert.equal(fs.readFileSync(copy, 'utf8'), 'db');
        assert.equal(fs.readFileSync(copy + '-wal', 'utf8'), 'wal');
        assert.equal(fs.readFileSync(copy + '-shm', 'utf8'), 'shm');
      });
      assert.equal(fs.existsSync(copyDir), false);
      assert.throws(() => withCopiedCookieDb(db, copy => {
        copyDir = path.dirname(copy);
        throw new Error('test failure');
      }), /test failure/);
      assert.equal(fs.existsSync(copyDir), false);
    } finally {
      fs.rmSync(sourceDir, { recursive: true, force: true });
    }
  });

  await test('transfer timeout, abort and stream errors remove the staging file', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-transfer-test-'));
    const originalGet = http.get;
    try {
      for (const failure of ['timeout', 'abort', 'request-error', 'response-error']) {
        let req;
        let res;
        http.get = (_options, callback) => {
          req = new EventEmitter();
          req.setTimeout = (_ms, onTimeout) => { req.onTimeout = onTimeout; };
          req.destroy = () => { req.destroyed = true; };
          res = new PassThrough();
          res.statusCode = 200;
          res.headers = {};
          res.setTimeout = (_ms, onTimeout) => { res.onTimeout = onTimeout; };
          process.nextTick(() => {
            callback(res);
            res.write('partial');
          });
          return req;
        };
        const dest = path.join(dir, failure);
        fs.writeFileSync(dest, 'old');
        const transfer = fetchToFile('http://127.0.0.1/download', 'secret=1', dest, 5,
          'http://127.0.0.1', 20);
        for (let i = 0; i < 100 && !fs.existsSync(dest + '.part'); i++) {
          await new Promise(resolve => setTimeout(resolve, 5));
        }
        assert.equal(fs.existsSync(dest + '.part'), true);
        if (failure === 'timeout') req.onTimeout();
        else if (failure === 'abort') res.emit('aborted');
        else if (failure === 'request-error') req.emit('error', new Error('request failed'));
        else res.emit('error', new Error('response failed'));
        await assert.rejects(transfer, error => error.code === 'DOWNLOAD_FAILED');
        assert.equal(req.destroyed, true);
        assert.equal(fs.existsSync(dest + '.part'), false);
        assert.equal(fs.readFileSync(dest, 'utf8'), 'old');
      }
    } finally {
      http.get = originalGet;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}

main().catch(error => { console.error(error); process.exitCode = 1; });
