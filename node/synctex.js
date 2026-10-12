'use strict';

const zlib = require('zlib');

// SyncTeX is a byte format. latin1 lets the substitution preserve every byte
// outside project Input lines, including non-UTF-8 records.
function rewrite(gzip, synctexRoot) {
  const source = zlib.gunzipSync(gzip).toString('latin1');
  const root = Buffer.from(synctexRoot.replace(/\/$/, ''), 'utf8').toString('latin1');
  const content = source.replace(/^Input:(\d+):\/compile\/(?:\.\/)?/gm,
    (_match, number) => `Input:${number}:${root}/`);
  return zlib.gzipSync(Buffer.from(content, 'latin1'));
}

module.exports = { rewrite };
