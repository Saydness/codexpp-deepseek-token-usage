/*
 * Where the account balance can come from.
 *
 * Codex Desktop's renderer is forbidden from reaching the network, so the
 * panel cannot ask DeepSeek anything itself. The helper that starts with Codex
 * does the real request and hands the page a number. This module is that
 * lookup, kept separate so it can be tested without a live page.
 *
 * Sources, in the order "auto" tries them:
 *   proxy - a local proxy endpoint you point at with DSTU_BALANCE_URL; it
 *           reuses the auth header of live traffic, so it needs no key of its own;
 *   env   - DEEPSEEK_API_KEY, or whatever env_key Codex config.toml points at;
 *   auth  - the key Codex itself stores in ~/.codex/auth.json;
 *   store - a key the user typed into the panel once; it is encrypted with
 *           Windows DPAPI (current user) on this machine.
 *
 * A key is never written to a log, never sent to the page, and never stored in
 * the page's localStorage. Only the number and the source name travel back.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const KEY_SOURCES = ['env', 'auth', 'store'];

const DEFAULT_DIRECT_URL = 'https://api.deepseek.com/user/balance';
const DEFAULT_REQUEST_TIMEOUT_MS = 8000;
const POWERSHELL_TIMEOUT_MS = 20000;

export function defaultStorePath() {
  const base =
    process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  return path.join(base, 'Codex++', 'deepseek-balance.key');
}

export function defaultCodexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
}

export function defaultKeyScript() {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), 'set_balance_key.ps1');
}

/* 只记录来源和结果，任何时候都不打印密钥本身。 */
function noop() {}

let powershellCache = null;

export function powershellCommand() {
  if (powershellCache) return powershellCache;
  const override = process.env.DSTU_POWERSHELL;
  if (override) {
    powershellCache = override;
    return powershellCache;
  }
  for (const candidate of ['pwsh', 'powershell.exe']) {
    try {
      execFileSync(candidate, ['-NoProfile', '-NonInteractive', '-Command', 'exit 0'], {
        stdio: 'ignore',
        timeout: POWERSHELL_TIMEOUT_MS,
        windowsHide: true,
      });
      powershellCache = candidate;
      return powershellCache;
    } catch (_) {
      /* try the next one */
    }
  }
  powershellCache = 'powershell.exe';
  return powershellCache;
}

export function pickBalance(payload) {
  const infos = Array.isArray(payload?.balance_infos)
    ? payload.balance_infos
    : [];
  if (!infos.length) return null;
  const cny =
    infos.find(
      (item) => String(item?.currency || '').toUpperCase() === 'CNY'
    ) || infos[0];
  const value = Number(cny?.total_balance ?? cny?.balance);
  if (!Number.isFinite(value)) return null;
  return { value, currency: String(cny?.currency || 'CNY').toUpperCase() };
}

function timeoutMs(options) {
  const value = Number(options?.timeoutMs);
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_REQUEST_TIMEOUT_MS;
}

/* 1) 本机代理（地址来自 DSTU_BALANCE_URL）：它自己会用真实流量里的鉴权信息去查余额。 */
export async function readProxyBalance(options = {}) {
  const url = options.proxyUrl || process.env.DSTU_BALANCE_URL || '';
  if (!url) return { error: '没有配置本机代理地址（环境变量 DSTU_BALANCE_URL）' };
  const endpoint = options.force ? `${url}?force=1` : url;
  try {
    const response = await fetch(endpoint, {
      cache: 'no-store',
      signal: AbortSignal.timeout(timeoutMs(options)),
    });
    if (!response.ok) {
      return { error: `本机代理返回 HTTP ${response.status}` };
    }
    const body = await response.json();
    if (body && body.ok === false) {
      return { error: String(body.error || '代理未能读取余额') };
    }
    const balance = pickBalance(body?.payload ?? body);
    if (!balance) return { error: '代理返回的余额里没有可用金额' };
    return balance;
  } catch (_) {
    return { error: '本机代理不可达' };
  }
}

export async function readProxyHealth(proxyUrl) {
  const url = proxyUrl || process.env.DSTU_BALANCE_URL || '';
  if (!url) return null;
  const base = url.endsWith('/') ? url : `${url}/`;
  try {
    const response = await fetch(`${base}health`, {
      cache: 'no-store',
      signal: AbortSignal.timeout(DEFAULT_REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) return null;
    const body = await response.json();
    return {
      hasAuth: typeof body?.has_auth === 'boolean' ? body.has_auth : null,
    };
  } catch (_) {
    return null;
  }
}

/* env_key 让 Codex 用别的环境变量名放密钥；这里把它们都认下来。 */
export function readConfigEnvKeyNames(configPath) {
  try {
    const text = fs.readFileSync(configPath, 'utf8');
    const names = [];
    const pattern = /env_key\s*=\s*["']([^"']+)["']/g;
    let match = pattern.exec(text);
    while (match) {
      const name = String(match[1] || '').trim();
      if (name && !names.includes(name)) names.push(name);
      match = pattern.exec(text);
    }
    return names;
  } catch (_) {
    return [];
  }
}

function usableKey(value) {
  const key = typeof value === 'string' ? value.trim() : '';
  return key.length >= 8 ? key : '';
}

export function readEnvKey(options = {}) {
  const env = options.env || process.env;
  const direct = usableKey(env.DEEPSEEK_API_KEY);
  if (direct) return direct;
  const configPath =
    options.configPath ||
    path.join(options.codexHome || defaultCodexHome(), 'config.toml');
  for (const name of readConfigEnvKeyNames(configPath)) {
    const key = usableKey(env[name]);
    if (key) return key;
  }
  return '';
}

export function readAuthKey(options = {}) {
  const file =
    options.authPath ||
    path.join(options.codexHome || defaultCodexHome(), 'auth.json');
  let data = null;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return '';
  }
  const named = usableKey(data?.OPENAI_API_KEY);
  if (named) return named;
  /* 字段名以后可能改；再扫一层，只认长得像密钥的字符串。 */
  for (const value of Object.values(data || {})) {
    if (typeof value !== 'string') continue;
    const text = value.trim();
    if (/^sk-[A-Za-z0-9_-]{16,}$/.test(text)) return text;
  }
  return '';
}

export function readStoredKey(options = {}) {
  const storePath = options.storePath || defaultStorePath();
  if (!fs.existsSync(storePath)) return '';
  const script = options.keyScript || defaultKeyScript();
  try {
    const output = execFileSync(
      powershellCommand(),
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        '-Print',
      ],
      {
        encoding: 'utf8',
        timeout: POWERSHELL_TIMEOUT_MS,
        windowsHide: true,
        env: { ...process.env, DSTU_KEY_STORE: storePath },
      }
    );
    return usableKey(output);
  } catch (_) {
    return '';
  }
}

/*
 * 保存用户填的 Key：走 stdin，不进命令行参数，所以进程列表里看不到它；
 * 落盘的是 DPAPI 加密串，文件里没有明文。
 */
export function saveStoredKey(key, options = {}) {
  const value = usableKey(key);
  if (!value) return { ok: false, error: 'Key 看起来不完整' };
  const storePath = options.storePath || defaultStorePath();
  const script = options.keyScript || defaultKeyScript();
  try {
    execFileSync(
      powershellCommand(),
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
      ],
      {
        input: value,
        encoding: 'utf8',
        timeout: POWERSHELL_TIMEOUT_MS,
        windowsHide: true,
        env: { ...process.env, DSTU_KEY_STORE: storePath },
      }
    );
    return { ok: true, storePath };
  } catch (error) {
    noop(error);
    return { ok: false, error: '本机加密保存失败（Windows DPAPI 不可用？）' };
  }
}

export function clearStoredKey(options = {}) {
  const storePath = options.storePath || defaultStorePath();
  const script = options.keyScript || defaultKeyScript();
  try {
    execFileSync(
      powershellCommand(),
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
        '-Clear',
      ],
      {
        encoding: 'utf8',
        timeout: POWERSHELL_TIMEOUT_MS,
        windowsHide: true,
        env: { ...process.env, DSTU_KEY_STORE: storePath },
      }
    );
    return { ok: true };
  } catch (_) {
    return { ok: false, error: '删除本机保存的 Key 失败' };
  }
}

export function storedKeyPresent(options = {}) {
  return fs.existsSync(options.storePath || defaultStorePath());
}

export async function fetchBalanceWithKey(key, options = {}) {
  const url = options.directUrl || DEFAULT_DIRECT_URL;
  try {
    const response = await fetch(url, {
      headers: {
        accept: 'application/json',
        authorization: `Bearer ${key}`,
      },
      cache: 'no-store',
      signal: AbortSignal.timeout(timeoutMs(options)),
    });
    if (!response.ok) {
      return {
        error:
          response.status === 401 || response.status === 403
            ? `DeepSeek 拒绝了这个 Key（HTTP ${response.status}）`
            : `DeepSeek 接口返回 HTTP ${response.status}`,
      };
    }
    const body = await response.json();
    const balance = pickBalance(body?.data ?? body);
    if (!balance) return { error: '余额响应里没有可用金额' };
    return balance;
  } catch (error) {
    noop(error);
    return { error: '连不上 DeepSeek 接口（检查网络或代理）' };
  }
}

export function keyForSource(source, options = {}) {
  if (source === 'env') return readEnvKey(options);
  if (source === 'auth') return readAuthKey(options);
  if (source === 'store') return readStoredKey(options);
  return '';
}

/* 面板上「余额来源」只给三档：自动 / 只问本机代理 / 只用我填的 Key。 */
export function normalizePreference(value) {
  if (value === 'proxy') return 'proxy';
  if (value === 'key') return 'key';
  return 'auto';
}

export async function resolveBalance(options = {}) {
  const preference = normalizePreference(options.preference);
  const tried = [];
  if (preference !== 'key') {
    const proxied = await readProxyBalance(options);
    if (Number.isFinite(proxied?.value)) {
      return { ...proxied, source: 'proxy', tried };
    }
    tried.push({ source: 'proxy', error: proxied.error || '不可用' });
  }
  if (preference !== 'proxy') {
    for (const source of KEY_SOURCES) {
      const key = keyForSource(source, options);
      if (!key) {
        tried.push({ source, error: '没有这个来源的 Key' });
        continue;
      }
      const result = await fetchBalanceWithKey(key, options);
      if (Number.isFinite(result?.value)) {
        return { ...result, source, tried };
      }
      tried.push({ source, error: result.error || '不可用' });
    }
  }
  return { error: describeFailure(tried, preference), tried };
}

function describeFailure(tried, preference) {
  const hasKeyError = tried.some(
    (item) => item.source !== 'proxy' && item.error && item.error !== '没有这个来源的 Key'
  );
  if (hasKeyError) {
    const keyFailure = tried.find(
      (item) => item.source !== 'proxy' && item.error !== '没有这个来源的 Key'
    );
    return keyFailure?.error || '余额读取失败';
  }
  const anyKey = tried.some(
    (item) => item.source !== 'proxy' && item.error === '没有这个来源的 Key'
  );
  if (anyKey && preference !== 'proxy') {
    return '没有找到可用的 Key：可在「说明」里填一次，或用 Codex 自带的那把';
  }
  if (preference === 'proxy') return '本机代理暂时读不到余额';
  return '余额暂时读不到，可点「刷新余额」重试';
}
