'use strict';

const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execSync } = require('child_process');

/**
 * Extract Overleaf session cookie from Chrome/Chromium on macOS and Linux.
 */

const CHROME_MAC_BASE_DIR = 'Library/Application Support/Google/Chrome';
const CHROME_LINUX_PATHS = [
  { browser: 'chrome', path: '.config/google-chrome' },
  { browser: 'chrome (flatpak)', path: '.var/app/com.google.Chrome/config/google-chrome' },
  { browser: 'chromium', path: '.config/chromium' },
  { browser: 'chromium (flatpak)', path: '.var/app/org.chromium.Chromium/config/chromium' },
  { browser: 'chromium (snap)', path: 'snap/chromium/common/chromium' },
];
let secretToolMissingHintShown = false;

function isSecretToolMissingError(err) {
  // shell returns 127 when command is missing; ENOENT may appear in some environments
  return err && (err.status === 127 || err.code === 'ENOENT');
}

function trimTrailingNewlines(buffer) {
  if (!buffer || buffer.length === 0) return buffer;
  let end = buffer.length;
  while (end > 0 && (buffer[end - 1] === 0x0a || buffer[end - 1] === 0x0d)) {
    end--;
  }
  return buffer.slice(0, end);
}

// Every Chrome/Chromium install present on this machine, in preference order.
// A user can easily have several (e.g. native Chromium plus Flatpak Chrome),
// and only one of them holds the Overleaf session -- so callers search all.
function resolveChromeBaseDirs(options = {}) {
  const platform = options.platform || os.platform();
  const homeDir = options.homeDir || os.homedir();
  const existsSync = options.existsSync || fs.existsSync;

  if (platform === 'darwin') {
    return [{ browser: 'chrome', baseDir: path.join(homeDir, CHROME_MAC_BASE_DIR) }];
  }
  if (platform !== 'linux') {
    throw { code: 'UNSUPPORTED', message: 'Chrome cookie extraction only supported on macOS and Linux' };
  }

  const found = [];
  for (const candidate of CHROME_LINUX_PATHS) {
    const baseDir = path.join(homeDir, candidate.path);
    if (existsSync(baseDir)) found.push({ browser: candidate.browser, baseDir });
  }
  if (found.length === 0) {
    throw { code: 'NOT_FOUND', message: 'Chrome/Chromium data directory not found' };
  }
  return found;
}

function resolveChromeBaseDir(options = {}) {
  const platform = options.platform || os.platform();
  const homeDir = options.homeDir || os.homedir();
  const existsSync = options.existsSync || fs.existsSync;

  if (platform === 'darwin') {
    const baseDir = path.join(homeDir, CHROME_MAC_BASE_DIR);
    return { browser: 'chrome', baseDir };
  }

  if (platform === 'linux') {
    for (const candidate of CHROME_LINUX_PATHS) {
      const baseDir = path.join(homeDir, candidate.path);
      if (existsSync(baseDir)) {
        console.log(`Chrome base dir: ${baseDir} (browser: ${candidate.browser})`);
        return { browser: candidate.browser, baseDir };
      }
    }
    throw { code: 'NOT_FOUND', message: 'Chrome/Chromium data directory not found' };
  }

  throw {
    code: 'UNSUPPORTED',
    message: 'Chrome cookie extraction only supported on macOS and Linux',
  };
}

function trySecretToolLookup(args, asBuffer) {
  const options = {
    stdio: ['ignore', 'pipe', 'ignore'],
  };
  if (asBuffer) {
    options.encoding = 'buffer';
  } else {
    options.encoding = 'utf-8';
  }

  try {
    const result = execSync(`secret-tool lookup ${args}`, options);
    if (asBuffer) {
      const raw = trimTrailingNewlines(result);
      return raw && raw.length > 0 ? raw : null;
    }
    const trimmed = result.trim();
    return trimmed || null;
  } catch (e) {
    if (isSecretToolMissingError(e) && !secretToolMissingHintShown) {
      console.log('Keyring: secret-tool not found (libsecret-tools is not installed)');
      console.log('Keyring: install with: sudo apt install libsecret-tools');
      secretToolMissingHintShown = true;
    }
    return null;
  }
}

function normalizeV11Key(secretBuffer) {
  if (!secretBuffer || secretBuffer.length === 0) {
    return null;
  }

  const raw = trimTrailingNewlines(secretBuffer);
  if (raw.length === 32) {
    return Buffer.from(raw);
  }

  const asText = raw.toString('utf-8').trim();
  if (!asText) {
    return null;
  }

  if (/^[0-9a-fA-F]{64}$/.test(asText)) {
    return Buffer.from(asText, 'hex');
  }

  if (/^[A-Za-z0-9+/=]+$/.test(asText)) {
    try {
      const decoded = Buffer.from(asText, 'base64');
      if (decoded.length === 32) {
        return decoded;
      }
    } catch (e) {
      // ignore base64 decode errors
    }
  }

  return null;
}

function getLinuxPassword() {
  const password = trySecretToolLookup('application chrome', false);
  if (password) {
    console.log('Keyring: secret-tool succeeded');
    return password;
  }

  console.log('Keyring: falling back to hardcoded password');
  return 'peanuts';
}

function getLinuxV11Key() {
  const raw = trySecretToolLookup('xdg:schema chrome_libsecret_os_crypt_password_v2', true);
  if (!raw) {
    return null;
  }

  const key = normalizeV11Key(raw);
  if (key) {
    console.log('Keyring: secret-tool v11 key lookup succeeded');
    return key;
  }

  console.log('Keyring: secret-tool v11 key lookup returned unusable key');
  return null;
}

function getEncryptionKeys(options = {}) {
  const platform = options.platform || os.platform();

  if (platform === 'darwin') {
    const password = execSync(
      'security find-generic-password -w -s "Chrome Safe Storage" -a "Chrome"',
      { encoding: 'utf-8' }
    ).trim();

    return {
      keyV10: crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1'),
      keyV11: null,
    };
  }

  if (platform === 'linux') {
    const password = getLinuxPassword();
    return {
      keyV10: crypto.pbkdf2Sync(password, 'saltysalt', 1, 16, 'sha1'),
      keyV11: getLinuxV11Key(),
    };
  }

  throw {
    code: 'UNSUPPORTED',
    message: 'Chrome cookie extraction only supported on macOS and Linux',
  };
}

function ensureSqlite3Available(options = {}) {
  const run = options.execSyncFn || execSync;
  const platform = options.platform || os.platform();

  try {
    run('command -v sqlite3', {
      stdio: ['ignore', 'pipe', 'ignore'],
      encoding: 'utf-8',
    });
  } catch (e) {
    if (platform === 'linux') {
      console.log('sqlite3 check: sqlite3 not found in PATH');
      console.log('sqlite3 check: install with: sudo apt install sqlite3');
      throw {
        code: 'SQLITE3_MISSING',
        message: 'Chrome cookie extraction requires sqlite3. Install with: sudo apt install sqlite3',
      };
    }
    console.log('sqlite3 check: sqlite3 not found in PATH');
    throw {
      code: 'SQLITE3_MISSING',
      message: 'Chrome cookie extraction requires sqlite3',
    };
  }
}

/**
 * List available Chrome profiles.
 * Returns array of { dir: 'Default', name: 'Person 1' }
 */
function listProfiles() {
  const profiles = [];
  for (const { browser, baseDir } of resolveChromeBaseDirs()) {
    for (const p of listProfilesIn(baseDir, browser)) profiles.push(p);
  }
  return profiles;
}

function listProfilesIn(baseDir, browser) {
  if (!fs.existsSync(baseDir)) return [];

  const profiles = [];
  const entries = fs.readdirSync(baseDir, { withFileTypes: true });

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    // Any directory with a Cookies db is a usable profile. Chrome's own are
    // 'Default' / 'Profile N', but users can create arbitrarily named ones.
    const cookiesDb = path.join(baseDir, entry.name, 'Cookies');
    if (!fs.existsSync(cookiesDb)) continue;

    let displayName = entry.name;
    let email = '';
    try {
      const prefsPath = path.join(baseDir, entry.name, 'Preferences');
      if (fs.existsSync(prefsPath)) {
        const prefs = JSON.parse(fs.readFileSync(prefsPath, 'utf-8'));
        // Try to get email from account_info
        if (prefs.account_info && Array.isArray(prefs.account_info) && prefs.account_info[0]) {
          email = prefs.account_info[0].email || '';
        }
        if (prefs.profile && prefs.profile.name) {
          displayName = email || prefs.profile.name;
        }
      }
    } catch (e) {
      // Use directory name as fallback
    }

    profiles.push({
      dir: entry.name,
      name: `${displayName} [${browser}]`,
      email,
      baseDir,
      browser,
    });
  }

  return profiles;
}

function decryptCookieValue(encryptedValue, keyV10, keyV11) {
  if (!encryptedValue || encryptedValue.length === 0) {
    return '';
  }

  const prefix = encryptedValue.slice(0, 3).toString('utf-8');

  if (prefix === 'v11' && keyV11) {
    try {
      const nonce = encryptedValue.slice(3, 15);
      const ciphertext = encryptedValue.slice(15, encryptedValue.length - 16);
      const tag = encryptedValue.slice(encryptedValue.length - 16);

      const decipher = crypto.createDecipheriv('aes-256-gcm', keyV11, nonce);
      decipher.setAuthTag(tag);
      const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      return decrypted.toString('utf-8');
    } catch (e) {
      console.log('Cookie decryption: v11 failed, trying v10 fallback');
    }
  }

  if (prefix === 'v10' || prefix === 'v11') {
    try {
      const encrypted = encryptedValue.slice(3);
      const iv = Buffer.alloc(16, ' ');

      const decipher = crypto.createDecipheriv('aes-128-cbc', keyV10, iv);
      let decrypted = decipher.update(encrypted);
      decrypted = Buffer.concat([decrypted, decipher.final()]);
      const raw = decrypted.toString('utf-8');

      // Chrome's CBC decryption may produce garbage in the first block
      // due to IV mismatch on newer versions. Overleaf session cookies
      // always contain 's%3A' (URL-encoded 's:' Express session prefix).
      const idx = raw.indexOf('s%3A');
      if (idx >= 0) {
        return raw.substring(idx);
      }

      return raw;
    } catch (e) {
      console.log('Cookie decryption: v10 failed');
    }
  }

  return encryptedValue.toString('utf-8');
}

/**
 * Extract Overleaf cookie from a specific Chrome profile.
 * @param {string} profileDir - Profile directory name (e.g. 'Default', 'Profile 1')
 */
// Chrome stores timestamps as microseconds since 1601-01-01 UTC.
function chromeTimeToUnixMs(v) {
  const n = Number(v);
  if (!n) return 0;
  return Math.round(n / 1000 - 11644473600000);
}

function cookieDomainForQuery() {
  let cookieDomain = 'overleaf.com';
  if (process.env.OVERLEAF_URL) {
    try {
      cookieDomain = new URL(process.env.OVERLEAF_URL).hostname;
    } catch (e) { /* keep default */ }
  }
  return cookieDomain;
}

// Every overleaf_session2 row in one profile's cookie db, with its timestamps.
function queryProfileCookies(cookiesDb) {
  const tmpDb = path.join(os.tmpdir(), `overleaf_cookies_${process.pid}_${Math.abs(hashString(cookiesDb))}.db`);
  try {
    fs.copyFileSync(cookiesDb, tmpDb);
  } catch (e) {
    return [];
  }
  try {
    const query =
      `SELECT name, hex(encrypted_value), creation_utc, last_access_utc, expires_utc ` +
      `FROM cookies WHERE host_key LIKE '%${cookieDomainForQuery()}' AND name = 'overleaf_session2';`;
    const out = execSync(`sqlite3 "${tmpDb}" "${query}"`, { encoding: 'utf-8' }).trim();
    if (!out) return [];
    return out.split('\n').map((line) => {
      const [name, hexValue, creation, lastAccess, expires] = line.split('|');
      return {
        name,
        hexValue,
        creation: chromeTimeToUnixMs(creation),
        lastAccess: chromeTimeToUnixMs(lastAccess),
        expires: chromeTimeToUnixMs(expires),
      };
    }).filter((r) => r.hexValue);
  } catch (e) {
    return [];
  } finally {
    try { fs.unlinkSync(tmpDb); } catch (e) { /* ignore */ }
  }
}

function hashString(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) | 0;
  return h;
}

// Search every profile of every detected browser. Newest session first, so the
// browser you logged into most recently wins when several profiles have one.
function findOverleafCookies(profileFilter, baseDirOverride) {
  const bases = baseDirOverride
    ? [{ browser: 'explicit', baseDir: baseDirOverride }]
    : resolveChromeBaseDirs();

  const found = [];
  for (const { browser, baseDir } of bases) {
    for (const profile of listProfilesIn(baseDir, browser)) {
      if (profileFilter && profile.dir !== profileFilter) continue;
      const cookiesDb = path.join(baseDir, profile.dir, 'Cookies');
      for (const row of queryProfileCookies(cookiesDb)) {
        found.push({ ...row, browser, baseDir, profile: profile.dir, label: profile.name });
      }
    }
  }

  // Most recently used session first; fall back to creation, then expiry.
  found.sort((a, b) =>
    (b.lastAccess - a.lastAccess) || (b.creation - a.creation) || (b.expires - a.expires));
  return found;
}

// profileDir is optional: with it, only that profile is searched; without it,
// every profile of every detected browser is searched and the most recently
// used Overleaf session wins.
async function getOverleafCookie(profileDir, baseDirOverride) {
  ensureSqlite3Available();

  const candidates = findOverleafCookies(profileDir || null, baseDirOverride);
  if (candidates.length === 0) {
    throw {
      code: 'NO_COOKIE',
      message: profileDir
        ? `No overleaf_session2 cookie in profile "${profileDir}". Log in to overleaf.com in that browser profile first.`
        : 'No overleaf_session2 cookie found in any Chrome/Chromium profile. Log in to overleaf.com first.',
    };
  }

  console.log(`Cookie search: ${candidates.length} candidate(s) across profiles`);

  const { keyV10, keyV11 } = getEncryptionKeys();

  let lastErr = null;
  for (const c of candidates) {
    try {
      const value = decryptCookieValue(Buffer.from(c.hexValue, 'hex'), keyV10, keyV11);
      if (!value || !value.startsWith('s%3A')) {
        throw { code: 'DECRYPT_FAILED', message: 'decrypted value is not a session cookie' };
      }
      const when = c.lastAccess ? new Date(c.lastAccess).toISOString() : 'unknown';
      console.log(`Cookie source: ${c.browser} / ${c.profile} (last used ${when})`);
      return `${c.name}=${value}`;
    } catch (e) {
      lastErr = e;
      console.log(`Cookie candidate rejected (${c.browser} / ${c.profile}): ${e.message || e.code}`);
    }
  }

  throw lastErr || { code: 'DECRYPT_FAILED', message: 'Failed to decrypt any Overleaf cookie.' };
}

async function extractFrom(cookiesDb) {

  ensureSqlite3Available();

  const { keyV10, keyV11 } = getEncryptionKeys();

  const tmpDb = path.join(os.tmpdir(), 'overleaf_chrome_cookies_' + process.pid + '.db');
  fs.copyFileSync(cookiesDb, tmpDb);

  try {
    // Extract domain from OVERLEAF_URL for self-hosted instances
    let cookieDomain = 'overleaf.com';
    if (process.env.OVERLEAF_URL) {
      try {
        const parsedUrl = new URL(process.env.OVERLEAF_URL);
        cookieDomain = parsedUrl.hostname;
      } catch (e) { /* keep default */ }
    }
    const query = `SELECT name, hex(encrypted_value) FROM cookies WHERE host_key LIKE '%${cookieDomain}' AND name = 'overleaf_session2' ORDER BY expires_utc DESC LIMIT 1;`;
    const result = execSync(
      `sqlite3 "${tmpDb}" "${query}"`,
      { encoding: 'utf-8' }
    ).trim();

    if (!result) {
      throw { code: 'NO_COOKIE', message: 'No overleaf_session2 cookie found in Chrome. Log in to overleaf.com in Chrome first.' };
    }

    const [name, hexValue] = result.split('|');
    if (!hexValue) {
      throw { code: 'NO_COOKIE', message: 'Cookie value is empty' };
    }

    const encryptedValue = Buffer.from(hexValue, 'hex');
    const value = decryptCookieValue(encryptedValue, keyV10, keyV11);

    if (!value || !value.startsWith('s%3A')) {
      throw { code: 'DECRYPT_FAILED', message: 'Failed to decrypt cookie. Try setting cookie manually.' };
    }

    return `${name}=${value}`;
  } finally {
    try { fs.unlinkSync(tmpDb); } catch (e) { /* ignore */ }
  }
}

module.exports = {
  getOverleafCookie,
  listProfiles,
  _internal: {
    resolveChromeBaseDir,
    resolveChromeBaseDirs,
    findOverleafCookies,
    chromeTimeToUnixMs,
    decryptCookieValue,
    normalizeV11Key,
    ensureSqlite3Available,
  },
};
