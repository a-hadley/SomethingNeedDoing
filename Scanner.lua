local addonName = ...
local SND = _G[addonName]

local function T(key, ...)
  if SND and SND.Tr then
    return SND:Tr(key, ...)
  end
  if select("#", ...) > 0 then
    return string.format(key, ...)
  end
  return key
end

SND.scanner = {
  lastScan = 0,
  dirty = false,
  lastPublish = 0,
  pendingPublishTimer = nil,
  pendingPublishDueAt = 0,
  activeScanID = nil,
  activeScanRecipesFound = 0,
  activeScanAlertShown = false,
  lastZeroRecipeAlertScanID = nil,
  lastAutoScanKey = nil,
  lastAutoScanAt = 0,
  lastObservedLineKey = nil,
  lastObservedLineName = nil,
  lastObservedSkillLineID = nil,
  lastAutoCraftKey = nil,
  lastAutoCraftAt = 0,
  lastSharedMatsSnapshotCount = 0,
  lastSharedMatsSnapshotTruncated = false,
  lastSharedMatsSnapshotTruncatedCount = 0,
  lastSharedMatsSnapshotTotalCandidates = 0,
  lastSharedMatsTruncationWarnAt = 0,
}

local function debugScan(self, message)
  self:DebugOnlyLog(message)
end

local function countTableEntries(tbl)
  if type(tbl) ~= "table" then
    return 0
  end
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

local function countStoredRecipesForPlayer(playerEntry)
  if type(playerEntry) ~= "table" or type(playerEntry.professions) ~= "table" then
    return 0
  end
  local count = 0
  for _, prof in pairs(playerEntry.professions) do
    if type(prof) == "table" and type(prof.recipes) == "table" then
      count = count + countTableEntries(prof.recipes)
    end
  end
  return count
end

-- Prune local player professions that are no longer valid.
-- Uses GetProfessions()/GetProfessionInfo() to enumerate current professions
-- and removes entries that the player no longer has.
function SND:PruneStaleLocalProfessions()
  local playerKey = self:GetPlayerKey(UnitName("player"))
  if not playerKey then
    return
  end
  local playerEntry = self.db.players[playerKey]
  if not playerEntry or not playerEntry.professions then
    return
  end

  -- Build a set of valid skillLineIDs from the WoW API
  local validSkillLineIDs = {}
  if type(GetProfessions) == "function" then
    local prof1, prof2, arch, fish, cook, firstAid = GetProfessions()
    local indices = { prof1, prof2, arch, fish, cook, firstAid }
    for _, idx in ipairs(indices) do
      if idx then
        local info = { GetProfessionInfo(idx) }
        local skillLineID = info[7] -- 7th return value is skillLine
        if skillLineID then
          validSkillLineIDs[skillLineID] = true
        end
      end
    end
  end

  -- If we couldn't enumerate professions (API unavailable), skip pruning
  if not next(validSkillLineIDs) then
    return
  end

  local pruned = 0
  for profKey, _ in pairs(playerEntry.professions) do
    if type(profKey) == "number" and not validSkillLineIDs[profKey] then
      playerEntry.professions[profKey] = nil
      pruned = pruned + 1
    end
  end

  if pruned > 0 then
    debugScan(self, string.format("Scanner: pruned %d stale profession(s) from local player", pruned))
  end
end

local SCAN_INTERVAL = 60 * 60 * 24
local AUTO_SCAN_DEDUPE_WINDOW_SECONDS = 1
local PUBLISH_COOLDOWN_SECONDS = 3

local function isTradeSkillFrameVisible()
  -- Classic/TBC: GetTradeSkillLine returns the profession name when the window is open
  if type(GetTradeSkillLine) == "function" then
    local ok, line = pcall(GetTradeSkillLine)
    if ok and line and line ~= "" and line ~= "UNKNOWN" then
      return true
    end
  end
  -- Retail fallback
  if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLine then
    local skillLineName = C_TradeSkillUI.GetTradeSkillLine()
    return skillLineName ~= nil and skillLineName ~= ""
  end
  return false
end

local function shouldScan(lastScan)
  if not lastScan or lastScan == 0 then
    return true
  end
  return (SND:Now() - lastScan) > SCAN_INTERVAL
end

local function normalizeProfessionName(name)
  if type(name) ~= "string" then
    return name
  end
  return name:gsub("%s*%([^%)]*%)%s*$", "")
end

local function isUnknownProfessionToken(value)
  return type(value) == "string" and value:upper() == "UNKNOWN"
end

function SND:StartScanRun(trigger)
  if self.scanner.activeScanID then
    debugScan(self, string.format("Scanner: continuing active scan run id=%s trigger=%s", tostring(self.scanner.activeScanID), tostring(trigger)))
    return self.scanner.activeScanID
  end
  self.scanner.activeScanID = (self.scanner.activeScanID or 0) + 1
  self.scanner.activeScanRecipesFound = 0
  self.scanner.activeScanAlertShown = false
  debugScan(self, string.format("Scanner: scan run start id=%s trigger=%s", tostring(self.scanner.activeScanID), tostring(trigger)))
  return self.scanner.activeScanID
end

function SND:RecordScanRecipesFound(foundCount, skillLineID, professionName)
  local count = tonumber(foundCount) or 0
  if not self.scanner.activeScanID then
    return
  end
  self.scanner.activeScanRecipesFound = (self.scanner.activeScanRecipesFound or 0) + math.max(0, count)
  debugScan(self, string.format(
    "Scanner: scan run id=%s recipe tally +%d (total=%d) profession=%s skillLineID=%s",
    tostring(self.scanner.activeScanID),
    math.max(0, count),
    tonumber(self.scanner.activeScanRecipesFound) or 0,
    tostring(professionName),
    tostring(skillLineID)
  ))
end

function SND:ShowZeroRecipesAlert(scanID)
  if not scanID then
    return
  end
  if self.scanner.lastZeroRecipeAlertScanID == scanID then
    return
  end
  self.scanner.lastZeroRecipeAlertScanID = scanID

  local message = T("No recipes were found during the latest profession scan.")
  debugScan(self, string.format("Scanner: zero-recipe alert fired (scan id=%s)", tostring(scanID)))
  self:DebugPrint(T("Scanner: %s", message))

  -- Only show in UI label, no popups
  if self.mainFrame and self.mainFrame.contentFrames then
    local meFrame = self.mainFrame.contentFrames[4]
    if meFrame and meFrame.scanAlertLabel then
      meFrame.scanAlertLabel:SetText(T("Scan Alert: %s", message))
      meFrame.scanAlertLabel:Show()
    end
  end
end

function SND:FinalizeScanRun(reason)
  local scanID = self.scanner.activeScanID
  if not scanID then
    return
  end
  local totalRecipes = tonumber(self.scanner.activeScanRecipesFound) or 0
  debugScan(self, string.format("Scanner: scan run end id=%s reason=%s totalRecipes=%d", tostring(scanID), tostring(reason), totalRecipes))
  -- TODO: re-enable zero-recipe alert when ready
  -- if totalRecipes == 0 and not self.scanner.activeScanAlertShown then
  --   self.scanner.activeScanAlertShown = true
  --   self:ShowZeroRecipesAlert(scanID)
  -- end
  self.scanner.activeScanID = nil
  self.scanner.activeScanRecipesFound = 0
  self.scanner.activeScanAlertShown = false
end

function SND:InitScanner()
  self.scanner.pendingCombatScans = self.scanner.pendingCombatScans or {}

  -- Combat state tracking
  self:RegisterEvent("PLAYER_REGEN_DISABLED", function(selfRef)
    selfRef.scanner.inCombat = true
  end)
  self:RegisterEvent("PLAYER_REGEN_ENABLED", function(selfRef)
    selfRef.scanner.inCombat = false
    -- Process any pending scans after combat
    if #selfRef.scanner.pendingCombatScans > 0 then
      debugScan(selfRef, string.format("Scanner: combat ended, processing %d pending scans", #selfRef.scanner.pendingCombatScans))
      for _, trigger in ipairs(selfRef.scanner.pendingCombatScans) do
        selfRef:ScanProfessions(trigger)
      end
      selfRef.scanner.pendingCombatScans = {}
    end
  end)

  self:RegisterEvent("TRADE_SKILL_SHOW", function(selfRef)
    selfRef:ScanProfessions("event:TRADE_SKILL_SHOW")
  end)
  if self.RegisterBucketEvent then
    self:RegisterBucketEvent("TRADE_SKILL_UPDATE", 0.4, function()
      self:ScanProfessions("bucket:TRADE_SKILL_UPDATE")
    end)
  else
    -- Add a small delay to prevent interfering with profession UI operations
    self:RegisterEvent("TRADE_SKILL_UPDATE", function(selfRef)
      if selfRef.ScheduleTimer then
        selfRef:ScheduleTimer(function()
          selfRef:ScanProfessions("event:TRADE_SKILL_UPDATE")
        end, 0.4)
      else
        selfRef:ScanProfessions("event:TRADE_SKILL_UPDATE")
      end
    end)
  end
  self:RegisterEvent("CRAFT_SHOW", function(selfRef)
    selfRef:ScanCraftProfessions("event:CRAFT_SHOW")
  end)
  if self.RegisterBucketEvent then
    self:RegisterBucketEvent("CRAFT_UPDATE", 0.4, function()
      self:ScanCraftProfessions("bucket:CRAFT_UPDATE")
    end)
  else
    self:RegisterEvent("CRAFT_UPDATE", function(selfRef)
      selfRef:ScanCraftProfessions("event:CRAFT_UPDATE")
    end)
  end
  self:RegisterEvent("CRAFT_CLOSE", function(selfRef)
    selfRef.scanner.lastAutoCraftKey = nil
    selfRef.scanner.lastAutoCraftAt = 0
    debugScan(selfRef, "Scanner: craft close observed; cleared craft dedupe state.")
  end)
  local function handleSkillLinesChanged(selfRef, trigger)
    selfRef.scanner.dirty = true
    local tradeSkillFrameShown = isTradeSkillFrameVisible()
    if tradeSkillFrameShown or selfRef.db.config.autoPublishOnLearn then
      debugScan(selfRef, string.format(
        "Scanner: SKILL_LINES_CHANGED trigger scan tradeSkillFrameShown=%s autoPublishOnLearn=%s",
        tostring(tradeSkillFrameShown),
        tostring(selfRef.db.config.autoPublishOnLearn)
      ))
      selfRef:ScanProfessions(trigger)
    else
      debugScan(selfRef, "Scanner: SKILL_LINES_CHANGED marked dirty only; frame closed and autoPublishOnLearn disabled.")
    end
  end
  if self.RegisterBucketEvent then
    self:RegisterBucketEvent("SKILL_LINES_CHANGED", 0.5, function()
      handleSkillLinesChanged(self, "bucket:SKILL_LINES_CHANGED")
    end)
  else
    self:RegisterEvent("SKILL_LINES_CHANGED", function(selfRef)
      handleSkillLinesChanged(selfRef, "event:SKILL_LINES_CHANGED")
    end)
  end
  self:RegisterEvent("PLAYER_LOGIN", function(selfRef)
    selfRef:MaybeAutoScanAndPublish()
  end)
end

function SND:MaybeAutoScanAndPublish()
  if not self.db or not self.db.config then
    return
  end

  if not (self.db.config.autoPublishOnLogin or self.db.config.autoPublishOnLearn) then
    debugScan(self, "Scanner: auto publish disabled; skipping scan.")
    return
  end

  local playerKey = self:GetPlayerKey(UnitName("player"))
  local playerEntry = playerKey and self.db.players[playerKey]
  local hasProfessions = playerEntry and playerEntry.professions and next(playerEntry.professions)
  if shouldScan(self.scanner.lastScan) or self.scanner.dirty or not hasProfessions then
    debugScan(self, "Scanner: triggering scan (interval/dirty/missing professions).")
    self:ScanProfessions("auto:MaybeAutoScanAndPublish")
  else
    debugScan(self, "Scanner: skipping scan; publishing cached data.")
    self:DebouncedPublish()
    self:PublishSharedMats()
  end
end

function SND:ScanProfessions(trigger)
  -- Combat protection: queue scans during combat
  if InCombatLockdown() then
    self.scanner.inCombat = true
    if not self.scanner.pendingCombatScans then
      self.scanner.pendingCombatScans = {}
    end
    -- Only queue if not already pending
    local alreadyPending = false
    for _, pendingTrigger in ipairs(self.scanner.pendingCombatScans) do
      if pendingTrigger == trigger then
        alreadyPending = true
        break
      end
    end
    if not alreadyPending then
      table.insert(self.scanner.pendingCombatScans, trigger or "manual:scan")
      debugScan(self, string.format("Scanner: scan queued during combat trigger=%s", tostring(trigger or "manual:scan")))
    end
    return
  end

  local scanTrigger = trigger or "manual:scan"
  local hasGetTradeSkillLine = type(GetTradeSkillLine) == "function"
  local tradeSkillLine = nil
  local tradeSkillRank = nil
  local tradeSkillMaxRank = nil
  if hasGetTradeSkillLine then
    local ok, line, rank, maxRank = pcall(GetTradeSkillLine)
    if ok then
      tradeSkillLine = line
      tradeSkillRank = rank
      tradeSkillMaxRank = maxRank
    end
  end
  local tradeSkillFrameShown = isTradeSkillFrameVisible()

  local skillLineIDByName = {
    ["Alchemy"] = 171,
    ["Blacksmithing"] = 164,
    ["Cooking"] = 185,
    ["Enchanting"] = 333,
    ["Engineering"] = 202,
    ["First Aid"] = 129,
    ["Fishing"] = 356,
    ["Herbalism"] = 182,
    ["Jewelcrafting"] = 755,
    ["Leatherworking"] = 165,
    ["Mining"] = 186,
    ["Skinning"] = 393,
    ["Tailoring"] = 197,
  }
  local gathering = {
    ["Mining"] = true,
    ["Herbalism"] = true,
    ["Skinning"] = true,
  }
  local crafting = {
    ["Alchemy"] = true,
    ["Blacksmithing"] = true,
    ["Cooking"] = true,
    ["Enchanting"] = true,
    ["Engineering"] = true,
    ["First Aid"] = true,
    ["Jewelcrafting"] = true,
    ["Leatherworking"] = true,
    ["Tailoring"] = true,
  }
  local trimmedTradeSkillLine = normalizeProfessionName(tradeSkillLine)
  local hasUsableTradeSkillLine = trimmedTradeSkillLine and not isUnknownProfessionToken(trimmedTradeSkillLine)
  local currentSkillLineID = skillLineIDByName[trimmedTradeSkillLine]
  local currentLineKey = tostring(currentSkillLineID or trimmedTradeSkillLine or "none")
  if self.scanner.lastObservedLineKey ~= currentLineKey then
    debugScan(self, string.format(
      "Scanner: line change trigger=%s previousLine=%s(previousSkillLineID=%s) currentLine=%s(currentSkillLineID=%s)",
      tostring(scanTrigger),
      tostring(self.scanner.lastObservedLineName),
      tostring(self.scanner.lastObservedSkillLineID),
      tostring(trimmedTradeSkillLine),
      tostring(currentSkillLineID)
    ))
    self.scanner.lastObservedLineKey = currentLineKey
    self.scanner.lastObservedLineName = trimmedTradeSkillLine
    self.scanner.lastObservedSkillLineID = currentSkillLineID
  end

  debugScan(self, string.format(
    "Scanner: open-profession scan trigger=%s TradeSkillFrameShown=%s TradeSkillLine=%s",
    tostring(scanTrigger),
    tostring(tradeSkillFrameShown),
    tostring(tradeSkillLine)
  ))

  if not tradeSkillFrameShown then
    if scanTrigger == "manual:scan" then
      debugScan(self, "Scanner: manual scan skipped; open a profession window to scan.")
      self:DebugPrint(T("Scanner: open a profession window to scan."))
    else
      debugScan(self, string.format("Scanner: skip trigger=%s; trade skill frame is closed.", tostring(scanTrigger)))
    end
    return
  end

  if not hasUsableTradeSkillLine then
    debugScan(self, string.format("Scanner: skip trigger=%s; trade skill line is unknown/invalid (%s).", tostring(scanTrigger), tostring(tradeSkillLine)))
    return
  end

  if gathering[trimmedTradeSkillLine] then
    debugScan(self, string.format("Scanner: skip trigger=%s; gathering profession is excluded (%s).", tostring(scanTrigger), tostring(trimmedTradeSkillLine)))
    return
  end

  if not crafting[trimmedTradeSkillLine] then
    debugScan(self, string.format("Scanner: skip trigger=%s; non-crafting trade skill line (%s).", tostring(scanTrigger), tostring(trimmedTradeSkillLine)))
    return
  end

  if string.find(scanTrigger, "^event:TRADE_SKILL_") or string.find(scanTrigger, "^bucket:TRADE_SKILL_") then
    debugScan(self, string.format(
      "Scanner: auto-scan trigger=%s currentLine=%s skillLineID=%s",
      tostring(scanTrigger),
      tostring(trimmedTradeSkillLine),
      tostring(currentSkillLineID)
    ))

    local now = self:Now()
    local lastLineKey = self.scanner.lastAutoScanKey
    local lastScanAt = tonumber(self.scanner.lastAutoScanAt) or 0
    local isTradeSkillUpdate = scanTrigger == "event:TRADE_SKILL_UPDATE" or scanTrigger == "bucket:TRADE_SKILL_UPDATE"
    if isTradeSkillUpdate and lastLineKey == currentLineKey and (now - lastScanAt) < AUTO_SCAN_DEDUPE_WINDOW_SECONDS then
      debugScan(self, string.format(
        "Scanner: auto-scan skipped trigger=%s currentLine=%s skillLineID=%s reason=dedupe-window",
        tostring(scanTrigger),
        tostring(trimmedTradeSkillLine),
        tostring(currentSkillLineID)
      ))
      return
    end
    self.scanner.lastAutoScanKey = currentLineKey
    self.scanner.lastAutoScanAt = now
  end

  self:StartScanRun(scanTrigger)

  local playerName, playerRealm = UnitName("player")
  local playerKey = self:GetPlayerKey(playerName, playerRealm)
  local playerEntry = self.db.players[playerKey] or {}

  playerEntry.name = playerName
  playerEntry.lastSeen = self:Now()
  playerEntry.online = true
  playerEntry.professions = playerEntry.professions or {}

  local profKey = currentSkillLineID or trimmedTradeSkillLine
  local profEntry = playerEntry.professions[profKey] or {}
  profEntry.name = tradeSkillLine
  if tradeSkillRank ~= nil then
    profEntry.rank = tradeSkillRank
  elseif profEntry.rank == nil then
    profEntry.rank = 0
  end
  if tradeSkillMaxRank ~= nil then
    profEntry.maxRank = tradeSkillMaxRank
  elseif profEntry.maxRank == nil then
    profEntry.maxRank = 0
  end
  -- Clear recipes before scanning so unlearned recipes don't persist.
  -- The scan is the authoritative source for the local player's recipes.
  profEntry.recipes = {}

  local foundCount
  if C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillReady and currentSkillLineID then
    local ready = C_TradeSkillUI.IsTradeSkillReady(currentSkillLineID)
    debugScan(self, string.format("Scanner: trade skill ready=%s for %s skillLineID=%s", tostring(ready), tostring(tradeSkillLine), tostring(currentSkillLineID)))
    if ready then
      foundCount = self:ScanRecipesForSkillLine(currentSkillLineID, profEntry)
    else
      debugScan(self, string.format("Scanner: skip scan trigger=%s; trade skill not ready for %s skillLineID=%s.", tostring(scanTrigger), tostring(tradeSkillLine), tostring(currentSkillLineID)))
      self.scanner.activeScanID = nil
      self.scanner.activeScanRecipesFound = 0
      self.scanner.activeScanAlertShown = false
      return
    end
  else
    foundCount = self:ScanRecipesForSkillLine(currentSkillLineID, profEntry)
  end

  self:RecordScanRecipesFound(foundCount, currentSkillLineID, tradeSkillLine)
  debugScan(self, string.format("Scanner: profession recipe count name=%s skillLineID=%s foundCount=%d", tostring(tradeSkillLine), tostring(currentSkillLineID), tonumber(foundCount) or 0))
  playerEntry.professions[profKey] = profEntry

  self.db.players[playerKey] = playerEntry
  debugScan(self, string.format(
    "Scanner: store transition player=%s professions=%d storedRecipes=%d scanTally=%d",
    tostring(playerKey),
    countTableEntries(playerEntry.professions),
    countStoredRecipesForPlayer(playerEntry),
    tonumber(self.scanner.activeScanRecipesFound) or 0
  ))
  -- Prune professions the local player no longer has (e.g., dropped a profession)
  self:PruneStaleLocalProfessions()

  local isFirstScan = (tonumber(self.scanner.lastPublish) or 0) == 0
  self.scanner.lastScan = self:Now()
  self.scanner.dirty = false
  self:DebouncedPublish()
  self:PublishSharedMats()
  self:FinalizeScanRun("scan-complete-current-open-profession")

  -- After first scan, schedule a quick full-state broadcast so the guild gets
  -- the newly scanned data without waiting for the next sync ticker.
  if isFirstScan and type(self.BroadcastFullState) == "function" then
    self.comms.lastFullSyncAt = 0
    self:ScheduleSNDTimer(2, function()
      self:BroadcastFullState("first-scan")
    end)
  end

  if self.mainFrame and self.mainFrame.contentFrames then
    local directoryFrame = self.mainFrame.contentFrames[1]
    if directoryFrame and directoryFrame.listButtons then
      local query = directoryFrame.searchBox and directoryFrame.searchBox:GetText() or ""
      self:UpdateDirectoryResults(query)
    end
  end
end

function SND:OpenNextQueuedProfession()
  debugScan(self, "Scanner: OpenNextQueuedProfession bypassed; queue-driven opening disabled.")
  return false
end

function SND:ScanCraftProfessions(trigger)
  -- Combat protection: queue scans during combat
  if InCombatLockdown() then
    self.scanner.inCombat = true
    if not self.scanner.pendingCombatScans then
      self.scanner.pendingCombatScans = {}
    end
    local alreadyPending = false
    for _, pendingTrigger in ipairs(self.scanner.pendingCombatScans) do
      if pendingTrigger == trigger then
        alreadyPending = true
        break
      end
    end
    if not alreadyPending then
      table.insert(self.scanner.pendingCombatScans, trigger or "event:CRAFT_SHOW")
      debugScan(self, string.format("Scanner: craft scan queued during combat trigger=%s", tostring(trigger or "event:CRAFT_SHOW")))
    end
    return
  end

  local scanTrigger = trigger or "event:CRAFT_SHOW"
  if type(GetCraftDisplaySkillLine) ~= "function" then
    debugScan(self, string.format("Scanner: skip trigger=%s; craft display skill API unavailable.", tostring(scanTrigger)))
    return
  end

  local ok, craftLine, craftRank, craftMaxRank = pcall(GetCraftDisplaySkillLine)
  if not ok then
    debugScan(self, string.format("Scanner: skip trigger=%s; GetCraftDisplaySkillLine failed.", tostring(scanTrigger)))
    return
  end

  local skillLineIDByName = {
    ["Cooking"] = 185,
    ["Enchanting"] = 333,
    ["First Aid"] = 129,
  }
  local crafting = {
    ["Cooking"] = true,
    ["Enchanting"] = true,
    ["First Aid"] = true,
  }
  local trimmedCraftLine = normalizeProfessionName(craftLine)
  local hasUsableCraftLine = trimmedCraftLine and not isUnknownProfessionToken(trimmedCraftLine)
  local currentSkillLineID = skillLineIDByName[trimmedCraftLine]
  local currentLineKey = tostring(currentSkillLineID or trimmedCraftLine or "none")

  if not hasUsableCraftLine then
    debugScan(self, string.format("Scanner: skip trigger=%s; craft line unknown/invalid (%s).", tostring(scanTrigger), tostring(craftLine)))
    return
  end

  if not crafting[trimmedCraftLine] then
    debugScan(self, string.format("Scanner: skip trigger=%s; non-crafting craft line (%s).", tostring(scanTrigger), tostring(trimmedCraftLine)))
    return
  end

  if scanTrigger == "event:CRAFT_UPDATE" or scanTrigger == "bucket:CRAFT_UPDATE" then
    local now = self:Now()
    local lastLineKey = self.scanner.lastAutoCraftKey
    local lastScanAt = tonumber(self.scanner.lastAutoCraftAt) or 0
    if lastLineKey == currentLineKey and (now - lastScanAt) < AUTO_SCAN_DEDUPE_WINDOW_SECONDS then
      debugScan(self, string.format(
        "Scanner: craft auto-scan skipped trigger=%s currentLine=%s skillLineID=%s reason=dedupe-window",
        tostring(scanTrigger),
        tostring(trimmedCraftLine),
        tostring(currentSkillLineID)
      ))
      return
    end
    self.scanner.lastAutoCraftKey = currentLineKey
    self.scanner.lastAutoCraftAt = now
  elseif scanTrigger == "event:CRAFT_SHOW" or scanTrigger == "bucket:CRAFT_SHOW" then
    self.scanner.lastAutoCraftKey = currentLineKey
    self.scanner.lastAutoCraftAt = self:Now()
  end

  self:StartScanRun(scanTrigger)

  local playerName, playerRealm = UnitName("player")
  local playerKey = self:GetPlayerKey(playerName, playerRealm)
  local playerEntry = self.db.players[playerKey] or {}

  playerEntry.name = playerName
  playerEntry.lastSeen = self:Now()
  playerEntry.online = true
  playerEntry.professions = playerEntry.professions or {}

  local profKey = currentSkillLineID or trimmedCraftLine
  local profEntry = playerEntry.professions[profKey] or {}
  profEntry.name = craftLine
  if craftRank ~= nil then
    profEntry.rank = craftRank
  elseif profEntry.rank == nil then
    profEntry.rank = 0
  end
  if craftMaxRank ~= nil then
    profEntry.maxRank = craftMaxRank
  elseif profEntry.maxRank == nil then
    profEntry.maxRank = 0
  end
  -- Clear recipes before scanning so unlearned recipes don't persist.
  profEntry.recipes = {}

  local foundCount = self:ScanCraftRecipesForSkillLine(currentSkillLineID, profEntry, trimmedCraftLine)

  self:RecordScanRecipesFound(foundCount, currentSkillLineID, craftLine)
  debugScan(self, string.format("Scanner: profession recipe count name=%s skillLineID=%s foundCount=%d", tostring(craftLine), tostring(currentSkillLineID), tonumber(foundCount) or 0))
  playerEntry.professions[profKey] = profEntry

  self.db.players[playerKey] = playerEntry
  debugScan(self, string.format(
    "Scanner: store transition player=%s professions=%d storedRecipes=%d scanTally=%d",
    tostring(playerKey),
    countTableEntries(playerEntry.professions),
    countStoredRecipesForPlayer(playerEntry),
    tonumber(self.scanner.activeScanRecipesFound) or 0
  ))
  self.scanner.lastScan = self:Now()
  self.scanner.dirty = false
  self:DebouncedPublish()
  self:PublishSharedMats()
  self:FinalizeScanRun("scan-complete-current-open-craft-profession")

  if self.mainFrame and self.mainFrame.contentFrames then
    local directoryFrame = self.mainFrame.contentFrames[1]
    if directoryFrame and directoryFrame.listButtons then
      local query = directoryFrame.searchBox and directoryFrame.searchBox:GetText() or ""
      self:UpdateDirectoryResults(query)
    end
  end
end

function SND:CloseTradeSkillWindow()
  if C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill then
    C_TradeSkillUI.CloseTradeSkill()
    return
  end
  if CloseTradeSkill then
    CloseTradeSkill()
  end
end

function SND:ScanRecipesForSkillLine(skillLineID, profEntry)
  if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs(skillLineID)
    if recipeIDs then
      local totalCount = countTableEntries(recipeIDs)
      debugScan(self, string.format("Scanner: recipe scan start skillLineID=%s (arrayCount=%d totalCount=%d)", tostring(skillLineID), #recipeIDs, totalCount))

      -- Phase 1: Collect recipe metadata
      local recipeMetadata = {}
      local foundCount = 0
      for _, recipeSpellID in pairs(recipeIDs) do
        if type(recipeSpellID) == "number" then
          profEntry.recipes[recipeSpellID] = true

          -- Collect schematic data for modern recipes
          local schematic = nil
          if C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
            schematic = C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, false)
          end

          recipeMetadata[recipeSpellID] = {
            schematic = schematic,
            skillLineID = skillLineID
          }

          foundCount = foundCount + 1
        end
      end

      -- Phase 2: Extract reagents and output items
      local itemsToWarm = {}
      for recipeSpellID, metadata in pairs(recipeMetadata) do
        local reagents = nil
        local outputItemID = nil

        if metadata.schematic then
          -- Extract reagents
          if metadata.schematic.reagentSlotSchematics then
            reagents = {}
            for _, slot in ipairs(metadata.schematic.reagentSlotSchematics) do
              if slot.reagents then
                for _, reagent in ipairs(slot.reagents) do
                  if reagent.itemID then
                    reagents[reagent.itemID] = (reagents[reagent.itemID] or 0) + (reagent.quantityRequired or 1)
                    table.insert(itemsToWarm, reagent.itemID)
                  end
                end
              end
            end
            if not next(reagents) then
              reagents = nil
            end
          end

          -- Extract output item
          outputItemID = metadata.schematic.outputItemID
          if outputItemID then
            table.insert(itemsToWarm, outputItemID)
          end
        end

        -- Store in recipeIndex with reagent data
        self:EnsureRecipeIndexEntry(
          recipeSpellID,
          metadata.skillLineID,
          outputItemID,
          { reagents = reagents }  -- Pass as modernMeta
        )
      end

      -- Phase 3: Warm item cache for all collected items
      if #itemsToWarm > 0 then
        self:WarmItemCache(itemsToWarm, nil, function()
          -- Callback when items loaded - trigger UI refresh
          self:RefreshUIAfterCacheWarm()
        end)
        debugScan(self, string.format("Scanner: queued %d items for cache warming", #itemsToWarm))
      end

      debugScan(self, string.format("Scanner: recipe scan end skillLineID=%s (foundCount=%d)", tostring(skillLineID), foundCount))
      return foundCount
    end
    debugScan(self, string.format("Scanner: no recipes returned for skillLineID=%s (C_TradeSkillUI); falling back to classic scan.", tostring(skillLineID)))
  end

  if type(GetNumTradeSkills) ~= "function" then
    debugScan(self, "Scanner: trade skill recipe APIs unavailable; cannot scan recipes.")
    return 0
  end

  local function parseSpellIDFromLink(link)
    if type(link) ~= "string" then
      return nil
    end
    return tonumber(link:match("spell:(%d+)")) or tonumber(link:match("enchant:(%d+)"))
  end

  local function parseItemIDFromLink(link)
    if type(link) ~= "string" then
      return nil
    end
    return tonumber(link:match("item:(%d+)"))
  end

  local function isClassicRecipeRowType(skillType)
    return skillType == "optimal"
      or skillType == "medium"
      or skillType == "easy"
      or skillType == "trivial"
      or skillType == "available"
  end

  local function normalizeRecipeKeyPart(value)
    local normalized = tostring(value or "")
    normalized = normalized:lower()
    normalized = normalized:gsub("[%c%s]+", " ")
    normalized = normalized:gsub("^%s+", "")
    normalized = normalized:gsub("%s+$", "")
    return normalized
  end

  local function buildClassicFallbackRecipeKey(skillLine, professionName, rowName, rowIndex)
    local professionPart = skillLine and tostring(skillLine) or normalizeRecipeKeyPart(professionName)
    local rowNamePart = normalizeRecipeKeyPart(rowName)
    local indexPart = tonumber(rowIndex) or 0
    return string.format("classic:%s:%s:%d", tostring(professionPart), tostring(rowNamePart), indexPart)
  end

  local function collectClassicReagents(index)
    local reagents = {}
    local numReagents = GetTradeSkillNumReagents and GetTradeSkillNumReagents(index) or 0
    for reagentIndex = 1, (tonumber(numReagents) or 0) do
      local reagentCount = nil
      if GetTradeSkillReagentInfo then
        local _, _, requiredCount = GetTradeSkillReagentInfo(index, reagentIndex)
        reagentCount = tonumber(requiredCount) or 0
      end
      local reagentLink = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(index, reagentIndex) or nil
      local reagentItemID = parseItemIDFromLink(reagentLink)
      if reagentItemID and reagentCount and reagentCount > 0 then
        reagents[reagentItemID] = (reagents[reagentItemID] or 0) + reagentCount
      end
    end
    if next(reagents) then
      return reagents
    end
    return nil
  end

  if type(GetTradeSkillInfo) == "function" and type(ExpandTradeSkillSubClass) == "function" then
    local preExpandCount = GetNumTradeSkills() or 0
    for idx = 1, preExpandCount do
      local _, rowType, _, isExpanded = GetTradeSkillInfo(idx)
      if rowType == "header" and not isExpanded then
        ExpandTradeSkillSubClass(idx)
      end
    end
  end

  local numSkills = GetNumTradeSkills()
  debugScan(self, string.format("Scanner: classic recipe scan start skillLineID=%s numSkills=%d", tostring(skillLineID), numSkills or 0))
  local foundCount = 0
  local recipeRowsSeen = 0
  local skippedByType = 0
  local rowsMissingLinks = 0
  local capturedBySpellID = 0
  local capturedByFallbackKey = 0
  local skipLogCount = 0
  local maxSkipLogs = 5
  local rowDiagLogCount = 0
  local maxRowDiagLogs = 20

  for index = 1, (numSkills or 0) do
    local rowName, rowType = nil, nil
    if type(GetTradeSkillInfo) == "function" then
      rowName, rowType = GetTradeSkillInfo(index)
    end

    if rowType and not isClassicRecipeRowType(rowType) then
      skippedByType = skippedByType + 1
      if skipLogCount < maxSkipLogs then
        skipLogCount = skipLogCount + 1
        debugScan(self, string.format("Scanner: classic skip row index=%d type=%s name=%s", index, tostring(rowType), tostring(rowName)))
      end
    else
      recipeRowsSeen = recipeRowsSeen + 1
      local recipeLink = GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index) or nil
      local recipeSpellID = parseSpellIDFromLink(recipeLink)
      local outputLink = GetTradeSkillItemLink and GetTradeSkillItemLink(index) or nil
      local outputItemID = parseItemIDFromLink(outputLink)
      local numReagents = GetTradeSkillNumReagents and GetTradeSkillNumReagents(index) or nil
      local tools = GetTradeSkillTools and GetTradeSkillTools(index) or nil
      local reagents = collectClassicReagents(index)
      local recipeKey = recipeSpellID
      local fallbackKey = nil

      if not recipeLink and not outputLink then
        rowsMissingLinks = rowsMissingLinks + 1
      end

      if not recipeKey then
        fallbackKey = buildClassicFallbackRecipeKey(skillLineID, profEntry and profEntry.name, rowName, index)
        recipeKey = fallbackKey
      end

      if rowDiagLogCount < maxRowDiagLogs then
        local reagentSummaries = {}
        local reagentCountToLog = math.min(tonumber(numReagents) or 0, 3)
        for reagentIndex = 1, reagentCountToLog do
          local reagentName, _, reagentRequiredCount = nil, nil, nil
          if GetTradeSkillReagentInfo then
            reagentName, _, reagentRequiredCount = GetTradeSkillReagentInfo(index, reagentIndex)
          end
          local reagentLink = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(index, reagentIndex) or nil
          local reagentItemID = parseItemIDFromLink(reagentLink)
          table.insert(reagentSummaries, string.format("%s x%s itemID=%s", tostring(reagentName), tostring(reagentRequiredCount), tostring(reagentItemID)))
        end

        rowDiagLogCount = rowDiagLogCount + 1
        debugScan(self, string.format(
          "Scanner: classic row diag skillLineID=%s idx=%d name=%s type=%s recipeLink=%s parsedSpellID=%s fallbackKey=%s outputLink=%s outputItemID=%s numReagents=%s reagents=[%s] tools=%s",
          tostring(skillLineID),
          index,
          tostring(rowName),
          tostring(rowType),
          tostring(recipeLink),
          tostring(recipeSpellID),
          tostring(fallbackKey),
          tostring(outputLink),
          tostring(outputItemID),
          tostring(numReagents),
          table.concat(reagentSummaries, "; "),
          tostring(tools)
        ))
      end

      if recipeKey then
        profEntry.recipes[recipeKey] = true
        self:EnsureRecipeIndexEntry(recipeKey, skillLineID, outputItemID, {
          name = rowName,
          reagents = reagents,
          tools = tools,
          rowIndex = index,
          classicFallback = fallbackKey ~= nil,
        })
        if fallbackKey then
          capturedByFallbackKey = capturedByFallbackKey + 1
        else
          capturedBySpellID = capturedBySpellID + 1
        end
        foundCount = foundCount + 1
      end
    end
  end

  if skippedByType > maxSkipLogs then
    debugScan(self, string.format("Scanner: classic skip row logs suppressed=%d", skippedByType - maxSkipLogs))
  end

  debugScan(self, string.format(
    "Scanner: classic recipe scan end skillLineID=%s recipeRowsSeen=%d captured=%d capturedBySpellID=%d capturedByFallbackKey=%d rowsMissingLinks=%d skippedByType=%d rowDiagLogs=%d",
    tostring(skillLineID),
    recipeRowsSeen,
    foundCount,
    capturedBySpellID,
    capturedByFallbackKey,
    rowsMissingLinks,
    skippedByType,
    rowDiagLogCount
  ))
  return foundCount
end

function SND:ScanCraftRecipesForSkillLine(skillLineID, profEntry, professionName)
  if type(GetNumCrafts) ~= "function" or type(GetCraftInfo) ~= "function" then
    debugScan(self, "Scanner: craft recipe APIs unavailable; cannot scan craft recipes.")
    return 0
  end

  local function parseSpellIDFromLink(link)
    if type(link) ~= "string" then
      return nil
    end
    return tonumber(link:match("spell:(%d+)")) or tonumber(link:match("enchant:(%d+)"))
  end

  local function parseItemIDFromLink(link)
    if type(link) ~= "string" then
      return nil
    end
    return tonumber(link:match("item:(%d+)"))
  end

  local function isCraftRecipeRowType(craftType)
    return craftType == "optimal"
      or craftType == "medium"
      or craftType == "easy"
      or craftType == "trivial"
      or craftType == "available"
  end

  local function normalizeRecipeKeyPart(value)
    local normalized = tostring(value or "")
    normalized = normalized:lower()
    normalized = normalized:gsub("[%c%s]+", " ")
    normalized = normalized:gsub("^%s+", "")
    normalized = normalized:gsub("%s+$", "")
    return normalized
  end

  local function buildCraftFallbackRecipeKey(skillLine, profession, rowName, subSpellName, rowIndex)
    local professionPart = skillLine and tostring(skillLine) or normalizeRecipeKeyPart(profession)
    local rowNamePart = normalizeRecipeKeyPart(rowName)
    local subSpellPart = normalizeRecipeKeyPart(subSpellName)
    local indexPart = tonumber(rowIndex) or 0
    return string.format("craft:%s:%s:%s:%d", tostring(professionPart), tostring(rowNamePart), tostring(subSpellPart), indexPart)
  end

  local function collectCraftReagents(index)
    local reagents = {}
    if type(GetCraftReagentInfo) ~= "function" then
      return nil
    end
    local reagentIndex = 1
    while true do
      local reagentName, _, requiredCount = GetCraftReagentInfo(index, reagentIndex)
      if not reagentName then
        break
      end
      local reagentCount = tonumber(requiredCount) or 0
      local reagentLink = GetCraftReagentItemLink and GetCraftReagentItemLink(index, reagentIndex) or nil
      local reagentItemID = parseItemIDFromLink(reagentLink)
      if reagentItemID and reagentCount > 0 then
        reagents[reagentItemID] = (reagents[reagentItemID] or 0) + reagentCount
      end
      reagentIndex = reagentIndex + 1
    end
    if next(reagents) then
      return reagents
    end
    return nil
  end

  local numCrafts = GetNumCrafts() or 0
  debugScan(self, string.format("Scanner: craft scan start skillLineID=%s profession=%s numCrafts=%d", tostring(skillLineID), tostring(professionName), tonumber(numCrafts) or 0))

  local foundCount = 0
  local rowsSeen = 0
  local skippedByType = 0
  local rowsMissingLinks = 0
  local capturedBySpellID = 0
  local capturedByFallbackKey = 0

  for index = 1, numCrafts do
    local rowName, subSpellName, rowType = GetCraftInfo(index)
    if rowType and not isCraftRecipeRowType(rowType) then
      skippedByType = skippedByType + 1
    else
      rowsSeen = rowsSeen + 1
      local recipeLink = GetCraftItemLink and GetCraftItemLink(index) or nil
      local recipeSpellID = parseSpellIDFromLink(recipeLink)
      local outputItemID = parseItemIDFromLink(recipeLink)
      local reagents = collectCraftReagents(index)
      local spellFocus = GetCraftSpellFocus and GetCraftSpellFocus(index) or nil
      local recipeKey = recipeSpellID
      local fallbackKey = nil

      if not recipeLink then
        rowsMissingLinks = rowsMissingLinks + 1
      end

      if not recipeKey then
        fallbackKey = buildCraftFallbackRecipeKey(skillLineID, professionName, rowName, subSpellName, index)
        recipeKey = fallbackKey
      end

      profEntry.recipes[recipeKey] = true
      self:EnsureRecipeIndexEntry(recipeKey, skillLineID, outputItemID, {
        name = rowName or subSpellName,
        reagents = reagents,
        tools = spellFocus,
        rowIndex = index,
        classicFallback = fallbackKey ~= nil,
      })
      if fallbackKey then
        capturedByFallbackKey = capturedByFallbackKey + 1
      else
        capturedBySpellID = capturedBySpellID + 1
      end
      foundCount = foundCount + 1
    end
  end

  debugScan(self, string.format(
    "Scanner: craft recipe scan end skillLineID=%s profession=%s rowsSeen=%d captured=%d capturedBySpellID=%d capturedByFallbackKey=%d rowsMissingLinks=%d skippedByType=%d",
    tostring(skillLineID),
    tostring(professionName),
    rowsSeen,
    foundCount,
    capturedBySpellID,
    capturedByFallbackKey,
    rowsMissingLinks,
    skippedByType
  ))

  return foundCount
end

function SND:EnsureRecipeIndexEntry(recipeSpellID, skillLineID, outputItemID, metaData)
  if recipeSpellID == nil then
    return
  end

  local now = self:Now()
  local updatedBy = self:GetPlayerKey(UnitName("player"))

  local entry = self.db.recipeIndex[recipeSpellID]
  if entry then
    local changed = false
    if not entry.professionSkillLineID and skillLineID then
      entry.professionSkillLineID = skillLineID
      changed = true
      debugScan(self, string.format("Scanner: recipeIndex update recipeSpellID=%s set professionSkillLineID=%s", tostring(recipeSpellID), tostring(skillLineID)))
    end
    if not entry.outputItemID and outputItemID then
      entry.outputItemID = outputItemID
      changed = true
      debugScan(self, string.format("Scanner: recipeIndex update recipeSpellID=%s set outputItemID=%s", tostring(recipeSpellID), tostring(outputItemID)))
    end
    -- Add support for reagents from modern recipes
    if not entry.reagents and type(metaData) == "table" and metaData.reagents then
      entry.reagents = metaData.reagents
      changed = true
      debugScan(self, string.format("Scanner: recipeIndex update recipeSpellID=%s set reagents", tostring(recipeSpellID)))
    end
    if type(metaData) == "table" then
      if not entry.name and metaData.name then
        entry.name = metaData.name
        changed = true
      end
      if not entry.tools and metaData.tools then
        entry.tools = metaData.tools
        changed = true
      end
      if not entry.rowIndex and metaData.rowIndex then
        entry.rowIndex = metaData.rowIndex
        changed = true
      end
      if metaData.classicFallback and not entry.classicFallback then
        entry.classicFallback = true
        changed = true
      end
    end
    if entry.entityType ~= "RECIPE" then
      entry.entityType = "RECIPE"
      changed = true
    end
    local expectedID = tostring(recipeSpellID)
    if not entry.id then
      entry.id = expectedID
      changed = true
    end

    if changed then
      entry.version = (tonumber(entry.version) or 1) + 1
      entry.updatedAtServer = now
      entry.updatedBy = updatedBy
      entry.lastUpdated = now
      if type(self.MarkDirty) == "function" then
        self:MarkDirty("recipeIndex", recipeSpellID)
      end
      debugScan(self, string.format("Scanner: recipeIndex exists recipeSpellID=%s changed=true", tostring(recipeSpellID)))
    else
      debugScan(self, string.format("Scanner: recipeIndex exists recipeSpellID=%s changed=false", tostring(recipeSpellID)))
    end
    return
  end

  local info = nil
  if type(recipeSpellID) == "number" and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
    info = C_TradeSkillUI.GetRecipeInfo(recipeSpellID)
  end

  -- Support both classic and modern reagent data
  local metaName = type(metaData) == "table" and metaData.name or nil
  local metaReagents = type(metaData) == "table" and metaData.reagents or nil
  local metaTools = type(metaData) == "table" and metaData.tools or nil
  local metaRowIndex = type(metaData) == "table" and metaData.rowIndex or nil
  local metaFallback = type(metaData) == "table" and metaData.classicFallback or false
  local fallbackName = metaName
  if not fallbackName then
    fallbackName = "Recipe " .. tostring(recipeSpellID)
  end

  self.db.recipeIndex[recipeSpellID] = {
    id = tostring(recipeSpellID),
    entityType = "RECIPE",
    name = (info and info.name) or fallbackName,
    professionSkillLineID = skillLineID,
    outputItemID = outputItemID,
    reagents = metaReagents,  -- Now includes modern recipe reagents
    tools = metaTools,
    rowIndex = metaRowIndex,
    classicFallback = metaFallback and true or nil,

    -- NEW: Track item data status
    itemDataStatus = outputItemID and "pending" or nil,
    itemName = nil,  -- Filled by GET_ITEM_INFO_RECEIVED
    itemIcon = nil,  -- Filled by GET_ITEM_INFO_RECEIVED

    version = 1,
    updatedAtServer = now,
    updatedBy = updatedBy,
    lastUpdated = now,
  }
  if type(self.MarkDirty) == "function" then
    self:MarkDirty("recipeIndex", recipeSpellID)
  end
  debugScan(self, string.format("Scanner: recipeIndex create recipeSpellID=%s name=%s professionSkillLineID=%s", tostring(recipeSpellID), tostring(self.db.recipeIndex[recipeSpellID].name), tostring(skillLineID)))
end

function SND:DebouncedPublish()
  local now = self:Now()
  local lastPublish = tonumber(self.scanner.lastPublish) or 0
  local elapsed = now - lastPublish
  if elapsed < PUBLISH_COOLDOWN_SECONDS then
    local dueAt = lastPublish + PUBLISH_COOLDOWN_SECONDS
    if not self.scanner.pendingPublishTimer then
      local delaySeconds = math.max(0.01, dueAt - now)
      self.scanner.pendingPublishDueAt = dueAt
      self.scanner.pendingPublishTimer = self:ScheduleSNDTimer(delaySeconds, function()
        self.scanner.pendingPublishTimer = nil
        self.scanner.pendingPublishDueAt = 0
        self:DebouncedPublish()
      end)
      debugScan(self, string.format("Publish: cooldown active; scheduled trailing publish in %.2fs", delaySeconds))
    else
      debugScan(self, string.format("Publish: cooldown active; trailing publish already scheduled for %s", tostring(self.scanner.pendingPublishDueAt)))
    end
    return
  end

  if self.scanner.pendingPublishTimer then
    self:CancelSNDTimer(self.scanner.pendingPublishTimer)
    self.scanner.pendingPublishTimer = nil
    self.scanner.pendingPublishDueAt = 0
  end

  self.scanner.lastPublish = now
  debugScan(self, string.format(
    "Publish: begin playerCount=%d recipeIndexCount=%d",
    countTableEntries(self.db and self.db.players),
    countTableEntries(self.db and self.db.recipeIndex)
  ))
  -- Mark professions dirty for incremental sync
  if type(self.MarkDirty) == "function" then
    self:MarkDirty("professions")
  end
  self:SendProfSummary()
  self:SendRecipeIndex()
end

function SND:PublishSharedMats()
  if not self.db.config.shareMatsOptIn then
    self:ClearSharedMats()
    return
  end
  if not self.db.config.autoPublishMats then
    return
  end
  local snapshot = self:SnapshotSharedMats()
  if snapshot then
    if type(self.MarkDirty) == "function" then
      self:MarkDirty("materials")
    end
    self:SendMatsSnapshot(snapshot)
    self.scanner.lastMatsPublish = self:Now()
  end
end

function SND:ClearSharedMats()
  local playerKey = self:GetPlayerKey(UnitName("player"))
  if playerKey and self.db.players[playerKey] then
    self.db.players[playerKey].sharedMats = nil
  end
  self:SendMatsSnapshot({})
  self.scanner.lastMatsPublish = self:Now()
end

function SND:SnapshotSharedMats()
  local snapshot = {}
  local count = 0
  local maxItems = 200
  local totalCandidates = 0
  local truncatedCount = 0
  local exclusions = (self.db.config and self.db.config.shareMatsExclusions) or {}

  self.scanner.lastSharedMatsSnapshotCount = 0
  self.scanner.lastSharedMatsSnapshotTruncated = false
  self.scanner.lastSharedMatsSnapshotTruncatedCount = 0
  self.scanner.lastSharedMatsSnapshotTotalCandidates = 0

  for _, entry in pairs(self.db.recipeIndex) do
    local reagents = entry.reagents
    if reagents then
      for itemID in pairs(reagents) do
        if not exclusions[itemID] then
          if snapshot[itemID] == nil then
            totalCandidates = totalCandidates + 1
            if count < maxItems then
              snapshot[itemID] = GetItemCount(itemID, true)
              count = count + 1
            else
              truncatedCount = truncatedCount + 1
            end
          end
        end
      end
    end
  end

  self.scanner.lastSharedMatsSnapshotCount = count
  self.scanner.lastSharedMatsSnapshotTotalCandidates = totalCandidates

  if truncatedCount > 0 then
    local now = self:Now()
    self.scanner.lastSharedMatsSnapshotTruncated = true
    self.scanner.lastSharedMatsSnapshotTruncatedCount = truncatedCount

    if (now - (tonumber(self.scanner.lastSharedMatsTruncationWarnAt) or 0)) >= 60 then
      self.scanner.lastSharedMatsTruncationWarnAt = now
      local message = string.format(
        "Scanner: shared mats snapshot truncated (cap=%d captured=%d truncated=%d totalCandidates=%d)",
        maxItems,
        count,
        truncatedCount,
        totalCandidates
      )
      debugScan(self, message)
      self:DebugPrint(message)
    end
  end

  return snapshot
end
