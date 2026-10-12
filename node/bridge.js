#!/usr/bin/env node
'use strict';

const readline = require('readline');
const auth = require('./auth');
const SocketManager = require('./socket');
const { getOverleafCookie, listProfiles } = require('./chrome-cookie');

// Redirect console.log to stderr (stdout is the RPC channel)
if (require.main === module) {
  console.log = (...args) => console.error('[bridge]', ...args);
}

const BASE_URL = process.env.OVERLEAF_URL || 'https://www.overleaf.com';

// SyncTeX is keyed by an editor id the *client* invents. The same one has to be
// sent on the compile and on the sync lookup: omit it and Overleaf forwards
// `editorId=undefined` to the CLSI and answers 500; send one that does not match
// the build and it answers 404. One per bridge process is enough, since a build
// outlives nothing longer than the session that made it.
const EDITOR_ID = require('crypto').randomUUID();

let requestId = 0;
let socketManager = null;
let pendingRequests = 0;
let stdinClosed = false;

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function sendResult(id, result) {
  send({ id, result });
}

function sendError(id, code, message) {
  send({ id, error: { code, message } });
}

function sendEvent(event, data) {
  send({ event, data });
}

// Download `url` to `destPath`, following redirects and refusing anything that
// is not a 200. Writing whatever the server returned -- an error page, or
// nothing at all -- produces a file that looks fine to the caller and is
// garbage to whatever opens it, which is how the 0-byte PDF bug worked.
function redirectPolicy(fromUrl, toUrl, originalOrigin = new URL(fromUrl).origin) {
  const from = new URL(fromUrl);
  const to = new URL(toUrl, from);
  if (from.protocol === 'https:' && to.protocol === 'http:') {
    throw { code: 'DOWNLOAD_FAILED', message: 'Refusing HTTPS to HTTP download redirect' };
  }
  if (to.protocol !== 'http:' && to.protocol !== 'https:') {
    throw { code: 'DOWNLOAD_FAILED', message: `Unsupported download redirect protocol: ${to.protocol}` };
  }
  return { url: to.href, sendCookie: to.origin === originalOrigin };
}

function fetchToFile(url, cookie, destPath, redirectsLeft = 5, originalOrigin = new URL(url).origin, timeoutMs = 60000) {
  const fs = require('fs');
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      reject({ code: 'DOWNLOAD_FAILED', message: `Unsupported download protocol: ${parsed.protocol}` });
      return;
    }
    const httpModule = parsed.protocol === 'http:' ? require('http') : require('https');
    const partPath = destPath + '.part';
    let req;
    let res;
    let ws;
    let settled = false;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      if (req) req.destroy();
      if (res) res.destroy();
      const done = () => fs.rm(partPath, { force: true }, () => reject({
        code: 'DOWNLOAD_FAILED', message: error.message || String(error),
      }));
      if (ws && !ws.closed) {
        ws.once('close', done);
        ws.destroy();
      } else {
        done();
      }
    };
    try { req = httpModule.get({
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
      path: parsed.pathname + parsed.search,
      headers: parsed.origin === originalOrigin ? { Cookie: cookie } : {},
    }, (response) => {
      res = response;
      if (settled) { res.destroy(); return; }
      res.on('error', fail);
      res.on('aborted', () => fail(new Error('Download response aborted')));
      res.setTimeout(timeoutMs, () => fail(new Error('Download timed out')));
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
        if (redirectsLeft <= 0) {
          fail(new Error('Too many redirects'));
          return;
        }
        let next;
        try { next = redirectPolicy(url, res.headers.location, originalOrigin); } catch (e) { fail(e); return; }
        settled = true;
        res.destroy();
        resolve(fetchToFile(next.url, cookie, destPath, redirectsLeft - 1, originalOrigin, timeoutMs));
        return;
      }
      if (res.statusCode !== 200) {
        fail(new Error(`Download failed with status ${res.statusCode}`));
        return;
      }
      // Written only for a confirmed 200, so a failure leaves no partial file.
      // Staged through a sibling and renamed, which is atomic within a
      // directory: a PDF viewer watching destPath for changes sees either the
      // previous build or the new one, never a truncated stream.
      try { ws = fs.createWriteStream(partPath, { mode: 0o600 }); } catch (e) { fail(e); return; }
      ws.on('error', fail);
      res.pipe(ws);
      ws.on('finish', () => {
        ws.close(() => {
          if (settled) return;
          try {
            fs.renameSync(partPath, destPath);
            settled = true;
            resolve();
          } catch (e) {
            fail(new Error(`Could not replace ${destPath}: ${e.message}`));
          }
        });
      });
    }); } catch (e) { fail(e); return; }
    req.on('error', fail);
    req.setTimeout(timeoutMs, () => fail(new Error('Download timed out')));
  });
}

function downloadPath(dir, fileName) {
  const path = require('path');
  if (typeof fileName !== 'string' || !fileName || fileName === '.' || fileName === '..' || fileName.includes('\0')) {
    throw { code: 'INVALID_PARAM', message: 'Invalid download file name' };
  }
  const baseName = path.basename(fileName);
  if (!baseName || baseName === '.' || baseName === '..') {
    throw { code: 'INVALID_PARAM', message: 'Invalid download file name' };
  }
  const root = path.resolve(dir);
  const dest = path.resolve(root, 'overleaf_' + baseName);
  const prefix = root.endsWith(path.sep) ? root : root + path.sep;
  if (!dest.startsWith(prefix)) {
    throw { code: 'INVALID_PARAM', message: 'Download path escapes output directory' };
  }
  return dest;
}

// Downloads default to a private per-user directory rather than a shared
// /tmp: the old path was world-readable and predictable, so on a multi-user
// machine anyone could read a compiled paper, or pre-place a symlink there.
function downloadDir(outputDir) {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const dir = outputDir || path.join(os.tmpdir(), `overleaf-nvim-${process.getuid ? process.getuid() : 'user'}`);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

// Both SyncTeX directions answer with JSON and use the same failure modes:
// 404 once the build has been evicted, 400 for a path the server will not accept.
async function syncTexRequest(cookie, url) {
  const res = await auth.httpGet(url, auth.normalizeCookie(cookie).cookie);
  if (res.status === 404) {
    throw { code: 'SYNCTEX_NO_BUILD', message: 'The compiled build is gone; compile again' };
  }
  if (res.status !== 200) {
    let detail = '';
    try {
      detail = ': ' + (JSON.parse(res.body).error || '');
    } catch (e) {
      /* the error page is HTML, which says nothing useful */
    }
    throw { code: 'SYNCTEX_FAILED', message: `SyncTeX lookup failed with status ${res.status}${detail}` };
  }
  return JSON.parse(res.body);
}

const handlers = {
  async ping(params) {
    return { status: 'ok' };
  },

  async listChromeProfiles(params) {
    const profiles = listProfiles();
    return { profiles };
  },

  async getCookie(params) {
    const cookie = await getOverleafCookie(params.profile);
    return { cookie };
  },

  async auth(params) {
    const { cookie, cookieSource } = params;
    if (!cookie) throw { code: 'MISSING_PARAM', message: 'cookie is required' };
    return await auth.fetchProjectPage(cookie, { cookieSource });
  },

  async connect(params) {
    let { cookie, projectId } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }

    // Fetch GCLB cookie for load balancer stickiness (skip for local/test servers)
    if (!process.env.OVERLEAF_URL) {
      cookie = await auth.updateCookies(cookie);
      console.log('Updated cookies for socket connection');
    }

    if (socketManager) {
      socketManager.disconnect();
    }

    socketManager = new SocketManager(cookie, projectId, sendEvent);
    return await socketManager.connect();
  },

  async joinDoc(params) {
    const { docId, fromVersion } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId) throw { code: 'MISSING_PARAM', message: 'docId is required' };
    return await socketManager.joinDoc(docId, fromVersion);
  },

  async leaveDoc(params) {
    const { docId } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId) throw { code: 'MISSING_PARAM', message: 'docId is required' };
    return await socketManager.leaveDoc(docId);
  },

  async applyOtUpdate(params) {
    const { docId, op, v, content, tracked, dupIfSource } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId || op === undefined || v === undefined) {
      throw { code: 'MISSING_PARAM', message: 'docId, op, and v are required' };
    }
    return await socketManager.applyOtUpdate(docId, op, v, content, tracked === true, dupIfSource);
  },

  async compile(params) {
    const { cookie, csrfToken, projectId } = params;
    if (!cookie || !csrfToken || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, and projectId are required' };
    }

    const compileRes = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/compile?auto_compile=true&editorId=${EDITOR_ID}`,
      cookie, csrfToken,
      { check: 'silent', draft: false, incrementalCompilesEnabled: true, stopOnFirstError: false }
    );

    if (compileRes.status !== 200) {
      throw { code: 'COMPILE_ERROR', message: `Compile request failed with status ${compileRes.status}` };
    }

    const parsed = JSON.parse(compileRes.body);

    // Download log if available
    // Build output is served only by the CLSI node that produced it; without
    // clsiserverid the request lands on another node and 404s.
    const clsiQuery = parsed.clsiServerId ? `?clsiserverid=${encodeURIComponent(parsed.clsiServerId)}` : '';

    const logFile = (parsed.outputFiles || []).find(f => f.path === 'output.log');
    let log = '';
    if (logFile) {
      const logUrl = `${BASE_URL}${logFile.url}${clsiQuery}`;
      const logRes = await auth.httpGet(logUrl, cookie);
      if (logRes.status === 200) log = logRes.body;
      else console.log(`Failed to fetch compile log: status ${logRes.status}`);
    }

    // SyncTeX addresses a build, not a project. The id is only exposed inside
    // the output URLs: /project/:id/user/:uid/build/<buildId>/output/output.pdf
    const pdfFile = (parsed.outputFiles || []).find(f => f.path === 'output.pdf');
    const buildMatch = pdfFile && pdfFile.url && pdfFile.url.match(/\/build\/([^/]+)\//);

    return {
      status: parsed.status,
      outputFiles: parsed.outputFiles || [],
      log,
      clsiServerId: parsed.clsiServerId || null,
      compileGroup: parsed.compileGroup || null,
      pdfDownloadDomain: parsed.pdfDownloadDomain || null,
      buildId: buildMatch ? buildMatch[1] : null,
      editorId: EDITOR_ID,
    };
  },

  // Forward search: a place in the source -> where it landed in the PDF.
  async syncCode(params) {
    const { cookie, projectId, file, line, column, buildId, clsiServerId } = params;
    if (!cookie || !projectId || !file || !buildId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, projectId, file and buildId are required' };
    }
    const query = new URLSearchParams({
      file,
      line: String(line),
      column: String(column == null ? 0 : column),
      buildId,
      editorId: EDITOR_ID,
    });
    if (clsiServerId) query.set('clsiserverid', clsiServerId);
    return await syncTexRequest(cookie, `${BASE_URL}/project/${projectId}/sync/code?${query}`);
  },

  // Inverse search: a point on a PDF page -> the source that produced it.
  async syncPdf(params) {
    const { cookie, projectId, page, h, v, buildId, clsiServerId } = params;
    if (!cookie || !projectId || page == null || h == null || v == null || !buildId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, projectId, page, h, v and buildId are required' };
    }
    const query = new URLSearchParams({
      page: String(page),
      h: Number(h).toFixed(2),
      v: Number(v).toFixed(2),
      buildId,
      editorId: EDITOR_ID,
    });
    if (clsiServerId) query.set('clsiserverid', clsiServerId);
    return await syncTexRequest(cookie, `${BASE_URL}/project/${projectId}/sync/pdf?${query}`);
  },

  async downloadUrl(params) {
    const { cookie, url, fileName, outputDir, synctexRoot } = params;
    if (!cookie || !url) {
      throw { code: 'MISSING_PARAM', message: 'cookie and url are required' };
    }
    const fs = require('fs');
    const path = require('path');
    const destPath = downloadPath(downloadDir(outputDir), fileName === undefined ? 'download' : fileName);
    if (synctexRoot === undefined || synctexRoot === null) {
      await fetchToFile(url, cookie, destPath);
      return { path: destPath };
    }
    if (typeof synctexRoot !== 'string' || !path.isAbsolute(synctexRoot)) {
      throw { code: 'INVALID_PARAM', message: 'synctexRoot must be an absolute path' };
    }
    const staging = destPath + '.' + process.pid + '.synctex-download';
    const rewritten = destPath + '.' + process.pid + '.synctex-rewrite';
    try {
      await fetchToFile(url, cookie, staging);
      fs.writeFileSync(rewritten, require('./synctex').rewrite(fs.readFileSync(staging), synctexRoot), { mode: 0o600 });
      fs.renameSync(rewritten, destPath);
    } finally {
      fs.rmSync(staging, { force: true });
      fs.rmSync(rewritten, { force: true });
    }
    return { path: destPath };
  },

  async downloadFile(params) {
    const { cookie, projectId, fileId, fileName, outputDir } = params;
    if (!cookie || !projectId || !fileId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, projectId, and fileId are required' };
    }
    const dir = downloadDir(outputDir);
    const tmpPath = downloadPath(dir, fileName === undefined ? fileId : fileName);
    await fetchToFile(`${BASE_URL}/project/${projectId}/file/${fileId}`, cookie, tmpPath);
    return { path: tmpPath };
  },

  async createDoc(params) {
    const { cookie, csrfToken, projectId, name, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !name) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and name are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/doc`,
      cookie, csrfToken,
      { name, parent_folder_id: parentFolderId || null }
    );
    if (res.status !== 200) {
      throw { code: 'CREATE_FAILED', message: `Create doc failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async createFolder(params) {
    const { cookie, csrfToken, projectId, name, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !name) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and name are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/folder`,
      cookie, csrfToken,
      { name, parent_folder_id: parentFolderId || null }
    );
    if (res.status !== 200) {
      throw { code: 'CREATE_FAILED', message: `Create folder failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async renameEntity(params) {
    const { cookie, csrfToken, projectId, entityId, entityType, newName } = params;
    if (!cookie || !csrfToken || !projectId || !entityId || !entityType || !newName) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, entityId, entityType, and newName are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/${entityType}/${entityId}/rename`,
      cookie, csrfToken,
      { name: newName }
    );
    if (res.status !== 204 && res.status !== 200) {
      throw { code: 'RENAME_FAILED', message: `Rename failed: ${res.status} ${res.body}` };
    }
    return {};
  },

  async deleteEntity(params) {
    const { cookie, csrfToken, projectId, entityId, entityType } = params;
    if (!cookie || !csrfToken || !projectId || !entityId || !entityType) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, entityId, and entityType are required' };
    }
    const res = await auth.httpDelete(
      `${BASE_URL}/project/${projectId}/${entityType}/${entityId}`,
      cookie, csrfToken
    );
    if (res.status !== 204 && res.status !== 200) {
      throw { code: 'DELETE_FAILED', message: `Delete failed: ${res.status}` };
    }
    return {};
  },

  async uploadFile(params) {
    const { cookie, csrfToken, projectId, filePath, fileName, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !filePath) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and filePath are required' };
    }
    const fs = require('fs');
    if (!fs.existsSync(filePath)) {
      throw { code: 'FILE_NOT_FOUND', message: `File not found: ${filePath}` };
    }
    const folderId = parentFolderId || 'rootFolder';
    const url = `${BASE_URL}/project/${projectId}/upload?folder_id=${folderId}`;
    const res = await auth.httpPostMultipart(url, cookie, csrfToken, filePath, fileName);
    if (res.status !== 200) {
      throw { code: 'UPLOAD_FAILED', message: `Upload failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async getHistory(params) {
    const { cookie, projectId, minCount } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }
    const res = await auth.httpGet(
      `${BASE_URL}/project/${projectId}/updates?min_count=${minCount || 15}`,
      cookie
    );
    if (res.status !== 200) {
      throw { code: 'HISTORY_FAILED', message: `History request failed: ${res.status}` };
    }
    return JSON.parse(res.body);
  },

  async getThreads(params) {
    const { cookie, projectId } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }
    const res = await auth.httpGet(
      `${BASE_URL}/project/${projectId}/threads`,
      cookie
    );
    if (res.status !== 200) {
      throw { code: 'THREADS_FAILED', message: `Get threads failed: ${res.status}` };
    }
    return JSON.parse(res.body);
  },

  async addComment(params) {
    const { cookie, csrfToken, projectId, threadId, content } = params;
    if (!cookie || !csrfToken || !projectId || !threadId || !content) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, threadId, and content are required' };
    }
    const res = await auth.httpPost(
      `${BASE_URL}/project/${projectId}/thread/${threadId}/messages`,
      cookie, csrfToken,
      { content }
    );
    if (res.status !== 200 && res.status !== 201 && res.status !== 204) {
      throw { code: 'COMMENT_FAILED', message: `Add comment failed: ${res.status}` };
    }
    try { return JSON.parse(res.body); } catch (e) { return {}; }
  },

  async resolveThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `${BASE_URL}/project/${projectId}/doc/${docId}/thread/${threadId}/resolve`
      : `${BASE_URL}/project/${projectId}/thread/${threadId}/resolve`;
    const res = await auth.httpPost(url, cookie, csrfToken, {});
    if (res.status < 200 || res.status >= 300) {
      throw { code: 'RESOLVE_FAILED', message: `Resolve thread failed: ${res.status}` };
    }
    return {};
  },

  async reopenThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `${BASE_URL}/project/${projectId}/doc/${docId}/thread/${threadId}/reopen`
      : `${BASE_URL}/project/${projectId}/thread/${threadId}/reopen`;
    const res = await auth.httpPost(url, cookie, csrfToken, {});
    if (res.status < 200 || res.status >= 300) {
      throw { code: 'REOPEN_FAILED', message: `Reopen thread failed: ${res.status}` };
    }
    return {};
  },

  async deleteThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `${BASE_URL}/project/${projectId}/doc/${docId}/thread/${threadId}`
      : `${BASE_URL}/project/${projectId}/thread/${threadId}`;
    const res = await auth.httpDelete(url, cookie, csrfToken);
    if (res.status !== 200 && res.status !== 204) {
      throw { code: 'DELETE_FAILED', message: `Delete thread failed: ${res.status}` };
    }
    return {};
  },

  async disconnect() {
    if (socketManager) {
      socketManager.disconnect();
      socketManager = null;
    }
    return {};
  },
};

function maybeExit() {
  if (stdinClosed && pendingRequests === 0 && !socketManager) {
    process.exit(0);
  }
}

async function handleMessage(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    console.log('Failed to parse message:', line);
    return;
  }

  const { id, method, params } = msg;
  if (!method || id === undefined) {
    console.log('Invalid message format:', line);
    return;
  }

  const handler = handlers[method];
  if (!handler) {
    sendError(id, 'UNKNOWN_METHOD', `Unknown method: ${method}`);
    return;
  }

  pendingRequests++;
  try {
    const result = await handler(params || {});
    sendResult(id, result);
  } catch (err) {
    const code = err.code || 'INTERNAL_ERROR';
    const message = err.message || String(err);
    sendError(id, code, message);
  } finally {
    pendingRequests--;
    maybeExit();
  }
}

if (require.main === module) {
  // stdin line reader
  const rl = readline.createInterface({
    input: process.stdin,
    terminal: false,
  });

  rl.on('line', (line) => {
    if (line.trim()) {
      handleMessage(line.trim());
    }
  });

  rl.on('close', () => {
    console.log('stdin closed');
    stdinClosed = true;
    if (socketManager) {
      socketManager.disconnect();
      socketManager = null;
    }
    maybeExit();
    // Force exit after 5s if pending requests don't complete
    setTimeout(() => process.exit(0), 5000).unref();
  });

  process.on('SIGTERM', () => {
    console.log('SIGTERM received');
    if (socketManager) {
      socketManager.disconnect();
    }
    process.exit(0);
  });

  process.on('uncaughtException', (err) => {
    console.log('Uncaught exception:', err.message);
    sendEvent('error', { message: err.message });
  });

  console.log('Bridge started');
}

module.exports = { _internal: { redirectPolicy, downloadPath, fetchToFile } };
