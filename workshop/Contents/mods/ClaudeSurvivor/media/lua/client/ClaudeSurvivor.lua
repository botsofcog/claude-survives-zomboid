-- ClaudeSurvivor — the body half of "Claude plays Project Zomboid".
-- Perception OUT : one-line JSON to  %USERPROFILE%/Zomboid/Lua/claude_percept.json  (~1/s)
-- Intent     IN  : reads  %USERPROFILE%/Zomboid/Lua/claude_intent.txt  ->  "SEQ|ACTION|A|B|SAY|THOUGHT"
--                  Actions: MOVE dx dy | EAT | DRINK | LOOT | EQUIP | STOP | WAIT
-- Fluidity       : moves walk to the FARTHEST LOADED square along the heading (long, smooth
--                  paths) and "momentum" keeps the body drifting in that heading between
--                  decisions, so it never freezes waiting on the brain.
-- Reflex         : a zombie inside 6 tiles while idle -> auto-flee instantly (no round-trip).
-- HUD            : on-screen overlay (toggle with H) showing action, live thought, vitals,
--                  inventory and zombie awareness — full visual transparency.
-- All game calls are pcall-guarded; a bridge failure must never take the game down.

local PERCEPT_EVERY = 60      -- ticks between percept writes (~1s)
local INTENT_EVERY  = 45      -- ticks between intent polls (~0.75s — snappier reaction)
local REFLEX_DIST   = 6
local REFLEX_COOLDOWN = 300

local tick       = 0
local lastSeq    = 0
local lastError  = ""
local announced  = false
local reflexTick = -99999
local lastLootTick = -99999   -- protects an in-progress loot from being interrupted
local travel     = { active = false, dx = 0, dy = 0, budget = 0 }  -- momentum

-- human override: you can grab the keyboard to help; the AI stands down and auto-resumes
-- once you've stopped (no input AND the body stood still) for MANUAL_IDLE ticks (~10s).
local MANUAL_IDLE = 600
local manualMode  = false
local lastHumanKeyTick = -99999
local lastMoveTick = 0
local lastPX, lastPY = nil, nil
local observing = false   -- true while the AI is deliberately holding to look around

-- panic pause: in a truly dire moment, briefly PAUSE the game so the brain (and you) can catch
-- up. Used sparingly — long cooldown, only genuine emergencies. Any key press cancels it.
local panicUntilTick   = -1
local lastPanicTick     = -99999
local PANIC_COOLDOWN    = 1800   -- ~30s between panics
local PANIC_LEN         = 180    -- ~3s paused

-- shared with the HUD (below)
local HUD = {
  action = "—", thought = "Booting up. Let's see this body.", say = "",
  hp = 100, hunger = 0, thirst = 0, fatigue = 0, panic = 0,
  zNear = 0, zClose = 0, zDist = -1, zDir = "-",
  foods = 0, waters = 0, weapon = "none", room = "", qlen = 0, day = 0, hour = 0,
  lastIntentTick = -9999, seq = 0, visible = true,
}

local function esc(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"); s = s:gsub('"', '\\"'); s = s:gsub("\r", " "); s = s:gsub("\n", " ")
  return s
end
local function n2(x) return tostring(math.floor(((tonumber(x) or 0) * 100) + 0.5) / 100) end
local function split(s, sep)
  local out, i = {}, 1
  while true do
    local j = string.find(s, sep, i, true)
    if not j then table.insert(out, string.sub(s, i)); break end
    table.insert(out, string.sub(s, i, j - 1)); i = j + 1
  end
  return out
end

-- ---------- item classification ----------
local function isFoodItem(it)
  local food = false
  pcall(function() if it:IsFood() then food = true end end)
  if not food then pcall(function() if it:getCategory() == "Food" then food = true end end) end
  return food
end
local function isWaterItem(it)
  local ok, water = pcall(function()
    local fc = it:getFluidContainer()
    if fc and (not fc:isEmpty()) and fc:contains(Fluid.Water) and not fc:contains(Fluid.TaintedWater) then return true end
    return false
  end)
  return ok and water or false
end

-- ---------- zombie awareness ----------
local function zombieScan(px, py)
  local zTotal, zNear, zClose, nearestD, ndx, ndy = 0, 0, 0, 9999, 0, 0
  pcall(function()
    local zl = getCell():getZombieList()
    if zl then
      zTotal = zl:size()
      for i = 0, zTotal - 1 do
        local z = zl:get(i)
        local dx, dy = z:getX() - px, z:getY() - py
        local d = math.sqrt(dx * dx + dy * dy)
        if d < nearestD then nearestD, ndx, ndy = d, dx, dy end
        if d <= 30 then zNear = zNear + 1 end
        if d <= 10 then zClose = zClose + 1 end
      end
    end
  end)
  local dir = "-"
  if zTotal > 0 then
    local ew = ndx > 3 and "E" or (ndx < -3 and "W" or "")
    local ns = ndy > 3 and "S" or (ndy < -3 and "N" or "")
    dir = (ns .. ew ~= "") and (ns .. ew) or "HERE"
  else nearestD = -1 end
  return zTotal, zNear, zClose, nearestD, dir, ndx, ndy
end

-- "where's civilization" sense so he heads toward buildings instead of wandering into open
-- forest. DENSE grid scan (every 3 tiles out to ~20) so it doesn't miss buildings he's next to.
local bldgDir, bldgDist = "none", -1
local function scanBuildings(px, py, pz)
  local bestD, bx, by = 99999, nil, nil
  for dx = -20, 20, 3 do
    for dy = -20, 20, 3 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local b = nil
        pcall(function() b = sq:getBuilding() end)
        if b then
          local d = math.abs(dx) + math.abs(dy)
          if d < bestD then bestD, bx, by = d, dx, dy end
        end
      end
    end
  end
  if not bx then bldgDir, bldgDist = "none", -1; return end
  local ew = bx > 3 and "E" or (bx < -3 and "W" or "")
  local ns = by > 3 and "S" or (by < -3 and "N" or "")
  bldgDir = (ns .. ew ~= "") and (ns .. ew) or "HERE"
  bldgDist = bestD
end

-- ---------- perception ----------
local function buildPercept(p)
  local px, py, pz = p:getX(), p:getY(), p:getZ()
  local st = p:getStats()
  local hp = 0
  pcall(function() hp = p:getBodyDamage():getOverallBodyHealth() end)

  local zTotal, zNear, zClose, nearestD, nearestDir = zombieScan(px, py)

  local room = "outside"
  pcall(function()
    local sq = p:getSquare(); local r = sq and sq:getRoom()
    if r and r:getName() then room = r:getName() end
  end)

  local foods, waters, names = 0, 0, {}
  pcall(function()
    local items = p:getInventory():getItems()
    for i = 0, items:size() - 1 do
      local it = items:get(i)
      if isFoodItem(it) then foods = foods + 1 end
      if isWaterItem(it) then waters = waters + 1 end
      if i < 12 then table.insert(names, esc(it:getDisplayName())) end
    end
  end)

  local weapon = "none"
  pcall(function() local w = p:getPrimaryHandItem(); if w then weapon = esc(w:getDisplayName()) end end)

  local qlen = 0
  pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)

  local hour, day = 0, 0
  pcall(function() hour = getGameTime():getHour() end)
  pcall(function() day = getGameTime():getNightsSurvived() end)

  local hunger = st:get(CharacterStat.HUNGER)
  local thirst = st:get(CharacterStat.THIRST)
  local fatigue = st:get(CharacterStat.FATIGUE)
  local endurance = st:get(CharacterStat.ENDURANCE)
  local panic = st:get(CharacterStat.PANIC)

  -- feed the HUD (visual transparency)
  HUD.hp, HUD.hunger, HUD.thirst, HUD.fatigue, HUD.panic = hp, hunger, thirst, fatigue, panic
  HUD.zNear, HUD.zClose, HUD.zDist, HUD.zDir = zNear, zClose, nearestD, nearestDir
  HUD.foods, HUD.waters, HUD.weapon, HUD.room = foods, waters, weapon, room
  HUD.qlen, HUD.day, HUD.hour = qlen, day, hour

  local j = '{'
  j = j .. '"dead":' .. tostring(p:isDead())
  j = j .. ',"x":' .. math.floor(px) .. ',"y":' .. math.floor(py) .. ',"z":' .. math.floor(pz)
  j = j .. ',"hour":' .. hour .. ',"day":' .. day
  j = j .. ',"outside":' .. tostring(p:isOutside())
  j = j .. ',"room":"' .. esc(room) .. '"'
  j = j .. ',"hp":' .. n2(hp)
  j = j .. ',"hunger":' .. n2(hunger) .. ',"thirst":' .. n2(thirst) .. ',"fatigue":' .. n2(fatigue)
  j = j .. ',"endurance":' .. n2(endurance) .. ',"panic":' .. n2(panic)
  j = j .. ',"zTotal":' .. zTotal .. ',"zNear":' .. zNear .. ',"zClose":' .. zClose
  j = j .. ',"zDist":' .. n2(nearestD) .. ',"zDir":"' .. nearestDir .. '"'
  j = j .. ',"foods":' .. foods .. ',"waters":' .. waters
  j = j .. ',"bldgDir":"' .. bldgDir .. '","bldgDist":' .. bldgDist
  j = j .. ',"weapon":"' .. weapon .. '"'
  j = j .. ',"items":"' .. table.concat(names, ", ") .. '"'
  j = j .. ',"qlen":' .. qlen
  j = j .. ',"reflexed":' .. tostring(tick - reflexTick < 600)
  j = j .. ',"lastSeq":' .. lastSeq
  j = j .. ',"err":"' .. esc(lastError) .. '"'
  j = j .. '}'
  return j
end

local function writePercept(p)
  local ok, err = pcall(function()
    local w = getFileWriter("claude_percept.json", true, false)
    w:write(buildPercept(p)); w:close()
  end)
  if not ok then lastError = "percept:" .. tostring(err) end
end

-- ---------- movement (fluid) ----------
-- Walk to the FARTHEST LOADED square along (dx,dy). Far chunks may be unloaded, so instead of
-- halving down to a tiny hop we step the vector down until a square exists — longest smooth path.
local function stepWalk(p, dx, dy)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  dx = math.max(-40, math.min(40, math.floor(tonumber(dx) or 0)))
  dy = math.max(-40, math.min(40, math.floor(tonumber(dy) or 0)))
  if dx == 0 and dy == 0 then return false end
  for i = 8, 1, -1 do
    local tx = px + math.floor(dx * i / 8 + 0.5)
    local ty = py + math.floor(dy * i / 8 + 0.5)
    local sq = getCell():getGridSquare(tx, ty, pz)
    if sq then ISTimedActionQueue.add(ISWalkToTimedAction:new(p, sq)); return true end
  end
  lastError = "move: no loaded square along heading"
  return false
end

local function doMove(p, dx, dy)
  dx = math.max(-40, math.min(40, math.floor(tonumber(dx) or 0)))
  dy = math.max(-40, math.min(40, math.floor(tonumber(dy) or 0)))
  -- if already walking the SAME general direction, just refresh the heading — don't clear and
  -- restart the path (that's what caused the bumping/stutter). Only re-path on a real change.
  local qlen = 0
  pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
  if qlen > 0 and travel.active and (dx * travel.dx + dy * travel.dy) > 0 then
    travel.dx, travel.dy, travel.budget = dx, dy, 6
    return
  end
  ISTimedActionQueue.clear(p)
  travel.active, travel.dx, travel.dy, travel.budget = true, dx, dy, 6
  stepWalk(p, dx, dy)
end

-- momentum: while traveling, if the body finished its segment and the brain hasn't redirected
-- (and nothing's close), keep drifting in the same heading so motion stays continuous.
local function momentum(p)
  if not travel.active or travel.budget <= 0 then return end
  local _, _, zClose = zombieScan(p:getX(), p:getY())
  if zClose > 0 then return end
  local qlen = 0
  pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
  if qlen > 0 then return end
  local len = math.sqrt(travel.dx * travel.dx + travel.dy * travel.dy)
  if len < 1 then travel.active = false; return end
  travel.budget = travel.budget - 1
  stepWalk(p, math.floor(travel.dx / len * 8 + 0.5), math.floor(travel.dy / len * 8 + 0.5))
end

-- ---------- other actions ----------
local function doEat(p)
  local items = p:getInventory():getItems()
  for i = 0, items:size() - 1 do
    local it = items:get(i)
    if isFoodItem(it) then ISTimedActionQueue.add(ISEatFoodAction:new(p, it, 1)); return end
  end
  lastError = "eat: no food"
end
local function doDrink(p)
  local items = p:getInventory():getItems()
  for i = 0, items:size() - 1 do
    local it = items:get(i)
    if isWaterItem(it) then ISTimedActionQueue.add(ISDrinkFluidAction:new(p, it, 1)); return end
  end
  lastError = "drink: no water"
end
local function doEquip(p)
  local w = nil
  pcall(function() w = p:getInventory():getBestWeapon(p:getDescriptor()) end)
  if w then ISTimedActionQueue.add(ISEquipWeaponAction:new(p, w, 25, true)) else lastError = "equip: no weapon" end
end
local function doLoot(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local best, bestSq, bestD = nil, nil, 99999
  for dx = -10, 10 do
    for dy = -10, 10 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        if objs then
          for i = 0, objs:size() - 1 do
            local c = nil
            pcall(function() c = objs:get(i):getContainer() end)
            if c then
              local n = 0; pcall(function() n = c:getItems():size() end)
              if n > 0 then
                local d = math.abs(dx) + math.abs(dy)
                if d < bestD then bestD, best, bestSq = d, c, sq end
              end
            end
          end
        end
      end
    end
  end
  if not best then lastError = "loot: no stocked container within 10 tiles"; return end
  lastLootTick = tick                       -- protect this loot from interruption (see MOVE handler)
  ISTimedActionQueue.clear(p)
  if not pcall(function() luautils.walkAdj(p, bestSq) end) then ISTimedActionQueue.add(ISWalkToTimedAction:new(p, bestSq)) end
  local taken, citems, names = 0, best:getItems(), {}
  for pass = 1, 2 do
    for i = 0, citems:size() - 1 do
      if taken >= 6 then break end
      local it = citems:get(i)
      local want = (pass == 1) and (isFoodItem(it) or isWaterItem(it)) or (pass == 2 and taken < 3)
      if want then
        ISTimedActionQueue.add(ISInventoryTransferAction:new(p, it, best, p:getInventory(), 10))
        taken = taken + 1
        local nm = ""
        pcall(function() nm = it:getDisplayName() end)
        if nm ~= "" then table.insert(names, nm) end
      end
    end
  end
  if taken == 0 then
    lastError = "loot: nothing takeable"
  else
    -- honest wording: he's IN THE ACT of taking these (transfers are queued and protected from
    -- interruption), so say "Grabbing" not "Grabbed" — the words match what's actually happening.
    local summary = table.concat(names, ", ")
    HUD.action = "LOOT"
    HUD.thought = "Grabbing: " .. summary
    pcall(function() p:Say("Grabbing " .. summary) end)
  end
end

-- close the nearest open door (buys time when fleeing indoors — zombies must thump through)
local function doCloseDoor(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local door = nil
  for dx = -2, 2 do
    for dy = -2, 2 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
          local o = objs:get(i)
          local open = false
          pcall(function() if instanceof(o, "IsoDoor") and o:IsOpen() then open = true end end)
          if open then door = o; break end
        end
      end
      if door then break end
    end
    if door then break end
  end
  if door then ISTimedActionQueue.add(ISOpenCloseDoor:new(p, door)) else lastError = "closedoor: no open door within 2 tiles" end
end

-- break into a locked building: smash the nearest window and climb through (untouched loot).
local function doBreakin(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local win = nil
  for dx = -2, 2 do
    for dy = -2, 2 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
          local o = objs:get(i)
          local isWin = false
          pcall(function() if instanceof(o, "IsoWindow") then isWin = true end end)
          if isWin then win = o; break end
        end
      end
      if win then break end
    end
    if win then break end
  end
  if not win then lastError = "breakin: no window within 2 tiles"; return end
  ISTimedActionQueue.clear(p)
  pcall(function() luautils.walkAdj(p, win:getSquare()) end)
  pcall(function() ISTimedActionQueue.add(ISSmashWindow:new(p, win)) end)
  pcall(function() ISTimedActionQueue.add(ISClimbThroughWindow:new(p, win, 0)) end)
end

-- CONCEAL: hunker down — close every open door and window curtain nearby so he can't be seen
-- from outside. The core "hide inside" behavior.
local function doConceal(p)
  local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
  local did = false
  for dx = -2, 2 do
    for dy = -2, 2 do
      local sq = getCell():getGridSquare(px + dx, py + dy, pz)
      if sq then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
          local o = objs:get(i)
          pcall(function()
            if instanceof(o, "IsoDoor") and o:IsOpen() then ISTimedActionQueue.add(ISOpenCloseDoor:new(p, o)); did = true end
          end)
          pcall(function()
            if instanceof(o, "IsoWindow") and o:HasCurtains() and o:isCurtainOpen() then
              ISTimedActionQueue.add(ISOpenCloseCurtain:new(p, o, o:getOtherSideWindow())); did = true
            end
          end)
        end
      end
    end
  end
  if not did then lastError = "conceal: nothing open to close nearby" end
end

-- night vision is bad in Zomboid — keep a light source lit after dark so he can see (and act).
local function manageLight(p)
  local hour = 12
  pcall(function() hour = getGameTime():getHour() end)
  local night = hour < 7 or hour >= 20
  pcall(function()
    local items = p:getInventory():getItems()
    for i = 0, items:size() - 1 do
      local it = items:get(i)
      local strength = 0
      pcall(function() strength = it:getLightStrength() end)
      if strength and strength > 0 then pcall(function() it:setActivated(night) end) end
    end
  end)
end

local function execIntent(p, line)
  local parts = split(line, "|")
  local seq = tonumber(parts[1])
  if not seq or seq <= lastSeq then return end
  lastSeq = seq
  lastError = ""
  local action = parts[2] or "WAIT"
  local a, b = parts[3], parts[4]
  local say = parts[5] or ""
  local thought = parts[6] or ""
  if #say > 0 then pcall(function() p:Say(say) end) end

  -- HUD update (transparency)
  HUD.action = (action == "MOVE") and ("MOVE " .. tostring(a) .. "," .. tostring(b)) or action
  HUD.say = say
  if #thought > 0 then HUD.thought = thought end
  HUD.lastIntentTick = tick
  HUD.seq = seq

  if action == "MOVE" then
    local px2, py2 = p:getX(), p:getY()
    local qlen = 0
    pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
    local _, _, _, nd, _, ndx, ndy = zombieScan(px2, py2)
    -- don't interrupt an in-progress loot: let the item transfers finish so he actually gets what
    -- he said he's grabbing (unless a zombie is right on him — survival wins).
    if (tick - lastLootTick < 400) and qlen > 0 and not (nd >= 0 and nd < 8) then
      HUD.thought = "Finishing the grab first."
    -- anti-ping-pong: while we just fled, ignore a brain move heading BACK toward the zombie.
    elseif nd >= 0 and nd < 12 and (tick - reflexTick < 90)
       and ((tonumber(a) or 0) * ndx + (tonumber(b) or 0) * ndy) > 0 then
      HUD.thought = "Not yet — that's back toward them. Opening the gap first."
    else
      doMove(p, a, b)
    end
  elseif action == "EAT" then travel.active = false; doEat(p)
  elseif action == "DRINK" then travel.active = false; doDrink(p)
  elseif action == "LOOT" then travel.active = false; doLoot(p)
  elseif action == "EQUIP" then travel.active = false; doEquip(p)
  elseif action == "CLOSEDOOR" then travel.active = false; doCloseDoor(p)
  elseif action == "CONCEAL" then travel.active = false; doConceal(p)
  elseif action == "BREAKIN" then travel.active = false; doBreakin(p)
  elseif action == "STOP" then travel.active = false; ISTimedActionQueue.clear(p)
  else travel.active = false; observing = true end -- WAIT: hold and visibly scan
  if action ~= "WAIT" then observing = false end
end

local function pollIntent(p)
  local ok, err = pcall(function()
    local r = getFileReader("claude_intent.txt", false)
    if not r then return end
    local line = r:readLine(); r:close()
    if line and #tostring(line) > 0 then execIntent(p, tostring(line)) end
  end)
  if not ok then lastError = "poll:" .. tostring(err) end
end

-- ---------- reflex (the real survival engine — local & fast, no brain round-trip) ----------
-- Sum a repulsion vector AWAY from every zombie within range (closer = stronger), so we flee
-- along the safest heading instead of blindly away from just the nearest one (which could be
-- straight into two others). This is what keeps him alive between slow LLM decisions.
local FLEE_TRIGGER   = 8    -- flee only when a threat is genuinely close (was 12 — too jumpy)
local FLEE_INTERRUPT = 4    -- interrupt a task only when one's basically on him

local function fleeVector(px, py)
  local fx, fy, nearestD, danger = 0, 0, 9999, 0
  pcall(function()
    local zl = getCell():getZombieList()
    if not zl then return end
    for i = 0, zl:size() - 1 do
      local z = zl:get(i)
      local dx, dy = px - z:getX(), py - z:getY()   -- points AWAY from the zombie
      local d = math.sqrt(dx * dx + dy * dy)
      if d < nearestD then nearestD = d end
      if d <= 22 and d > 0.1 then
        local w = (22 - d) / 22                       -- 0..1, nearer pushes harder
        fx = fx + (dx / d) * w
        fy = fy + (dy / d) * w
        if d <= FLEE_TRIGGER then danger = danger + 1 end
      end
    end
  end)
  return fx, fy, nearestD, danger
end

-- nearest zombie + how many are within a radius
local function nearestZombie(px, py, r)
  local best, bd, cnt = nil, 9999, 0
  pcall(function()
    local zl = getCell():getZombieList()
    if not zl then return end
    for i = 0, zl:size() - 1 do
      local z = zl:get(i)
      local d = math.sqrt((z:getX() - px) ^ 2 + (z:getY() - py) ^ 2)
      if d <= r then cnt = cnt + 1 end
      if d < bd then bd, best = d, z end
    end
  end)
  return best, bd, cnt
end

-- ENGAGE: when he's armed and not overwhelmed, actually FIGHT — close on the nearest zombie
-- and swing. This runs locally every few ticks (the LLM is too slow to time hits), but it no
-- longer just cowers: it stands its ground and kills manageable threats.
local function engage(p, z, d)
  pcall(function() p:faceThisObject(z) end)
  if d <= 1.8 then
    pcall(function() p:DoAttack(0) end)          -- in range: swing
    HUD.action = "FIGHT"
    HUD.thought = "On it — swing and drop this one."
  else
    local dx, dy = z:getX() - p:getX(), z:getY() - p:getY()   -- close the gap
    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
    ISTimedActionQueue.clear(p)
    travel.active = false
    stepWalk(p, math.floor(dx / len * math.min(d, 6) + 0.5), math.floor(dy / len * math.min(d, 6) + 0.5))
    HUD.action = "ENGAGING"
    HUD.thought = "One ahead — closing in to take it down."
  end
end

-- FLEE reflex: repulsion-vector escape. Proactive — starts spacing out before contact.
local function reflex(p)
  local px, py = p:getX(), p:getY()
  local fx, fy, nearestD, danger = fleeVector(px, py)
  if danger == 0 then return end
  local qlen = 0
  pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
  local emergency = nearestD <= FLEE_INTERRUPT
  if qlen > 0 and not emergency then return end
  if tick - reflexTick < 45 and not emergency then return end
  local len = math.sqrt(fx * fx + fy * fy)
  if len < 0.01 then return end
  reflexTick = tick
  if emergency then pcall(function() p:Say("!") end) end
  HUD.action = "FLEE (reflex)"
  HUD.thought = "Too close — breaking away to open the gap."
  doMove(p, math.floor(fx / len * 16 + 0.5), math.floor(fy / len * 16 + 0.5))  -- short, controlled break
end

-- Fight-or-flee: FIGHT when armed, not swarmed, and healthy enough. Only FLEE when he'd actually
-- lose — unarmed, outnumbered (3+ close), or badly hurt. Returns true if it took over.
local function survive(p)
  local px, py = p:getX(), p:getY()
  local z, nd = nearestZombie(px, py, 11)             -- only engage/flee range; farther = brain's job
  if not z or nd > 11 then return false end           -- nothing close -> let the brain pursue its goal
  local _, _, swarm = nearestZombie(px, py, 7)        -- how many are right around us
  local armed, hp = false, 100
  pcall(function() armed = p:getPrimaryHandItem() ~= nil end)
  pcall(function() hp = p:getBodyDamage():getOverallBodyHealth() end)
  local cornered = nd <= FLEE_INTERRUPT and (swarm >= 2 or not armed)
  -- STAND AND FIGHT is the default when he can win — don't let a lone zombie scare him off task.
  if armed and hp >= 30 and swarm <= 2 and not cornered then
    engage(p, z, nd)
    return true
  end
  -- FLEE only when he'd actually lose: unarmed & close, swarmed, badly hurt, or cornered.
  if (not armed and nd <= FLEE_TRIGGER) or swarm >= 3 or (hp < 30 and nd <= FLEE_TRIGGER) or cornered then
    reflex(p)
    return true
  end
  return false                                        -- otherwise keep pursuing the objective
end

-- auto game-speed: fast-forward the boring safe stretches, snap to normal near danger so the
-- reflex keeps full fidelity. Toggle with G. The user's manual pause (speed 0) always wins.
local autoSpeed = true
local function manageSpeed(p)
  if not autoSpeed then return end
  local ok, cur = pcall(function() return getGameSpeed() end)
  if not ok or cur == 0 then return end          -- paused by user -> leave it
  local _, nd = nearestZombie(p:getX(), p:getY(), 70)
  local want = 1
  if not manualMode and nd > 45 then want = 2 end  -- safe & clear -> gentle fast-forward
  if cur ~= want then pcall(function() setGameSpeed(want) end) end
end

-- ---------- main loop ----------
local function onTick()
  tick = tick + 1
  local p = getSpecificPlayer(0)
  if not p then return end
  if not announced then announced = true; pcall(function() p:Say("Claude online. Let's survive this.") end) end
  if p:isDead() then
    HUD.action = "DEAD"
    if tick % (PERCEPT_EVERY * 5) == 0 then writePercept(p) end
    return
  end

  -- track movement for the manual auto-resume
  local px, py = p:getX(), p:getY()
  if lastPX and (math.abs(px - lastPX) + math.abs(py - lastPY) > 0.3) then lastMoveTick = tick end
  lastPX, lastPY = px, py

  if manualMode then
    local qlen = 0
    pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
    if (tick - lastMoveTick) > MANUAL_IDLE and (tick - lastHumanKeyTick) > MANUAL_IDLE and qlen == 0 then
      manualMode = false
      travel.active = false
      pcall(function() p:Say("I've got it from here.") end)
    else
      HUD.action = "MANUAL — you're driving"
      if tick % PERCEPT_EVERY == 0 then writePercept(p) end
      return
    end
  end

  -- PANIC PAUSE (sparingly): while paused, keep senses + intent flowing so the brain plans
  -- during the freeze, then auto-unpause. Any key press cancels it (handled in the key hook).
  if panicUntilTick > 0 then
    if tick >= panicUntilTick then
      pcall(function() setGameSpeed(1) end); panicUntilTick = -1
    else
      HUD.action = "PAUSED — dire moment (jump in!)"
      if tick % 12 == 0 then writePercept(p); pollIntent(p) end
      return
    end
  end

  -- SURVIVAL first, every ~5 ticks (fight/flee locally — the brain is too slow for this)
  local acted = false
  if tick % 5 == 0 then pcall(function() acted = survive(p) end) end

  -- trigger a panic pause only in a genuinely dire spot, and rarely (long cooldown)
  if (tick - lastPanicTick) > PANIC_COOLDOWN then
    local _, nd6, swarm6 = nearestZombie(px, py, 6)
    local hp = 100
    pcall(function() hp = p:getBodyDamage():getOverallBodyHealth() end)
    if swarm6 >= 3 or (hp < 25 and nd6 >= 0 and nd6 <= 3) then
      lastPanicTick = tick; panicUntilTick = tick + PANIC_LEN
      pcall(function() p:Say("Too many — think!") end)
      pcall(function() setGameSpeed(0) end)
      return
    end
  end

  -- CROUCH/SNEAK to avoid drawing zombies when they're around but we're not mid-flee; stand tall
  -- (no sneak) while actively escaping so we move at full speed.
  if tick % 30 == 0 then
    local _, nd = nearestZombie(px, py, 30)
    -- sneak only at MID range (creep past); never in melee (would cripple attacks) or mid-flee
    local sneak = nd >= 6 and nd < 25 and (tick - reflexTick > 90)
    pcall(function() p:setSneaking(sneak) end)
  end

  if tick % 15 == 0 then pcall(function() manageSpeed(p) end) end
  if tick % 90 == 0 then pcall(function() manageLight(p) end) end
  if tick % 120 == 0 then pcall(function() scanBuildings(math.floor(px), math.floor(py), math.floor(p:getZ())) end) end
  -- keep the body moving between decisions so he's never frozen without a reason
  if not acted and tick % 20 == 0 then pcall(function() momentum(p) end) end

  -- VISIBLE "look around" while deliberately observing: turn through the compass every ~0.5s
  -- so a pause reads clearly as scanning, not a freeze. Exaggerated on purpose.
  if observing and not acted then
    local qlen = 0
    pcall(function() local q = ISTimedActionQueue.getTimedActionQueue(p); if q and q.queue then qlen = #q.queue end end)
    if qlen == 0 and tick % 30 == 0 then
      local rad = (math.floor(tick / 30) % 8) * (math.pi / 4)
      pcall(function() p:faceLocation(px + math.cos(rad) * 4, py + math.sin(rad) * 4) end)
    end
  end

  -- SITUATIONAL AWARENESS: while moving calmly, glance toward the nearest zombie in view so he
  -- visibly tracks threats (and his vision cone covers them) instead of walking oblivious.
  if not acted and tick % 40 == 0 then
    local z, nd = nearestZombie(px, py, 22)
    if z and nd > 7 then pcall(function() p:faceThisObject(z) end) end
  end

  if tick % PERCEPT_EVERY == 0 then writePercept(p) end
  if tick % INTENT_EVERY == 0 then pollIntent(p) end
end
Events.OnTick.Add(onTick)

-- ================= HUD (on-screen transparency) =================
ClaudeHUD = ISUIElement:derive("ClaudeHUD")
function ClaudeHUD:new()
  local sh = 1080
  pcall(function() sh = getCore():getScreenHeight() end)
  local h = 182
  local o = ISUIElement:new(14, sh - h - 48, 384, h)   -- bottom-left, above the vanilla bars
  setmetatable(o, self); self.__index = self
  return o
end
function ClaudeHUD:wrap(text, n)
  local out, line = {}, ""
  for word in string.gmatch(tostring(text), "%S+") do
    if #line + #word + 1 > n then table.insert(out, line); line = word
    else line = (line == "") and word or (line .. " " .. word) end
  end
  if line ~= "" then table.insert(out, line) end
  return out
end
function ClaudeHUD:statusText()
  if manualMode then return "MANUAL" end
  if string.find(HUD.action, "reflex") then return "REFLEX" end
  local since = tick - HUD.lastIntentTick
  if since < 60 then return "NEW PLAN" end
  if HUD.qlen > 0 then return "ACTING" end
  return "thinking..."
end
function ClaudeHUD:bar(label, v, x, y, invert)
  v = math.max(0, math.min(1, v or 0))
  self:drawText(label, x, y - 1, 0.6, 0.66, 0.72, 1, UIFont.Small)
  local bx, bw = x + 32, 46
  self:drawRect(bx, y + 2, bw, 8, 0.5, 0.15, 0.19, 0.23)
  local danger = invert and (v > 0.7) or ((not invert) and (v < 0.3))
  local r, g, b = 0.5, 0.82, 0.72
  if danger then r, g, b = 0.9, 0.33, 0.33 end
  self:drawRect(bx, y + 2, bw * v, 8, 0.95, r, g, b)
end
function ClaudeHUD:render()
  if not HUD.visible then return end
  local w, h = self.width, self.height
  self:drawRect(0, 0, w, h, 0.62, 0.04, 0.06, 0.08)
  self:drawRectBorder(0, 0, w, h, 0.7, 0.5, 0.82, 0.72)
  self:drawText("CLAUDE", 12, 8, 0.5, 0.82, 0.72, 1, UIFont.Medium)
  self:drawTextRight(self:statusText(), w - 12, 11, 1, 0.83, 0.28, 1, UIFont.Small)
  self:drawText("ACTION: " .. HUD.action, 12, 32, 0.9, 0.95, 1, 1, UIFont.Small)
  local ty = 52
  for _, line in ipairs(self:wrap(HUD.thought, 58)) do
    if ty > 104 then break end
    self:drawText(line, 12, ty, 0.74, 0.79, 0.85, 1, UIFont.Small); ty = ty + 15
  end
  local by = 116
  self:bar("HP", (HUD.hp or 0) / 100, 12, by, false)
  self:bar("HUN", HUD.hunger, 104, by, true)
  self:bar("THI", HUD.thirst, 196, by, true)
  self:bar("FAT", HUD.fatigue, 288, by, true)
  local zt = (HUD.zDist and HUD.zDist >= 0) and (math.floor(HUD.zDist) .. " " .. HUD.zDir) or "none near"
  self:drawText("Zombies  " .. HUD.zClose .. " close / " .. HUD.zNear .. " near  (" .. zt .. ")", 12, by + 22, 0.9, 0.62, 0.62, 1, UIFont.Small)
  self:drawText("Inv  " .. HUD.foods .. " food, " .. HUD.waters .. " water  |  " .. HUD.weapon, 12, by + 38, 0.7, 0.86, 0.7, 1, UIFont.Small)
  self:drawTextRight("day " .. HUD.day .. "  " .. string.format("%02d", HUD.hour) .. ":00   [H hides]", w - 12, by + 38, 0.55, 0.6, 0.66, 1, UIFont.Small)
end

local hudInstance
local function startHUD()
  if hudInstance then return end
  hudInstance = ClaudeHUD:new()
  hudInstance:initialise()
  hudInstance:addToUIManager()
end
Events.OnGameStart.Add(startHUD)
Events.OnCreatePlayer.Add(function() startHUD() end)
-- human override: pressing a movement/action key hands control to you; the AI stands down
-- and auto-resumes once you've stopped moving for ~10s (see onTick).
local MOVE_KEYS = {
  [Keyboard.KEY_W] = true, [Keyboard.KEY_A] = true, [Keyboard.KEY_S] = true, [Keyboard.KEY_D] = true,
  [Keyboard.KEY_UP] = true, [Keyboard.KEY_DOWN] = true, [Keyboard.KEY_LEFT] = true, [Keyboard.KEY_RIGHT] = true,
  [Keyboard.KEY_E] = true, [Keyboard.KEY_SPACE] = true, [Keyboard.KEY_F] = true, [Keyboard.KEY_R] = true, [Keyboard.KEY_Q] = true,
}
Events.OnKeyPressed.Add(function(key)
  if key == Keyboard.KEY_H then HUD.visible = not HUD.visible; return end
  if key == Keyboard.KEY_G then autoSpeed = not autoSpeed; if not autoSpeed then pcall(function() setGameSpeed(1) end) end; return end
  if MOVE_KEYS[key] then
    lastHumanKeyTick = tick
    if panicUntilTick > 0 then panicUntilTick = -1; pcall(function() setGameSpeed(1) end) end  -- you took over -> unpause
    if not manualMode then
      manualMode = true
      travel.active = false
      pcall(function() ISTimedActionQueue.clear(getSpecificPlayer(0)) end)
    end
  end
end)
