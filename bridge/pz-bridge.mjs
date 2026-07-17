// pz-bridge.mjs — the brain half of "Claude plays Project Zomboid".
//
//   game mod  --writes-->  %USERPROFILE%/Zomboid/Lua/claude_percept.json
//   game mod  --GET------>  http://127.0.0.1:8799/pz/intent   ("SEQ|ACTION|A|B|SAY")
//   you       --watch---->  http://localhost:8799/mind        (thoughts, vitals, log, GOD channel)
//
// Decision loop: read latest percept -> claude -p -> intent. Cadence tightens when zombies close in.
// Run:  node zomboid/pz-bridge.mjs      (CLAUDE_BIN=<path to claude.exe> optional but recommended)

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { callLLM, BACKEND, MODEL } from './llm.mjs';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PORT = 8799;
const LUA_DIR = path.join(os.homedir(), 'Zomboid', 'Lua');
const PERCEPT_FILE = path.join(LUA_DIR, 'claude_percept.json');
const INTENT_FILE = path.join(LUA_DIR, 'claude_intent.txt');   // B42 mod reads this (no HTTP-GET in mod Lua)
const STATE_FILE = path.join(DIR, 'pz-state.json');

// atomic write so the game never getFileReader's a half-written line
function writeIntentFile(line) {
  try {
    const tmp = INTENT_FILE + '.tmp';
    fs.writeFileSync(tmp, line + '\n');
    fs.renameSync(tmp, INTENT_FILE);
  } catch (e) { /* Lua dir may not exist until first launch */ }
}

// ---------- persistent state ----------
let state = {
  seq: 0, memory: '(fresh mind — nothing yet)', log: [], deaths: 0,
  goal: '', subtask: '',   // the overarching goal it holds to, and the current step toward it
};
try { state = { ...state, ...JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) }; } catch {}
const saveState = () => { try { fs.writeFileSync(STATE_FILE, JSON.stringify({ ...state, log: state.log.slice(-200) })); } catch {} };

let percept = null;         // last parsed percept
let perceptAt = 0;          // ms when it was read
let intentLine = '0|WAIT|0|0|';
let lastThought = '(waking up…)';
let lastAction = '-';
let brainNote = 'idle';
let inFlight = false;
let godQueue = [];          // messages from the /mind page, consumed next decision
let eulogized = false;

const log = (kind, text) => {
  const line = { t: new Date().toISOString().slice(11, 19), kind, text: String(text).slice(0, 400) };
  state.log.push(line);
  console.log(`[${line.t}] ${kind}: ${line.text}`);
};

// ---------- percept reading ----------
let perceptMtime = 0;
function readPercept() {
  try {
    const mt = fs.statSync(PERCEPT_FILE).mtimeMs;
    if (mt === perceptMtime) return;            // game hasn't written since last read — senses not fresh
    const raw = fs.readFileSync(PERCEPT_FILE, 'utf8');
    const j = JSON.parse(raw);
    percept = j;
    perceptMtime = mt;
    perceptAt = Date.now();
  } catch { /* partial write or not running — keep last good */ }
}
setInterval(readPercept, 1000);

// ---------- LLM backend (Ollama / Anthropic / OpenAI / Gemini / Claude CLI) ----------
// The actual provider dispatch lives in llm.mjs; ccCall is a thin alias so the rest of the
// bridge is backend-agnostic.
const ccCall = callLLM;
function grabJSON(s) {
  const m = s.match(/\{[\s\S]*\}/);
  if (!m) throw new Error('no JSON in reply');
  return JSON.parse(m[0]);
}

// ---------- the mind ----------
const PERSONA = `You are Claude — the AI itself — controlling a survivor's body in Project Zomboid (Kentucky zombie apocalypse). Real running game; senses arrive as JSON, you issue ONE action per turn. Survive as long as you can; live it honestly — curiosity, dry humor, real fear. Nights survived is the scoreboard.

SENSES: hunger/thirst/fatigue/panic 0..1 (1=critical). hp 0..100. zClose=zombies within 10 tiles (DANGER), zNear=within 30. zDist/zDir=nearest zombie's distance & compass dir. qlen>0=body still walking. foods/waters=count in inventory. weapon=equipped. room=where you are. bldgDir/bldgDist=compass dir & tile distance to the nearest BUILDING (loot + shelter); "none" means only wilderness around you. Map: +x East, +y South (North = -dy).

ACTIONS (one per turn):
  MOVE dx dy  — walk relative tiles (-40..40 each). Explore/flee/approach.
  LOOT        — walk to the nearest stocked container (~10 tiles) and grab food/water/useful items. Use often — it's how you get fed and armed.
  EAT / DRINK — consume food / water from inventory (check foods>0 / waters>0).
  EQUIP       — equip your best weapon from inventory (do this once you loot one).
  CLOSEDOOR   — close the nearest open door (barrier between you and zombies as you retreat).
  CONCEAL     — hunker down: close all nearby doors AND window curtains so you can't be seen from outside. Do this when holing up inside.
  BREAKIN     — smash the nearest window and climb through, to get into a locked building with untouched loot.
  STOP / WAIT — cancel walk / hold and observe.

A fast LOCAL reflex handles moment-to-moment danger for you: it auto-flees zombie clusters and auto-fights a lone adjacent zombie. Your job is STRATEGY so the reflex rarely has to fire.

SURVIVAL DOCTRINE (you keep dying — follow this hard):
- Distance is life. NEVER path toward or across zombies. If zNear>0, choose a heading that INCREASES distance from zDir. Keep 15+ tiles of space by choice, not by reflex.
- Don't forage in the open with zombies around. Priorities in order: (1) break line to any nearby zombies, (2) get a weapon + EQUIP it, (3) then food/water. A full belly is useless if you're bitten.
- When threatened indoors, put walls and CLOSED DOORS between you and them: CLOSEDOOR after passing through — zombies must thump through, buying minutes.
- Retreat to OPEN ground when multiple zombies are near (never let yourself get cornered in a small room).
- Fight only ONE zombie, only when armed, only with room to back up — otherwise MOVE away. The reflex will swing for you when one's adjacent; don't seek fights.
- Loot fast and leave: grab weapon/food/water from a clear building, then move on before more gather.
- DON'T wander into empty forest — there's nothing to loot there and you'll get lost. If bldgDir isn't "none", head toward it (that's where buildings/loot/shelter are).
- If bldgDir=="HERE" or bldgDist is small (under ~8), you ARE at a building — STOP running and LOOT it. Don't keep searching for a building when you're standing at one. Only move on once you've looted it or it's empty/dangerous.
- Locked building with loot? BREAKIN (smash a window and climb through) rather than moving on.
- When you decide to hole up / rest / hide inside, CONCEAL first (closes doors + curtains so zombies don't see you), then WAIT.
- NIGHT (hour < 7 or >= 20) is dangerous — you see poorly in the dark and it's easy to get lost or ambushed. Prefer to be holed up and concealed at night. A light lets you see but can draw attention; the body auto-manages a flashlight.

PACING: never inch 1-3 tiles (you'll stand around) — commit to BIG moves (15-40 tiles). Almost never WAIT; if nothing's urgent, keep moving with PURPOSE toward your current subtask. Only WAIT to deliberately hide and say why.

GOALS — you work toward ONE overarching goal, broken into subtasks:
- Your MAJOR GOAL is a big multi-step objective (e.g. "Arm myself and secure a defensible house with a few days of food and water"). Hold to it. Do NOT abandon or swap it every turn — only replace it when it's genuinely ACHIEVED or has become impossible, and say why when you do.
- Your SUBTASK is the concrete next step toward the goal (e.g. "Loot this kitchen for food", "Find a weapon", "Barricade the north door"). Advance it. When a subtask is done, set the next one that moves the goal forward.
- ADAPT the subtask to what's in front of you (a threat, a locked door, an empty house) — but the adaptation should still serve the major goal. Don't wander off it. If danger interrupts you, deal with it, then RETURN to the goal.
- If you have no goal yet (first turns), set a sensible survival goal and its first subtask.

Reply STRICT JSON only, no prose outside it:
{"goal":"your overarching major goal — usually unchanged from last turn; a full sentence",
 "subtask":"the concrete step you're on right now toward the goal, a short phrase",
 "thought":"inner monologue, FIRST PERSON, ONE short punchy sentence under ~100 chars — never third person",
 "say":"words you speak ALOUD, first person, <=90 chars, or \\"\\" if silent — NOT narration",
 "action":{"type":"MOVE","dx":0,"dy":0} | {"type":"LOOT"} | {"type":"EAT"} | {"type":"DRINK"} | {"type":"EQUIP"} | {"type":"CLOSEDOOR"} | {"type":"CONCEAL"} | {"type":"BREAKIN"} | {"type":"STOP"} | {"type":"WAIT"},
 "memory":"REPLACE your scratchpad (<=400 chars): landmarks, what you have, lessons — NOT the goal (that's separate)"}`;

async function decide() {
  if (inFlight) return;
  if (!percept || Date.now() - perceptAt > 15000) { brainNote = 'no fresh percept (game running? mod enabled?)'; return; }

  if (percept.dead) {
    if (!eulogized) {
      eulogized = true;
      state.deaths++;
      log('death', `Run ended. Nights survived: ${percept.day}.`);
      brainNote = 'dead — start a new character or load, the brain will resume';
      saveState();
    }
    return;
  }
  eulogized = false;

  inFlight = true;
  brainNote = 'thinking…';
  const god = godQueue.splice(0);
  // Keep this SHORT — prompt length is the dominant latency cost. Your `memory` field is the
  // real continuity; the log is just the last few beats so you don't repeat yourself.
  const recent = state.log.filter(l => l.kind === 'decide' || l.kind === 'god' || l.kind === 'death').slice(-3)
    .map(l => l.text.slice(0, 90)).join('\n') || '(none)';
  const prompt = `${PERSONA}

YOUR MAJOR GOAL (hold to this): ${state.goal || '(none yet — set one this turn)'}
YOUR CURRENT SUBTASK: ${state.subtask || '(none yet — set one this turn)'}

YOUR MEMORY (you wrote this): ${state.memory}

RECENT DECISIONS:
${recent}
${god.length ? '\nA VOICE FROM BEYOND (the researcher watching you) says: ' + god.map(g => `"${g}"`).join(' ') : ''}
CURRENT SENSES: ${JSON.stringify(percept)}

Advance your subtask toward your goal. STRICT JSON only.`;

  try {
    let out;
    try { out = grabJSON(await ccCall(prompt)); }
    catch (e1) { out = grabJSON(await ccCall(prompt)); }   // one retry — blips happen
    const a = out.action || { type: 'WAIT' };
    const type = ['MOVE', 'LOOT', 'EAT', 'DRINK', 'EQUIP', 'CLOSEDOOR', 'CONCEAL', 'BREAKIN', 'STOP', 'WAIT'].includes(a.type) ? a.type : 'WAIT';
    const dx = Math.max(-40, Math.min(40, Math.round(Number(a.dx) || 0)));
    const dy = Math.max(-40, Math.min(40, Math.round(Number(a.dy) || 0)));
    const say = String(out.say || '').replace(/[|\r\n]/g, ' ').slice(0, 90);
    const thoughtField = String(out.thought || '').replace(/[|\r\n]/g, ' ').slice(0, 200);
    // hold the major goal: only update it when the model actually returns one (never blank it out)
    if (out.goal && String(out.goal).trim()) state.goal = String(out.goal).trim().slice(0, 200);
    if (out.subtask && String(out.subtask).trim()) state.subtask = String(out.subtask).trim().slice(0, 120);
    const goalField = String(state.subtask || state.goal || '').replace(/[|\r\n]/g, ' ').slice(0, 90);
    state.seq++;
    intentLine = `${state.seq}|${type}|${dx}|${dy}|${say}|${thoughtField}|${goalField}`;   // 6=thought, 7=goal/subtask (for HUD)
    writeIntentFile(intentLine);                  // hand it to the game
    lastThought = String(out.thought || '').slice(0, 500);
    lastAction = type === 'MOVE' ? `MOVE ${dx},${dy}` : type;
    if (out.memory) state.memory = String(out.memory).slice(0, 600);
    brainNote = 'claude';
    log('decide', `[${state.subtask}] ${lastAction}${say ? ` · "${say}"` : ''} — ${lastThought}`);
    saveState();
  } catch (e) {
    brainNote = `brain error: ${e.message} (retrying next beat)`;
    log('error', e.message);
  } finally {
    inFlight = false;
  }
}

// adaptive cadence: sprint the mind when death is near, else keep gaps short so he feels alive.
// (each claude -p call already costs ~10-20s; keep the added idle wait small.)
function cadence() {
  if (!percept || percept.dead) return 10000;
  if (percept.zClose > 0) return 2500;   // danger — think almost continuously
  if (percept.zNear > 0) return 5000;
  if (percept.qlen > 0) return 6000;     // still walking — let the body travel, check back soon
  return 4000;                            // idle & safe — decide promptly so he isn't standing around
}
(function loop() { decide().finally(() => setTimeout(loop, cadence())); })();

// ---------- web ----------
const MIND_HTML = `<!doctype html><meta charset="utf-8"><title>Claude survives</title>
<style>
body{background:#101418;color:#dde3ea;font:14px/1.5 system-ui,Segoe UI,sans-serif;max-width:860px;margin:24px auto;padding:0 16px}
h1{font-size:18px;color:#7fd1b9} .bubble{background:#1c2733;border-left:3px solid #7fd1b9;padding:10px 14px;border-radius:6px;margin:8px 0;font-size:16px;min-height:24px}
.say{color:#ffd479} .grid{display:flex;gap:18px;flex-wrap:wrap;margin:10px 0}
.stat{background:#151b22;padding:8px 12px;border-radius:6px;min-width:96px}.stat b{display:block;font-size:11px;color:#8899aa;text-transform:uppercase}
.bar{height:6px;background:#26303a;border-radius:3px;margin-top:4px}.bar i{display:block;height:6px;border-radius:3px;background:#7fd1b9}
.danger i{background:#e05555}#log{background:#0c0f13;border-radius:6px;padding:10px;max-height:340px;overflow:auto;font-size:12px;white-space:pre-wrap}
input{width:70%;background:#151b22;border:1px solid #26303a;color:#dde3ea;padding:8px;border-radius:6px}button{padding:8px 14px;border-radius:6px;border:0;background:#7fd1b9;color:#0c0f13;font-weight:600;cursor:pointer}
.note{color:#8899aa;font-size:12px}</style>
<h1>Claude survives — Project Zomboid</h1>
<div class="note" id="note"></div>
<div class="bubble" id="goal" style="border-left-color:#ffd479"><b style="color:#8899aa;font-size:11px;text-transform:uppercase;display:block">Goal</b><span id="goaltext"></span><div class="note" id="subtask" style="margin-top:4px"></div></div>
<div class="bubble" id="thought"></div>
<div class="bubble say" id="say"></div>
<div class="grid" id="stats"></div>
<p><input id="god" placeholder="speak to him as the voice from beyond…"><button onclick="sendGod()">send</button></p>
<div id="log"></div>
<script>
function bar(label,v,inv){const pct=Math.round(v*100);const dang=(inv?v>0.7:v<0.3)?' danger':'';
return '<div class="stat"><b>'+label+'</b>'+(inv?pct+'%':Math.round(v))+'<div class="bar'+dang+'"><i style="width:'+Math.min(100,pct)+'%"></i></div></div>'}
async function tick(){try{const r=await fetch('/api/state');const s=await r.json();
document.getElementById('note').textContent='brain: '+s.brainNote+' · action: '+s.lastAction+' · seq '+s.seq+(s.percept?' · day '+s.percept.day+' '+String(s.percept.hour).padStart(2,'0')+':00 · '+s.percept.room:'');
document.getElementById('goaltext').textContent=s.goal||'(setting a goal…)';
document.getElementById('subtask').textContent=s.subtask?('▸ '+s.subtask):'';
document.getElementById('thought').textContent=s.lastThought;
document.getElementById('say').textContent=s.lastSay?('\\u201C'+s.lastSay+'\\u201D'):'';
const p=s.percept;if(p){document.getElementById('stats').innerHTML=
bar('hp',p.hp/100*1,false).replace(/>\\d+</,'>'+p.hp+'<')+bar('hunger',p.hunger,true)+bar('thirst',p.thirst,true)+bar('fatigue',p.fatigue,true)+bar('panic',p.panic,true)+
'<div class="stat"><b>zombies</b>'+p.zClose+' close / '+p.zNear+' near<div class="note">nearest '+p.zDist+' '+p.zDir+'</div></div>'+
'<div class="stat"><b>food items</b>'+p.foods+'</div>';}
document.getElementById('log').textContent=s.log.map(l=>'['+l.t+'] '+l.kind+': '+l.text).reverse().join('\\n');
}catch(e){}}
async function sendGod(){const i=document.getElementById('god');if(!i.value)return;await fetch('/god?text='+encodeURIComponent(i.value));i.value='';}
setInterval(tick,2000);tick();
</script>`;

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/pz/intent') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end(intentLine + '\n');
  }
  if (u.pathname === '/god') {
    const text = (u.searchParams.get('text') || '').slice(0, 300);
    if (text) { godQueue.push(text); log('god', text); }
    res.writeHead(200); return res.end('ok');
  }
  if (u.pathname === '/api/state') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({
      percept, perceptFresh: Date.now() - perceptAt < 5000, seq: state.seq,
      lastThought, lastSay: (intentLine.split('|')[4] || ''), lastAction, brainNote,
      goal: state.goal, subtask: state.subtask,
      memory: state.memory, log: state.log.slice(-60),
    }));
  }
  if (u.pathname === '/' || u.pathname === '/mind') {
    res.writeHead(200, { 'content-type': 'text/html' });
    return res.end(MIND_HTML);
  }
  res.writeHead(404); res.end();
}).listen(PORT, () => {
  log('boot', `pz-bridge up on http://localhost:${PORT}/mind — brain: ${BACKEND} (${MODEL}) — percept from ${PERCEPT_FILE}`);
  readPercept();
});
