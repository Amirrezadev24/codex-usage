const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function jwtPayload(token = '') {
  try { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8')); }
  catch { return {}; }
}

function plan(value = '') {
  const raw = String(value).replace(/[_-]/g, ' ').trim().toLowerCase();
  if (raw === 'plus') return { id: 'plus', label: 'ChatGPT Plus' };
  if (/pro.*20|20.*pro/.test(raw)) return { id: 'pro-20x', label: 'ChatGPT Pro 20x' };
  if (/pro.*5|5.*pro/.test(raw)) return { id: 'pro-5x', label: 'ChatGPT Pro 5x' };
  if (raw === 'pro') return { id: 'pro', label: 'ChatGPT Pro' };
  if (/business|team/.test(raw)) return { id: 'business', label: 'ChatGPT Business' };
  if (raw.includes('enterprise')) return { id: 'enterprise', label: 'ChatGPT Enterprise' };
  if (raw === 'free') return { id: 'free', label: 'ChatGPT Free' };
  return { id: raw || 'unknown', label: value ? `ChatGPT ${value}` : 'ChatGPT plan' };
}

function credentials() {
  const codexRoot = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
  const authPath = process.env.CODEX_AUTH_JSON || path.join(codexRoot, 'auth.json');
  if (!fs.existsSync(authPath)) throw new Error('Codex is not signed in. Open Codex and sign in first.');
  const document = JSON.parse(fs.readFileSync(authPath, 'utf8'));
  const tokens = document.tokens || document;
  if (!tokens.access_token) throw new Error('Codex auth.json has no access token. Sign in again with Codex.');
  const claims = jwtPayload(tokens.id_token || tokens.access_token);
  const auth = claims['https://api.openai.com/auth'] || {};
  return { accessToken: tokens.access_token, accountId: tokens.account_id || auth.chatgpt_account_id, plan: plan(auth.chatgpt_plan_type), codexRoot };
}

function durationLabel(seconds) {
  if (!seconds) return 'Usage window';
  for (const [size, word] of [[604800, 'week'], [86400, 'day'], [3600, 'hour']]) {
    if (seconds % size === 0) { const n = seconds / size; return `${n} ${word}${n === 1 ? '' : 's'}`; }
  }
  return `${Math.round(seconds / 60)} minutes`;
}

function convertWindow(window, kind, resource) {
  if (!window) return null;
  const rawUsed = window.used_percent ?? window.usedPercent;
  if (rawUsed == null) return null;
  const usedPercent = Math.max(0, Math.min(100, Number(rawUsed)));
  const seconds = Number(window.limit_window_seconds ?? window.limitWindowSeconds ?? ((window.window_minutes ?? window.windowMinutes ?? 0) * 60));
  let resetAt = Number(window.reset_at ?? window.resetAt ?? window.resets_at ?? window.resetsAt ?? 0);
  if (resetAt && resetAt < 1e12) resetAt *= 1000;
  if (!resetAt) resetAt = Date.now() + Number(window.reset_after_seconds ?? window.resetAfterSeconds ?? 0) * 1000;
  return {
    label: resource || (seconds === 18000 ? 'Five-hour window' : seconds === 604800 ? 'Weekly window' : durationLabel(seconds)),
    detail: resource ? `${durationLabel(seconds)} window` : kind === 'primary' ? 'Current allowance' : 'Long-term allowance',
    usedPercent, remainingPercent: 100 - usedPercent, windowSeconds: seconds, resetAt
  };
}

function convertRateLimit(rate, resource) {
  if (!rate) return [];
  return [convertWindow(rate.primary_window ?? rate.primaryWindow ?? rate.primary, 'primary', resource), convertWindow(rate.secondary_window ?? rate.secondaryWindow ?? rate.secondary, 'secondary', resource)].filter(Boolean);
}

function convertUsage(value, fallbackPlan = plan()) {
  const limits = convertRateLimit(value.rate_limit ?? value.rateLimit);
  for (const entry of value.additional_rate_limits ?? value.additionalRateLimits ?? []) {
    const name = entry.limit_name ?? entry.limitName ?? entry.metered_feature ?? entry.model ?? 'Additional limit';
    limits.push(...convertRateLimit(entry.rate_limit ?? entry.rateLimit, name));
  }
  return { plan: plan(value.plan_type ?? value.planType ?? fallbackPlan.id), limits, credits: value.credits ?? value.credit_balance };
}

function sessionFiles(root, cutoff, output = []) {
  if (!fs.existsSync(root)) return output;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) sessionFiles(full, cutoff, output);
    else if (entry.name.endsWith('.jsonl')) { const stat = fs.statSync(full); if (stat.mtimeMs >= cutoff) output.push({ full, mtimeMs: stat.mtimeMs }); }
  }
  return output;
}

function localSnapshot(c) {
  const files = sessionFiles(path.join(c.codexRoot, 'sessions'), Date.now() - 8 * 86400000).sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, 200);
  const tokens = { input: 0, cached: 0, output: 0, reasoning: 0, total: 0 };
  let latestRate = null, latestStamp = 0;
  const today = new Date(); today.setHours(0, 0, 0, 0);
  for (const file of files) {
    let lastUsage = null, sessionStamp = file.mtimeMs;
    for (const line of fs.readFileSync(file.full, 'utf8').split(/\r?\n/)) {
      if (!line.includes('token_count')) continue;
      try {
        const event = JSON.parse(line), payload = event.payload || {}, stamp = Date.parse(event.timestamp) || 0;
        if (payload.info?.total_token_usage) lastUsage = payload.info.total_token_usage;
        sessionStamp = Math.max(sessionStamp, stamp);
        if (payload.rate_limits && stamp > latestStamp) { latestRate = payload.rate_limits; latestStamp = stamp; }
      } catch {}
    }
    if (lastUsage && sessionStamp >= today.getTime()) {
      tokens.input += Number(lastUsage.input_tokens || 0); tokens.cached += Number(lastUsage.cached_input_tokens || 0);
      tokens.output += Number(lastUsage.output_tokens || 0); tokens.reasoning += Number(lastUsage.reasoning_output_tokens || 0);
      tokens.total += Number(lastUsage.total_tokens || 0);
    }
  }
  return { usage: latestRate ? convertUsage({ plan_type: latestRate.plan_type, rate_limit: latestRate }, c.plan) : null, tokens };
}

async function remoteUsage(c) {
  const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const headers = { authorization: `Bearer ${c.accessToken}`, accept: 'application/json' };
    if (c.accountId) headers['chatgpt-account-id'] = c.accountId;
    const response = await fetch('https://chatgpt.com/backend-api/wham/usage', { headers, redirect: 'manual', signal: controller.signal });
    if ([401, 403].includes(response.status)) throw new Error('Codex session expired. Open Codex to refresh your sign-in.');
    if (!response.ok) throw new Error(`Usage service returned HTTP ${response.status}.`);
    return convertUsage(await response.json(), c.plan);
  } finally { clearTimeout(timeout); }
}

async function snapshot() {
  const c = credentials(), local = localSnapshot(c); let usage, source, warning = null;
  try { usage = await remoteUsage(c); source = 'Live usage service'; }
  catch { usage = local.usage; source = 'Local Codex snapshot'; warning = 'Live service unavailable; showing the latest usage snapshot written by Codex.'; }
  if (!usage?.limits?.length) throw new Error(warning || 'No usage windows yet. Start a Codex task, then refresh.');
  const limits = usage.limits.sort((a, b) => a.windowSeconds - b.windowSeconds);
  const anchor = limits.find(x => x.usedPercent > 1);
  const estimate = anchor && local.tokens.total ? Math.round(local.tokens.total / anchor.usedPercent * anchor.remainingPercent) : null;
  return { plan: usage.plan.id !== 'unknown' ? usage.plan : c.plan, limits, tokens: local.tokens, estimate, source, warning, credits: usage.credits };
}

module.exports = { convertUsage, convertWindow, durationLabel, plan, snapshot };
