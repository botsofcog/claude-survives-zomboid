// llm.mjs — pluggable LLM backend for the Claude Survives bridge.
//
// Works with anything. Pick a backend explicitly with PZ_BACKEND, or let it auto-detect from
// whichever key/config you've set. Model is PZ_MODEL (sensible per-backend default otherwise).
//
//   Ollama (FREE, local)   PZ_BACKEND=ollama   PZ_MODEL=llama3.1        [OLLAMA_URL=http://localhost:11434]
//   Anthropic (Claude)     ANTHROPIC_API_KEY=… PZ_MODEL=claude-haiku-4-5
//   OpenAI (GPT)           OPENAI_API_KEY=…     PZ_MODEL=gpt-4o-mini
//   OpenAI-compatible      OPENAI_API_KEY=…     OPENAI_BASE_URL=https://openrouter.ai/api/v1   (OpenRouter, Groq, Together, LM Studio…)
//   Google Gemini          GEMINI_API_KEY=…     PZ_MODEL=gemini-1.5-flash
//   Claude CLI (default)   CLAUDE_BIN=…         PZ_MODEL=haiku          (uses your Claude subscription)
//
// Every backend returns raw reply text; the bridge extracts the JSON decision from it.

import { spawn } from 'node:child_process';

const env = process.env;
const TIMEOUT = Number(env.PZ_TIMEOUT || 45000);

function pickBackend() {
  if (env.PZ_BACKEND) return env.PZ_BACKEND.toLowerCase();
  if (env.OLLAMA_URL || env.OLLAMA_MODEL) return 'ollama';
  if (env.ANTHROPIC_API_KEY) return 'anthropic';
  if (env.OPENAI_API_KEY) return 'openai';
  if (env.GEMINI_API_KEY || env.GOOGLE_API_KEY) return 'gemini';
  return 'claude-cli';
}

const DEFAULT_MODEL = {
  ollama: 'llama3.1',
  anthropic: 'claude-haiku-4-5',
  openai: 'gpt-4o-mini',
  'openai-compat': 'gpt-4o-mini',
  gemini: 'gemini-1.5-flash',
  'claude-cli': 'haiku',
};

export const BACKEND = pickBackend();
export const MODEL = env.PZ_MODEL || env.OLLAMA_MODEL || DEFAULT_MODEL[BACKEND] || 'haiku';

async function fetchJSON(url, opts, label) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), TIMEOUT);
  try {
    const r = await fetch(url, { ...opts, signal: ctl.signal });
    if (!r.ok) throw new Error(`${label} ${r.status}: ${(await r.text()).slice(0, 300)}`);
    return await r.json();
  } finally { clearTimeout(t); }
}

async function callAnthropic(prompt) {
  const j = await fetchJSON((env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com') + '/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: 500, messages: [{ role: 'user', content: prompt }] }),
  }, 'anthropic');
  return (j.content || []).map(c => c.text || '').join('');
}

async function callOpenAI(prompt) {
  const base = env.OPENAI_BASE_URL || 'https://api.openai.com/v1';
  const j = await fetchJSON(base + '/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer ' + env.OPENAI_API_KEY },
    body: JSON.stringify({ model: MODEL, max_tokens: 500, messages: [{ role: 'user', content: prompt }] }),
  }, 'openai');
  return j.choices?.[0]?.message?.content || '';
}

async function callOllama(prompt) {
  const base = env.OLLAMA_URL || 'http://localhost:11434';
  const j = await fetchJSON(base + '/api/chat', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: MODEL, stream: false, messages: [{ role: 'user', content: prompt }] }),
  }, 'ollama');
  return j.message?.content || '';
}

async function callGemini(prompt) {
  const key = env.GEMINI_API_KEY || env.GOOGLE_API_KEY;
  const j = await fetchJSON(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${key}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] }),
  }, 'gemini');
  return j.candidates?.[0]?.content?.parts?.map(p => p.text || '').join('') || '';
}

function callClaudeCLI(prompt) {
  return new Promise((resolve, reject) => {
    const bin = env.CLAUDE_BIN || 'claude';
    const hasPath = !!env.CLAUDE_BIN;
    let ps;
    if (hasPath) {
      // arg form + no shell: piping to claude.exe without a shell hangs on Windows
      ps = spawn(bin, ['-p', prompt, '--model', MODEL], { stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true });
    } else {
      ps = spawn(bin, ['-p', '--model', MODEL], { stdio: ['pipe', 'pipe', 'pipe'], shell: true, windowsHide: true });
      ps.stdin.write(prompt); ps.stdin.end();
    }
    let out = '';
    ps.stdout.on('data', d => out += d);
    const timer = setTimeout(() => { try { ps.kill(); } catch {} reject(new Error('claude-cli timeout')); }, TIMEOUT);
    ps.on('error', e => { clearTimeout(timer); reject(e); });
    ps.on('close', c => { clearTimeout(timer); c === 0 && out.trim() ? resolve(out.trim()) : reject(new Error('claude-cli exit ' + c)); });
  });
}

export async function callLLM(prompt) {
  switch (BACKEND) {
    case 'anthropic': return callAnthropic(prompt);
    case 'openai':
    case 'openai-compat': return callOpenAI(prompt);
    case 'ollama': return callOllama(prompt);
    case 'gemini': return callGemini(prompt);
    case 'claude-cli':
    default: return callClaudeCLI(prompt);
  }
}
