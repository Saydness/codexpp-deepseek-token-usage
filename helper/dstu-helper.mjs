/*
 * Codex++ panel balance feeder.
 *
 * Started by start-helper.vbs, which keeps it alive only while Codex Desktop
 * is running. Two jobs:
 *   1. keeps the DeepSeek account balance fresh in the panel: every poll it
 *      heartbeats, every DSTU_BALANCE_INTERVAL_MS it pushes a fresh balance,
 *      and it reacts within one poll when the panel asks for a refresh;
 *   2. optionally imports an external usage log (set DSTU_USAGE_LOG) into the
 *      panel, so records the page itself missed can be filled back in.
 * The balance has to come from outside the page: Codex Desktop's renderer CSP
 * has no connect-src entry for deepseek, so the panel itself cannot call the
 * balance endpoint (or anything else). This script does the real GET and only
 * hands numbers to the panel. Balance sources, in order:
 *   1. a local proxy endpoint (only when DSTU_BALANCE_URL is set; it needs no
 *      key of its own because it reuses the auth header of live traffic),
 *   2. DEEPSEEK_API_KEY in the environment (or the env_key Codex config uses),
 *   3. ~/.codex/auth.json (the file Codex stores an API key in),
 *   4. a DPAPI-encrypted key saved by set_balance_key.ps1.
 * Whichever is found first wins; the key itself never reaches the page or the log.
 *
 * usage: node helper/dstu-helper.mjs [usage.jsonl]
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  clearStoredKey,
  readAuthKey,
  readEnvKey,
  readProxyHealth,
  resolveBalance,
  saveStoredKey,
  storedKeyPresent,
} from './balance_sources.mjs';

/* 用量日志是可选的：只有想把页面之外的调用也补进来时才需要提供。 */
const jsonlPath = process.env.DSTU_USAGE_LOG || process.argv[2] || '';
const cdpBase = process.env.DSTU_CDP || 'http://127.0.0.1:9229';
/* 本机代理是可选的：设了 DSTU_BALANCE_URL 才去问它，否则直接用 Key 直连。 */
const balanceUrl = process.env.DSTU_BALANCE_URL || '';
const directBalanceUrl =
  process.env.DSTU_DIRECT_BALANCE_URL ||
  'https://api.deepseek.com/user/balance';
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
const keyStorePath =
  process.env.DSTU_KEY_STORE ||
  (process.platform === 'darwin'
    ? path.join(
        os.homedir(),
        'Library',
        'Application Support',
        'Codex++',
        'deepseek-balance.key'
      )
    : path.join(
        process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'),
        'Codex++',
        'deepseek-balance.key'
      ));
const balanceIntervalMs =
  Number(process.env.DSTU_BALANCE_INTERVAL_MS || 5 * 60 * 1000);
const pollMs = Number(process.env.DSTU_POLL_MS || 15000);
const importIntervalMs = Number(
  process.env.DSTU_IMPORT_INTERVAL_MS || 5 * 60 * 1000
);
const importWindowMs = Number(
  process.env.DSTU_IMPORT_WINDOW_MS || 12 * 60 * 60 * 1000
);
/* 启动时补最近几天的整段记录：助手停过或面板漏抓时，缺口能被补回来。 */
const bootstrapWindowMs = Number(
  process.env.DSTU_BOOTSTRAP_WINDOW_MS || 48 * 60 * 60 * 1000
);
/* 增量补录时往前留一段重叠，避免边界上的记录被跳过。 */
const importOverlapMs = Number(
  process.env.DSTU_IMPORT_OVERLAP_MS || 30 * 60 * 1000
);
const WAIT_AUTH_NOTE =
  '余额来源还没就绪：在 Codex 里发一条消息，或在面板「说明」里填一次 API Key';
const PAGE_GRACE = Math.max(4, Math.round(300000 / pollMs));
/* 默认只往控制台打印；设了 DSTU_LOG 才落盘。日志里没有密钥，也没有请求正文。 */
const logPath = process.env.DSTU_LOG || '';
const LOG_MAX_BYTES = 200 * 1024;

/* 只写运行情况（时间、条数、错误），不写密钥、不写请求正文。 */
function logLine(message) {
  console.log(message);
  if (!logPath) return;
  try {
    if (fs.existsSync(logPath) && fs.statSync(logPath).size > LOG_MAX_BYTES) {
      fs.writeFileSync(logPath, '');
    }
    fs.appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`);
  } catch (_) {
    /* 日志写不进去不影响主流程。 */
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function recordTime(record) {
  return (
    Date.parse(record?.created_utc || '') ||
    Date.parse(String(record?.created_at || '') + '+08:00') ||
    0
  );
}

function readRecords() {
  if (!jsonlPath || !fs.existsSync(jsonlPath)) return [];
  const records = [];
  for (const line of fs.readFileSync(jsonlPath, 'utf8').split(/\r?\n/)) {
    const text = line.trim();
    if (!text) continue;
    try {
      const record = JSON.parse(text);
      if (record && typeof record === 'object') records.push(record);
    } catch (_) {
      // Ignore an incomplete final line.
    }
  }
  return records;
}

async function findTarget() {
  try {
    const response = await fetch(`${cdpBase}/json/list`);
    const targets = await response.json();
    return (
      targets.find(
        (target) =>
          target.type === 'page' &&
          !target.url.includes('avatar-overlay') &&
          target.url.startsWith('app://-/index.html')
      ) || null
    );
  } catch (_) {
    return null;
  }
}

async function evaluateInPage(expression) {
  const target = await findTarget();
  if (!target?.webSocketDebuggerUrl) return undefined;
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  try {
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, { once: true });
      socket.addEventListener('error', reject, { once: true });
    });
    const result = await new Promise((resolve) => {
      socket.addEventListener('message', (event) => {
        const message = JSON.parse(event.data);
        if (message.id !== 1) return;
        resolve(message);
      });
      socket.send(
        JSON.stringify({
          id: 1,
          method: 'Runtime.evaluate',
          params: {
            expression,
            awaitPromise: true,
            returnByValue: true,
          },
        })
      );
    });
    return result.result?.result?.value;
  } catch (_) {
    return undefined;
  } finally {
    socket.close();
  }
}

/*
 * 面板上的「余额来源」：auto = 先问本机代理，不行再用 Key 直连；
 * proxy = 只用本机代理；key = 只用 Key（环境变量 / auth.json / 本机存的）。
 */
function balanceSourceChoice(sync) {
  const value = String(sync?.source || 'auto');
  return value === 'proxy' || value === 'key' ? value : 'auto';
}

async function readBalance(preference, force) {
  return await resolveBalance({
    preference,
    force,
    proxyUrl: balanceUrl,
    directUrl: directBalanceUrl,
    storePath: keyStorePath,
    codexHome,
  });
}

/* 代理的鉴权信息来自真实流量；还没有流量时先告诉面板在等什么。 */
async function readHealth() {
  return await readProxyHealth(balanceUrl);
}

/* 有没有可用来源，只看够不够，不打印任何密钥。 */
function anyKeyPresent() {
  try {
    if (readEnvKey({ codexHome })) return true;
  } catch (_) {
    /* ignore */
  }
  try {
    if (readAuthKey({ codexHome })) return true;
  } catch (_) {
    /* ignore */
  }
  return storedKeyPresent({ storePath: keyStorePath });
}

let lastKeySaveHandled = 0;
let lastKeyClearHandled = 0;

/*
 * 面板把用户填的 Key 放在内存里，等这里取走：取走后用 DPAPI 加密存本机，
 * 然后回一个 keySaved，面板立刻把内存里那份丢掉。密钥不进日志、不进磁盘明文。
 */
async function handleKeyRequests(sync) {
  const result = { keySaved: false, keyCleared: false, note: '' };

  const clearAt = Number(sync?.keyClearAt) || 0;
  if (clearAt > lastKeyClearHandled) {
    const cleared = clearStoredKey({ storePath: keyStorePath });
    lastKeyClearHandled = clearAt;
    result.keyCleared = cleared.ok;
    if (cleared.ok) {
      logLine('balance key: removed from the local store');
    } else {
      result.note = cleared.error || '删除本机 Key 失败';
      logLine(`balance key: clear failed (${result.note})`);
    }
  }

  const requestAt = Number(sync?.keyRequestAt) || 0;
  const pending = typeof sync?.pendingKey === 'string' ? sync.pendingKey.trim() : '';
  if (requestAt > lastKeySaveHandled && pending) {
    const saved = saveStoredKey(pending, { storePath: keyStorePath });
    lastKeySaveHandled = requestAt;
    result.keySaved = saved.ok;
    if (saved.ok) {
      logLine('balance key: saved encrypted for this Windows user');
    } else {
      result.note = saved.error || '本机加密保存失败';
      logLine(`balance key: save failed (${result.note})`);
    }
  }

  return result;
}

/*
 * 把用量日志里最近的记录合并进面板。面板自己也会抓用量，但抓到的可能比日志
 * 少（去重、非流式响应等），所以这里既在启动时补一次，之后也定期再补，让数字
 * 始终收敛到日志。面板按 request_id 去重，重复导入不会重复计费。
 */
let importWatermark = 0;

async function importUsage({ waitMs = 2000, bootstrap = false } = {}) {
  const nowMs = Date.now();
  const windowMs = bootstrap ? bootstrapWindowMs : importWindowMs;
  const since = bootstrap
    ? nowMs - windowMs
    : Math.max(nowMs - windowMs, importWatermark - importOverlapMs);
  const records = readRecords().filter((record) => recordTime(record) >= since);
  if (!records.length) return 0;
  const deadline = Date.now() + waitMs;
  while (Date.now() <= deadline) {
    const imported = await evaluateInPage(
      `window.__deepseekUsagePanel?.mergeProxyRecords?.(${JSON.stringify(records)})`
    );
    if (imported !== undefined) {
      for (const record of records) {
        const at = recordTime(record);
        if (at > importWatermark) importWatermark = at;
      }
      logLine(`usage import: ${imported ?? 0} new record(s)`);
      return imported ?? 0;
    }
    await sleep(2000);
  }
  return null;
}

async function readPanelSync() {
  const value = await evaluateInPage(
    `window.__deepseekUsagePanel?.getBalanceSync?.() ?? null`
  );
  return value && typeof value === 'object' ? value : null;
}

async function ack(info) {
  return await evaluateInPage(
    `window.__deepseekUsagePanel?.ackBalanceSync?.(${JSON.stringify(
      info
    )}) ?? null`
  );
}

async function pushBalance(force, preference) {
  const balance = await readBalance(preference, force);
  if (!Number.isFinite(balance?.value)) {
    logLine(`balance: ${balance?.error || 'unavailable'}`);
    return {
      ok: false,
      error: balance?.error || '余额暂时读不到',
      tried: Array.isArray(balance?.tried) ? balance.tried : [],
    };
  }
  const result = await evaluateInPage(
    `(() => { const panel = window.__deepseekUsagePanel;` +
      ` if (!panel) return 'no-panel';` +
      ` const saved = panel.recordBalance(${balance.value}, 'api',` +
      ` { currency: ${JSON.stringify(balance.currency)},` +
      ` origin: ${JSON.stringify(balance.source || '')} });` +
      ` return saved ? 'ok' : 'skip'; })()`
  );
  if (result !== 'ok') {
    return {
      ok: false,
      error: result === 'no-panel' ? '面板未就绪' : '面板未接受余额',
    };
  }
  logLine(
    `balance push: ${balance.currency} ${balance.value} via ${balance.source}` +
      ` @ ${new Date().toISOString()}`
  );
  return {
    ok: true,
    value: balance.value,
    currency: balance.currency,
    source: balance.source,
  };
}

let missingPageChecks = 0;
let lastPushAt = 0;
let lastImportAt = Date.now();
/* 记住上一次成功用的是哪条路：心跳也要带上，面板刷新/注入后不用等下一次推送。 */
let lastSourceUsed = '';

if (!jsonlPath) {
  logLine('usage import: no usage log configured (set DSTU_USAGE_LOG to import one)');
} else {
  const firstImport = await importUsage({ waitMs: 300000, bootstrap: true });
  if (firstImport === null) logLine('usage import: panel never became reachable');
}

for (;;) {
  const sync = await readPanelSync();
  if (!sync) {
    missingPageChecks += 1;
    if (missingPageChecks >= PAGE_GRACE) {
        logLine('panel gone, balance feeder exiting');
      process.exit(0);
    }
    await sleep(pollMs);
    continue;
  }
  missingPageChecks = 0;

  /* 定期把用量日志里的新记录补进面板，数字不会因为抓漏而偏小。 */
  if (jsonlPath && Date.now() - lastImportAt >= importIntervalMs) {
    lastImportAt = Date.now();
    await importUsage({ waitMs: 0 });
  }

  /* 面板点过「保存 Key / 清除 Key」就先办掉，之后再读余额。 */
  const keyResult = await handleKeyRequests(sync);
  if (keyResult.keySaved || keyResult.keyCleared) lastPushAt = 0;

  /* 面板点过「刷新余额」就立刻重读，否则每 balanceIntervalMs 推一次。 */
  const requested = Number(sync.requestAt) > Number(sync.handledAt);
  const due = Date.now() - lastPushAt >= balanceIntervalMs;
  const health = await readHealth();
  const canRead = sync.enabled !== false;
  const source = balanceSourceChoice(sync);

  if (!canRead) {
    await ack({
      hasAuth: health ? health.hasAuth : null,
      hasKey: anyKeyPresent(),
      sourceUsed: lastSourceUsed,
      note: '',
    });
  } else if (requested || due || keyResult.keySaved || keyResult.keyCleared) {
    const result = await pushBalance(requested || keyResult.keySaved, source);
    let note = keyResult.note || (result.ok ? '' : result.error || '');
    /*
     * 代理还没见过任何请求时，"去 Codex 里发一条消息" 比任何报错都直接。
     * 但如果直连那把 Key 本身出了问题（被拒、网络不通），就照实说。
     */
    const keyTrouble = (result.tried || []).some(
      (item) =>
        item.source !== 'proxy' &&
        item.error &&
        item.error !== '没有这个来源的 Key'
    );
    if (
      !result.ok &&
      !keyTrouble &&
      !keyResult.note &&
      source !== 'key' &&
      health?.hasAuth === false
    ) {
      note = WAIT_AUTH_NOTE;
    }
    if (result.ok) {
      lastPushAt = Date.now();
      lastSourceUsed = result.source || '';
    }
    await ack({
      pushed: Boolean(result.ok),
      sourceUsed: lastSourceUsed,
      hasAuth: health ? health.hasAuth : null,
      hasKey: anyKeyPresent(),
      keySaved: keyResult.keySaved,
      keyCleared: keyResult.keyCleared,
      handledRequestAt: Number(sync.requestAt) || 0,
      note,
    });
  } else {
    const at = await ack({
      hasAuth: health ? health.hasAuth : null,
      hasKey: anyKeyPresent(),
      sourceUsed: lastSourceUsed,
      keySaved: keyResult.keySaved,
      keyCleared: keyResult.keyCleared,
    });
    if (!at) logLine('panel stopped answering, will retry');
  }

  await sleep(pollMs);
}
