#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const text0 = require('ot-json0/lib/text0');

let seed = 0x2a9d41;
function next() {
  seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
  return seed;
}
function pick(n) { return next() % n; }

const alphabet = ['a', 'b', ' ', '\n', 'é', '日', '😀', '𝔸'];
function word(n) {
  let s = '';
  for (let i = 0; i < n; i++) s += alphabet[pick(alphabet.length)];
  return s;
}
function offset(chars, index) { return chars.slice(0, index).join('').length; }
function operation(start) {
  let current = start;
  const op = [];
  const count = 1 + pick(4);
  for (let k = 0; k < count; k++) {
    const chars = Array.from(current);
    const insert = chars.length === 0 || pick(2) === 0;
    if (insert) {
      const p = offset(chars, pick(chars.length + 1));
      const c = { p, i: word(1 + pick(3)) };
      op.push(c);
      current = text0.apply(current, [c]);
    } else {
      const startIndex = pick(chars.length);
      const length = 1 + pick(Math.min(3, chars.length - startIndex));
      const c = { p: offset(chars, startIndex), d: chars.slice(startIndex, startIndex + length).join('') };
      op.push(c);
      current = text0.apply(current, [c]);
    }
  }
  return op;
}

const cases = [];
for (let i = 0; i < 1000; i++) {
  const s = word(pick(13));
  const a = operation(s);
  const b = operation(s);
  const left = text0.transform(a, b, 'left');
  const right = text0.transform(b, a, 'right');
  if (text0.apply(text0.apply(s, a), right) !== text0.apply(text0.apply(s, b), left)) {
    throw new Error(`reference failed to converge at case ${i}`);
  }
  cases.push({ s, a, b, left, right });
}
const target = path.join(__dirname, '../fixtures/ot_text0.json');
fs.writeFileSync(target, JSON.stringify(cases) + '\n');
console.log(`${cases.length} fixtures, ${fs.statSync(target).size} bytes`);
