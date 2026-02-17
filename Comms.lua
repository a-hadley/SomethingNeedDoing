local addonName = ...
local SND = _G[addonName]

local AceComm = LibStub("AceComm-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate")

-- Authority model: peer-to-peer eventual consistency.
-- Each player is authoritative for their own data (professions, materials).
-- Shared state (requests, recipe index) uses LWW with version vectors.
-- The WoW-provided `sender` field (unforgeable) is used to attribute data.
SND.comms = {
  prefix = "SND",
  version = 2,
  rate = { window = 5, max = 25 },
  chunkTimeout = 30,
  incrementalSyncInterval = 15,  -- Incremental (dirty-only) broadcast every 15s
  fullSyncInterval = 120,        -- Full state rebroadcast every 120s as fallback
}

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

local function debugComms(self, message)
  self:DebugOnlyLog(message)
end

local function commsError(self, message)
  self:DebugOnlyLog(message)
  if self.comms and self.comms.stats then
    self.comms.stats.errors = self.comms.stats.errors + 1
  end
end

-- Compare two semver strings (e.g. "0.4.0" vs "0.10.1").
-- Returns 1 if a > b, -1 if a < b, 0 if equal.
local function compareSemver(a, b)
  local aMaj, aMin, aPat = string.match(tostring(a), "^(%d+)%.(%d+)%.(%d+)")
  local bMaj, bMin, bPat = string.match(tostring(b), "^(%d+)%.(%d+)%.(%d+)")
  aMaj, aMin, aPat = tonumber(aMaj) or 0, tonumber(aMin) or 0, tonumber(aPat) or 0
  bMaj, bMin, bPat = tonumber(bMaj) or 0, tonumber(bMin) or 0, tonumber(bPat) or 0
  if aMaj ~= bMaj then return aMaj > bMaj and 1 or -1 end
  if aMin ~= bMin then return aMin > bMin and 1 or -1 end
  if aPat ~= bPat then return aPat > bPat and 1 or -1 end
  return 0
end

local function lwwScore(entry, fallbackId)
  if type(entry) ~= "table" then
    return 0, "", tostring(fallbackId or "")
  end
  local ts = tonumber(entry.updatedAtServer) or tonumber(entry.lastUpdated) or tonumber(entry.updatedAt) or 0
  local by = tostring(entry.updatedBy or "")
  local id = tostring(entry.id or fallbackId or "")
  return ts, by, id
end

local function incomingWins(incoming, existing, fallbackId)
  -- Prefer higher version first (monotonically incrementing per entity)
  local inVer = tonumber(incoming and incoming.version) or 0
  local exVer = tonumber(existing and existing.version) or 0
  if inVer ~= exVer then
    return inVer > exVer
  end
  -- Fall back to timestamp-based LWW
  local inTs, inBy, inId = lwwScore(incoming, fallbackId)
  local exTs, exBy, exId = lwwScore(existing, fallbackId)
  if inTs ~= exTs then
    return inTs > exTs
  end
  if inBy ~= exBy then
    return inBy > exBy
  end
  return inId > exId
end

-- Full-state message types: only keep latest per sender during combat queue
local FULL_STATE_TYPES = {
  RCP3_FULL = true, REQ_FULL = true, STAT_FULL = true,
  MAT_FULL = true, PROF_DATA = true,
}

local COMBAT_QUEUE_CAP = 200

local function normalizeRecipeEntry(entry, recipeSpellID, now, updatedBy)
  if type(entry) ~= "table" then
    return nil
  end
  entry.id = entry.id or tostring(recipeSpellID)
  entry.entityType = "RECIPE"
  entry.updatedAtServer = tonumber(entry.updatedAtServer) or tonumber(entry.lastUpdated) or now
  entry.updatedBy = entry.updatedBy or updatedBy
  entry.lastUpdated = entry.updatedAtServer
  entry.version = tonumber(entry.version) or 1
  return entry
end

local function normalizeMatsEnvelope(snapshotOrEnvelope, senderKey, now)
  if type(snapshotOrEnvelope) ~= "table" then
    return nil
  end

  local envelope = snapshotOrEnvelope
  if envelope.entityType == nil and envelope.data == nil then
    envelope = {
      id = "mat:" .. tostring(senderKey),
      entityType = "MATS",
      updatedAtServer = now,
      updatedBy = senderKey,
      data = snapshotOrEnvelope,
    }
  end

  envelope.id = envelope.id or ("mat:" .. tostring(senderKey))
  envelope.entityType = "MATS"
  envelope.updatedAtServer = tonumber(envelope.updatedAtServer) or now
  envelope.updatedBy = envelope.updatedBy or senderKey
  envelope.data = type(envelope.data) == "table" and envelope.data or {}
  envelope.version = tonumber(envelope.version) or 1
  return envelope
end

function SND:InitComms()
  self.comms.ace = AceComm
  self.comms.serializer = AceSerializer
  self.comms.deflate = LibDeflate
  self.comms.chunkBuffer = {}
  self.comms.guildMemberCache = self.comms.guildMemberCache or {}
  self.comms.guildMemberCacheLastRefresh = tonumber(self.comms.guildMemberCacheLastRefresh) or 0
  self.comms.pendingCombatMessages = {}
  self.comms.pendingCombatLatest = {}  -- [sender.."|"..msgType] = msgData (dedup full-state types)
  self.comms.inCombat = false
  if self.comms.sendLegacyRecipeChunks == nil then
    self.comms.sendLegacyRecipeChunks = false
  end

  -- Rolling message receive log (timestamps only, for stats display)
  self.comms.messageLog = {}
  self.comms.messageLogHead = 0
  self.comms.messageLogSize = 3600  -- max entries (enough for 1 hour at ~1msg/s)

  -- Per-message-type counters for stats display
  self.comms.stats = {
    byType = {},        -- { [messageType] = count } (received)
    sent = {},          -- { [messageType] = count } (sent)
    totalSent = 0,      -- total messages sent
    sendBlocked = 0,    -- sends blocked by combat lockdown
    rateLimited = 0,    -- messages dropped by rate limiter
    nonGuild = 0,       -- messages rejected (non-guild sender)
    combatQueued = 0,   -- messages queued during combat
    errors = 0,         -- decode/decompress/deserialize failures
  }

  -- Dirty tracking for incremental sync
  self.comms.dirty = {
    recipeIndex = {},   -- { [recipeSpellID] = true }
    requests = {},      -- { [requestId] = true }
    craftLog = {},      -- { [logId] = true }
    professions = false,
    materials = false,
  }

  self:RefreshGuildMemberCacheFromRoster()

  -- Combat state tracking for comms
  self:RegisterEvent("PLAYER_REGEN_DISABLED", function(selfRef)
    selfRef.comms.inCombat = true
  end)
  self:RegisterEvent("PLAYER_REGEN_ENABLED", function(selfRef)
    selfRef.comms.inCombat = false
    -- Merge deduped full-state messages + regular queue
    local allMessages = {}
    for _, msgData in pairs(selfRef.comms.pendingCombatLatest) do
      table.insert(allMessages, msgData)
    end
    for _, msgData in ipairs(selfRef.comms.pendingCombatMessages) do
      table.insert(allMessages, msgData)
    end
    selfRef.comms.pendingCombatMessages = {}
    selfRef.comms.pendingCombatLatest = {}

    if #allMessages == 0 then
      return
    end

    debugComms(selfRef, string.format("Comms: combat ended, processing %d pending messages in batches", #allMessages))

    -- Process in batches of 10 per 0.1s tick to avoid frame hitch
    local batchSize = 10
    local index = 1
    local function processBatch()
      local endIndex = math.min(index + batchSize - 1, #allMessages)
      for i = index, endIndex do
        local msgData = allMessages[i]
        selfRef:HandleAddonMessage(msgData.payload, msgData.channel, msgData.sender)
      end
      index = endIndex + 1
      if index <= #allMessages then
        selfRef:ScheduleSNDTimer(0.1, processBatch)
      else
        -- All done — schedule a coalesced full-state broadcast
        selfRef.comms.lastFullSyncAt = 0
        selfRef:ScheduleSNDTimer(2, function()
          selfRef:BroadcastFullState("post-combat")
        end)
      end
    end
    processBatch()
  end)

  self.comms.ace:RegisterComm(self.comms.prefix, function(prefix, payload, channel, sender)
    -- Record message timestamp for stats
    local msgLog = self.comms.messageLog
    self.comms.messageLogHead = (self.comms.messageLogHead % self.comms.messageLogSize) + 1
    msgLog[self.comms.messageLogHead] = self:Now()

    -- Debug: Track message reception
    local messageType = payload and payload:match("^([^|]+)") or "UNKNOWN"

    -- Track per-type message counts
    local stats = self.comms.stats
    stats.byType[messageType] = (stats.byType[messageType] or 0) + 1

    if self.db and self.db.config and self.db.config.debugMode then
      debugComms(self, string.format("Comms: RX type=%s from=%s channel=%s", messageType, tostring(sender), tostring(channel)))
    end

    -- Combat protection: queue messages during combat
    if InCombatLockdown() then
      self.comms.inCombat = true
      stats.combatQueued = stats.combatQueued + 1
      local msgData = { payload = payload, channel = channel, sender = sender }
      -- Deduplicate full-state types: only keep latest per sender per type
      if FULL_STATE_TYPES[messageType] then
        self.comms.pendingCombatLatest[sender .. "|" .. messageType] = msgData
      else
        if #self.comms.pendingCombatMessages < COMBAT_QUEUE_CAP then
          table.insert(self.comms.pendingCombatMessages, msgData)
        end
      end
      if self.db and self.db.config and self.db.config.debugMode then
        debugComms(self, string.format("Comms: queued during combat type=%s from=%s", messageType, tostring(sender)))
      end
      return
    end

    if not self:PassRateLimit(sender) then
      stats.rateLimited = stats.rateLimited + 1
      if self.db and self.db.config and self.db.config.debugMode then
        debugComms(self, string.format("Comms: rate limited type=%s from=%s", messageType, tostring(sender)))
      end
      return
    end
    if not self:IsGuildMember(sender) then
      stats.nonGuild = stats.nonGuild + 1
      if self.db and self.db.config and self.db.config.debugMode then
        debugComms(self, string.format("Comms: rejected non-guild type=%s from=%s", messageType, tostring(sender)))
      end
      return
    end
    self:HandleAddonMessage(payload, channel, sender)
  end)

  -- Incremental sync ticker: only sends dirty (changed) data every 15s
  if self.comms.incrementalSyncTicker then
    self:CancelSNDTimer(self.comms.incrementalSyncTicker)
  end
  self.comms.incrementalSyncTicker = self:ScheduleSNDRepeatingTimer(self.comms.incrementalSyncInterval, function()
    self:BroadcastIncrementalState()
  end)

  -- Full state fallback ticker: sends everything every 120s for convergence
  if self.comms.fullSyncTicker then
    self:CancelSNDTimer(self.comms.fullSyncTicker)
  end
  self.comms.fullSyncTicker = self:ScheduleSNDRepeatingTimer(self.comms.fullSyncInterval, function()
    self:BroadcastFullState("ticker")
  end)

  -- Startup: full state after 2 seconds for fast initial sync
  self:ScheduleSNDTimer(2, function()
    self:BroadcastFullState("startup")
  end)

  -- Periodic cleanup: stale rate limit state (every 5 minutes)
  self:ScheduleSNDRepeatingTimer(300, function()
    local now = self:Now()
    local window = self.comms.rate.window or 5
    for sender, state in pairs(self.comms.rateState or {}) do
      if now - (state.start or 0) > window * 2 then
        self.comms.rateState[sender] = nil
      end
    end
  end)

  -- Periodic cleanup: stale chunk buffers (every 60 seconds)
  self:ScheduleSNDRepeatingTimer(60, function()
    local now = self:Now()
    for key, buf in pairs(self.comms.chunkBuffer or {}) do
      if now - (buf.receivedAt or 0) > self.comms.chunkTimeout then
        self.comms.chunkBuffer[key] = nil
      end
    end
  end)
end

function SND:UpdateGuildMemberCache(memberSet)
  if type(memberSet) ~= "table" then
    return
  end

  local cache = {}
  for nameOnly in pairs(memberSet) do
    if type(nameOnly) == "string" and nameOnly ~= "" then
      cache[nameOnly] = true
    end
  end

  local playerName = UnitName("player")
  if playerName and playerName ~= "" then
    cache[playerName] = true
  end

  self.comms.guildMemberCache = cache
  self.comms.guildMemberCacheLastRefresh = self:Now()
end

function SND:RefreshGuildMemberCacheFromRoster()
  local memberSet = {}
  local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
  for i = 1, numMembers do
    local name = GetGuildRosterInfo(i)
    local nameOnly = name and strsplit("-", name)
    if nameOnly and nameOnly ~= "" then
      memberSet[nameOnly] = true
    end
  end
  self:UpdateGuildMemberCache(memberSet)
end

function SND:HandleAddonMessage(payload, channel, sender)
  local messageType = payload
  local pipeIndex = string.find(payload, "|", 1, true)
  if pipeIndex then
    messageType = string.sub(payload, 1, pipeIndex - 1)
  end
  if messageType ~= "RCP" and messageType ~= "RCP_FULL" and messageType ~= "RCP3" and messageType ~= "RCP3_FULL" then
    debugComms(self, string.format("Comms: received type=%s from=%s channel=%s", tostring(messageType), tostring(sender), tostring(channel)))
  end

  if messageType == "HELLO" then
    self:HandleHello(payload, sender)
  elseif messageType == "PROF" then
    self:HandleProf(payload, sender)
  elseif messageType == "RCP" or messageType == "RCP_FULL" then
    self:HandleRecipeChunk(payload, sender)
  elseif messageType == "RCP3" or messageType == "RCP3_FULL" then
    self:HandleRecipeEnvelope(payload, sender)
  elseif messageType == "MAT" or messageType == "MAT_FULL" then
    self:HandleMatsMessage(payload, sender)
  elseif messageType == "REQ_NEW" then
    self:HandleRequestMessage(payload, "REQ_NEW", sender)
  elseif messageType == "REQ_UPD" then
    self:HandleRequestMessage(payload, "REQ_UPD", sender)
  elseif messageType == "REQ_DEL" then
    self:HandleRequestMessage(payload, "REQ_DEL", sender)
  elseif messageType == "REQ_FULL" then
    self:HandleRequestMessage(payload, "REQ_FULL", sender)
  elseif messageType == "REQ_NOTIFY" then
    self:HandleDeliveryNotification(payload, sender)
  elseif messageType == "STAT_LOG" then
    if type(self.HandleStatLogMessage) == "function" then
      self:HandleStatLogMessage(payload, sender)
    end
  elseif messageType == "STAT_FULL" then
    if type(self.HandleStatFullMessage) == "function" then
      self:HandleStatFullMessage(payload, sender)
    end
  elseif messageType == "PROF_DATA" then
    self:HandleProfessionData(payload, sender)
  end
end

function SND:BroadcastFullState(reason)
  local now = self:Now()
  local interval = tonumber(self.comms.fullSyncInterval) or 300
  local lastFullSyncAt = tonumber(self.comms.lastFullSyncAt) or 0
  local nextFullSyncAt = lastFullSyncAt + interval

  if lastFullSyncAt > 0 and now < nextFullSyncAt then
    debugComms(self, string.format(
      "Comms: full-state rebroadcast skipped reason=%s now=%d next=%d in=%ds",
      tostring(reason or "unknown"),
      now,
      nextFullSyncAt,
      math.max(0, math.floor(nextFullSyncAt - now))
    ))
    return
  end

  debugComms(self, string.format(
    "Comms: full-state rebroadcast due reason=%s now=%d next=%d",
    tostring(reason or "unknown"),
    now,
    now + interval
  ))

  self:SendHello()
  self:SendRecipeIndex(true)
  self:SendProfessionData()
  self:SendMatsSnapshot(self:SnapshotSharedMats() or {}, true)
  if type(self.SendRequestFullState) == "function" then
    self:SendRequestFullState()
  end
  if type(self.SendCraftLogFullState) == "function" then
    self:SendCraftLogFullState()
  end
  self.comms.lastFullSyncAt = self:Now()
  -- Clear dirty state since full state covers everything
  if self.comms.dirty then
    self.comms.dirty.recipeIndex = {}
    self.comms.dirty.requests = {}
    self.comms.dirty.craftLog = {}
    self.comms.dirty.professions = false
    self.comms.dirty.materials = false
  end
  debugComms(self, string.format(
    "Comms: full-state rebroadcast sent at=%d next=%d",
    self.comms.lastFullSyncAt,
    self.comms.lastFullSyncAt + interval
  ))
end

function SND:BroadcastIncrementalState()
  local dirty = self.comms.dirty
  if not dirty then
    return
  end

  local hasDirty = dirty.professions or dirty.materials
    or next(dirty.recipeIndex) or next(dirty.requests) or next(dirty.craftLog)
  if not hasDirty then
    return
  end

  local sent = {}
  self:SendHello()

  if dirty.professions then
    self:SendProfessionData()
    dirty.professions = false
    table.insert(sent, "professions")
  end

  if next(dirty.recipeIndex) then
    table.insert(sent, string.format("recipes=%d", countTableEntries(dirty.recipeIndex)))
    self:SendDirtyRecipes(dirty.recipeIndex)
    dirty.recipeIndex = {}
  end

  if dirty.materials then
    self:SendMatsSnapshot(self:SnapshotSharedMats() or {}, false)
    dirty.materials = false
    table.insert(sent, "materials")
  end

  if next(dirty.requests) then
    table.insert(sent, string.format("requests=%d", countTableEntries(dirty.requests)))
    self:SendDirtyRequests(dirty.requests)
    dirty.requests = {}
  end

  if next(dirty.craftLog) then
    table.insert(sent, string.format("craftLog=%d", countTableEntries(dirty.craftLog)))
    self:SendDirtyCraftLog(dirty.craftLog)
    dirty.craftLog = {}
  end

  debugComms(self, string.format("Comms: incremental sync sent [%s]", table.concat(sent, ", ")))
end

function SND:SendDirtyRecipes(dirtySet)
  local now = self:Now()
  local updatedBy = self:GetPlayerKey(UnitName("player"))
  local subset = {}
  for recipeSpellID in pairs(dirtySet) do
    local entry = self.db.recipeIndex[recipeSpellID]
    if entry then
      normalizeRecipeEntry(entry, recipeSpellID, now, updatedBy)
      subset[recipeSpellID] = entry
    end
  end
  if not next(subset) then
    return
  end
  local serialized = self.comms.serializer:Serialize(subset)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  self:SendAddonMessage(string.format("RCP3|%s", encoded))
end

function SND:SendDirtyRequests(dirtySet)
  for requestId in pairs(dirtySet) do
    local request = self.db.requests[requestId]
    if request then
      local serialized = self.comms.serializer:Serialize({ id = requestId, data = request })
      local compressed = self.comms.deflate:CompressDeflate(serialized)
      local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
      self:SendAddonMessage(string.format("REQ_UPD|%s", encoded), "ALERT")
    end
  end
end

function SND:SendDirtyCraftLog(dirtySet)
  for logId in pairs(dirtySet) do
    local entry = self.db.craftLog and self.db.craftLog[logId]
    if entry then
      self:SendCraftLogEntry(entry)
    end
  end
end

function SND:MarkDirty(entityType, entityId)
  if not self.comms or not self.comms.dirty then
    return
  end
  local dirty = self.comms.dirty
  if entityType == "professions" then
    dirty.professions = true
  elseif entityType == "materials" then
    dirty.materials = true
  elseif entityType == "recipeIndex" and entityId then
    dirty.recipeIndex[entityId] = true
  elseif entityType == "requests" and entityId then
    dirty.requests[entityId] = true
  elseif entityType == "craftLog" and entityId then
    dirty.craftLog[entityId] = true
  end
end

function SND:GetCommsMessageCounts()
  local now = self:Now()
  local oneMin, fiveMin, sixtyMin = 0, 0, 0
  for _, ts in ipairs(self.comms.messageLog or {}) do
    local age = now - ts
    if age <= 60 then
      oneMin = oneMin + 1
      fiveMin = fiveMin + 1
      sixtyMin = sixtyMin + 1
    elseif age <= 300 then
      fiveMin = fiveMin + 1
      sixtyMin = sixtyMin + 1
    elseif age <= 3600 then
      sixtyMin = sixtyMin + 1
    end
  end

  local pendingCombat = #(self.comms.pendingCombatMessages or {})
  for _ in pairs(self.comms.pendingCombatLatest or {}) do
    pendingCombat = pendingCombat + 1
  end

  local chunkBuffers = 0
  for _ in pairs(self.comms.chunkBuffer or {}) do
    chunkBuffers = chunkBuffers + 1
  end

  local dirtyCount = 0
  local dirty = self.comms.dirty
  if dirty then
    if dirty.professions then dirtyCount = dirtyCount + 1 end
    if dirty.materials then dirtyCount = dirtyCount + 1 end
    for _ in pairs(dirty.recipeIndex or {}) do dirtyCount = dirtyCount + 1 end
    for _ in pairs(dirty.requests or {}) do dirtyCount = dirtyCount + 1 end
    for _ in pairs(dirty.craftLog or {}) do dirtyCount = dirtyCount + 1 end
  end

  local stats = self.comms.stats or {}

  return {
    oneMin = oneMin,
    fiveMin = fiveMin,
    sixtyMin = sixtyMin,
    pendingCombat = pendingCombat,
    chunkBuffers = chunkBuffers,
    dirtyCount = dirtyCount,
    byType = stats.byType or {},
    sent = stats.sent or {},
    totalSent = stats.totalSent or 0,
    sendBlocked = stats.sendBlocked or 0,
    rateLimited = stats.rateLimited or 0,
    nonGuild = stats.nonGuild or 0,
    combatQueued = stats.combatQueued or 0,
    errors = stats.errors or 0,
  }
end

function SND:GetPeerStats()
  local localVersion = self.addonVersion or "0.0.0"
  local peerVersions = self.comms.peerAddonVersions or {}
  local totalPeers = 0
  local onCurrentVersion = 0
  local byVersion = {}

  for _, ver in pairs(peerVersions) do
    totalPeers = totalPeers + 1
    byVersion[ver] = (byVersion[ver] or 0) + 1
    if ver == localVersion then
      onCurrentVersion = onCurrentVersion + 1
    end
  end

  return {
    totalPeers = totalPeers,
    localVersion = localVersion,
    onCurrentVersion = onCurrentVersion,
    outdated = totalPeers - onCurrentVersion,
    byVersion = byVersion,
  }
end

function SND:SendHello()
  local addonVer = self.addonVersion or "0.0.0"
  local payload = string.format("HELLO|%d|%s", self.comms.version, addonVer)
  self:SendAddonMessage(payload)
end

function SND:SendProfSummary()
  local payload = string.format("PROF|%d", self.comms.version)
  self:SendAddonMessage(payload)
end

function SND:SendProfessionData()
  -- Prune stale professions before broadcasting (e.g., dropped professions)
  if type(self.PruneStaleLocalProfessions) == "function" then
    self:PruneStaleLocalProfessions()
  end

  local playerKey = self:GetPlayerKey(UnitName("player"))
  local playerEntry = playerKey and self.db.players[playerKey]
  if not playerEntry or not playerEntry.professions then
    return
  end

  -- Build a compact table: { [profSkillLineID] = { name, recipes = {id=true,...} }, ... }
  local profData = {}
  for profKey, prof in pairs(playerEntry.professions) do
    if prof.recipes and next(prof.recipes) then
      profData[profKey] = {
        name = prof.name,
        rank = prof.rank,
        maxRank = prof.maxRank,
        recipes = prof.recipes,
      }
    end
  end

  if not next(profData) then
    return
  end

  local serialized = self.comms.serializer:Serialize(profData)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  debugComms(self, string.format("Comms: SendProfessionData player=%s profs=%d encoded=%d", tostring(playerKey), countTableEntries(profData), #encoded))
  self:SendAddonMessage(string.format("PROF_DATA|%s", encoded))
end

function SND:HandleProfessionData(payload, sender)
  local encoded = string.match(payload, "^PROF_DATA|(.+)$")
  if not encoded or encoded == "" then
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    commsError(self, string.format("Comms: HandleProfessionData decode failed from=%s", tostring(sender)))
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    commsError(self, string.format("Comms: HandleProfessionData decompress failed from=%s", tostring(sender)))
    return
  end
  local ok, profData = self.comms.serializer:Deserialize(inflated)
  if not ok or type(profData) ~= "table" then
    commsError(self, string.format("Comms: HandleProfessionData deserialize failed from=%s", tostring(sender)))
    return
  end

  local senderKey = self:GetPlayerKey(strsplit("-", sender)) or sender
  local senderEntry = self.db.players[senderKey] or {}
  senderEntry.name = senderEntry.name or strsplit("-", sender)
  senderEntry.online = true
  senderEntry.lastSeen = self:Now()

  -- Replace sender's professions with authoritative data from sender
  senderEntry.professions = {}
  for profKey, prof in pairs(profData) do
    if type(prof) == "table" and prof.recipes then
      local profName = prof.name or self:GetProfessionNameBySkillLineID(profKey)
      senderEntry.professions[profKey] = {
        name = profName,
        rank = prof.rank,
        maxRank = prof.maxRank,
        recipes = prof.recipes,
      }
    end
  end

  self.db.players[senderKey] = senderEntry
  debugComms(self, string.format(
    "Comms: HandleProfessionData sender=%s profs=%d",
    tostring(senderKey),
    countTableEntries(senderEntry.professions)
  ))
end

function SND:SendAddonMessage(payload, priority)
  -- Combat protection: don't send messages during combat
  if InCombatLockdown() then
    local stats = self.comms.stats
    stats.sendBlocked = stats.sendBlocked + 1
    debugComms(self, "Comms: message send blocked during combat")
    return
  end
  -- Track sent message type
  local msgType = payload and payload:match("^([^|]+)") or "UNKNOWN"
  local stats = self.comms.stats
  stats.sent[msgType] = (stats.sent[msgType] or 0) + 1
  stats.totalSent = stats.totalSent + 1
  -- Priority: "BULK" (low), "NORMAL" (default), "ALERT" (high/immediate)
  -- Request messages use "ALERT" to bypass throttling for instant updates
  local prio = priority or "NORMAL"
  self.comms.ace:SendCommMessage(self.comms.prefix, payload, "GUILD", nil, prio)
end

function SND:HandleHello(payload, sender)
  debugComms(self, string.format("Comms: HELLO received from=%s", tostring(sender)))

  -- Parse addon version from HELLO payload: "HELLO|<commsVersion>|<addonVersion>"
  local parts = { strsplit("|", payload) }
  local remoteCommsVersion = tonumber(parts[2]) or 0
  local remoteAddonVersion = parts[3]

  -- Track peer comms protocol version and addon version
  local senderKey = self:GetPlayerKey(strsplit("-", sender)) or sender
  if remoteCommsVersion > 0 then
    self.comms.peerVersions = self.comms.peerVersions or {}
    self.comms.peerVersions[senderKey] = remoteCommsVersion
    if remoteCommsVersion > self.comms.version then
      debugComms(self, string.format("Comms: peer %s has newer protocol v%d (we have v%d)", tostring(sender), remoteCommsVersion, self.comms.version))
    end
  end

  -- Store addon version per peer for stats display
  self.comms.peerAddonVersions = self.comms.peerAddonVersions or {}
  if remoteAddonVersion and remoteAddonVersion ~= "" then
    self.comms.peerAddonVersions[senderKey] = remoteAddonVersion
  end

  if not remoteAddonVersion or remoteAddonVersion == "" then
    return
  end

  local localVersion = self.addonVersion or "0.0.0"
  if compareSemver(remoteAddonVersion, localVersion) > 0 and not self._versionWarningShown then
    self._versionWarningShown = true
    self:Print(string.format(
      "|cffff8000SND Update Available:|r A guild member is running v%s (you have v%s). Please update!",
      remoteAddonVersion, localVersion
    ))
  end
end

function SND:HandleProf(payload, sender)
  debugComms(self, string.format("Comms: PROF received from=%s", tostring(sender)))
end

function SND:HandleRequestMessage(payload, kind, sender)
  local encoded = string.match(payload, "^" .. kind .. "%|(.*)$")
  if not encoded then
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    commsError(self, string.format("Comms: HandleRequestMessage decode failed kind=%s from=%s", kind, tostring(sender)))
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    commsError(self, string.format("Comms: HandleRequestMessage decompress failed kind=%s from=%s", kind, tostring(sender)))
    return
  end
  local ok, message = self.comms.serializer:Deserialize(inflated)
  if not ok or type(message) ~= "table" then
    commsError(self, string.format("Comms: HandleRequestMessage deserialize failed kind=%s from=%s", kind, tostring(sender)))
    return
  end

  local senderName = strsplit("-", sender)
  local senderKey = self:GetPlayerKey(senderName) or sender

  local function denyMutation(action, requestId, reason)
    debugComms(self, string.format(
      "Comms: denied %s sender=%s requestId=%s reason=%s",
      tostring(action),
      tostring(senderKey),
      tostring(requestId),
      tostring(reason)
    ))
  end

  local function isAuthorizedRequestMutation(requestId, incomingRequest, existingRequest)
    if type(self.RequestPolicyAuthorizeInboundMutation) ~= "function" then
      return false, "policy_unavailable"
    end
    return self:RequestPolicyAuthorizeInboundMutation(incomingRequest, existingRequest, senderKey)
  end

  local function isAuthorizedRequestDelete(requestId, tombstone, existingRequest)
    if type(self.RequestPolicyAuthorizeInboundDelete) ~= "function" then
      return false, "policy_unavailable"
    end
    return self:RequestPolicyAuthorizeInboundDelete(existingRequest, tombstone, senderKey)
  end

  self.db.requestTombstones = self.db.requestTombstones or {}

  if kind == "REQ_DEL" then
    if message.id and type(message.tombstone) == "table" then
      local existingReq = self.db.requests[message.id]
      local authorized, reason = isAuthorizedRequestDelete(message.id, message.tombstone, existingReq)
      if not authorized then
        denyMutation("REQ_DEL", message.id, reason)
        return
      end
      local existingTomb = self.db.requestTombstones[message.id]
      if incomingWins(message.tombstone, existingTomb or existingReq, message.id) then
        self.db.requestTombstones[message.id] = message.tombstone
        self.db.requests[message.id] = nil
      end
    elseif message.id then
      denyMutation("REQ_DEL", message.id, "missing_tombstone")
      return
    end
    return
  end

  if kind == "REQ_FULL" then
    local requests = type(message.requests) == "table" and message.requests or {}
    local tombstones = type(message.tombstones) == "table" and message.tombstones or {}

    for requestId, incomingRequest in pairs(requests) do
      if type(incomingRequest) == "table" then
        incomingRequest.id = incomingRequest.id or requestId
      end
      if type(self.NormalizeRequestData) == "function" then
        self:NormalizeRequestData(incomingRequest)
      end
      local existing = self.db.requests[requestId]
      local authorized, reason = isAuthorizedRequestMutation(requestId, incomingRequest, existing)
      if not authorized then
        denyMutation("REQ_FULL_REQ", requestId, reason)
      else
        local tombstone = self.db.requestTombstones[requestId]
        if incomingWins(incomingRequest, tombstone or existing, requestId) then
          self.db.requests[requestId] = incomingRequest
          -- Record craft log for delivered requests during full sync
          if incomingRequest.status == "DELIVERED" and type(self.RecordCraftLogEntry) == "function" then
            self:RecordCraftLogEntry(requestId, incomingRequest)
          end
        end
      end
    end

    for requestId, tomb in pairs(tombstones) do
      local existing = self.db.requests[requestId]
      local authorized, reason = isAuthorizedRequestDelete(requestId, tomb, existing)
      if not authorized then
        denyMutation("REQ_FULL_DEL", requestId, reason)
      else
        local existingTomb = self.db.requestTombstones[requestId]
        if incomingWins(tomb, existingTomb or existing, requestId) then
          self.db.requestTombstones[requestId] = tomb
          self.db.requests[requestId] = nil
        end
      end
    end

    return
  end

  if message.id and message.data then
    if type(message.data) == "table" then
      message.data.id = message.data.id or message.id
    end
    if type(self.NormalizeRequestData) == "function" then
      self:NormalizeRequestData(message.data)
    end
    local existing = self.db.requests[message.id]
    local authorized, reason = isAuthorizedRequestMutation(message.id, message.data, existing)
    if not authorized then
      denyMutation(kind, message.id, reason)
      return
    end
    local tomb = self.db.requestTombstones[message.id]
    if incomingWins(message.data, tomb or existing, message.id) then
      self.db.requests[message.id] = message.data
      if kind == "REQ_NEW" and type(self.ShowIncomingRequestPopup) == "function" then
        self:ShowIncomingRequestPopup(message.id, message.data, sender)
      end

      -- Record craft log entry when a remote DELIVERED status comes in
      if kind == "REQ_UPD" and message.data.status == "DELIVERED" and type(self.RecordCraftLogEntry) == "function" then
        self:RecordCraftLogEntry(message.id, message.data)
      end

      -- Notify if this is a new request for a recipe the local player knows
      if kind == "REQ_NEW" and message.data.recipeSpellID then
        local localPlayerKey = self:GetPlayerKey(UnitName("player"))
        local localPlayer = self.db.players[localPlayerKey]
        local canCraft = false

        if localPlayer and localPlayer.professions then
          for _, prof in pairs(localPlayer.professions) do
            if prof.recipes and prof.recipes[message.data.recipeSpellID] then
              canCraft = true
              break
            end
          end
        end

        -- Notify user if notifications enabled and not in combat
        local showNotifications = self.db and self.db.config and self.db.config.showNotifications
        if canCraft and showNotifications and not InCombatLockdown() then
          local recipeName = self:GetRecipeOutputItemName(message.data.recipeSpellID)
          if not recipeName and self.db.recipeIndex[message.data.recipeSpellID] then
            recipeName = self.db.recipeIndex[message.data.recipeSpellID].name
          end
          recipeName = recipeName or ("Recipe " .. tostring(message.data.recipeSpellID))

          local requesterName = message.data.requesterName or strsplit("-", sender)
          self:Print(string.format("|cffff8000New Request:|r |cffffd700%s|r requested by |cff00ff00%s|r - You can craft this!", recipeName, requesterName))
        end
      end
    end
  end

  -- Refresh request list UI (but not during combat to avoid taint)
  if not InCombatLockdown() and self.mainFrame and self.mainFrame.contentFrames then
    local requestsFrame = self.mainFrame.contentFrames[2]
    if requestsFrame and requestsFrame.listButtons then
      self:RefreshRequestList(requestsFrame)

      -- Also update the selected request's details if it was updated
      if message and message.id and requestsFrame.selectedRequestId == message.id then
        -- Show notification if status changed and user is viewing this request
        if kind == "REQ_UPD" and message.data and message.data.status then
          local request = self.db.requests[message.id]
          if request and self.db.config.showNotifications then
            local statusChangeMsg = string.format(
              "|cffff8000Request Status Changed:|r %s > |cff00ff00%s|r",
              self:GetRecipeOutputItemName(request.recipeSpellID) or "Request",
              message.data.status
            )
            self:DebugPrint(statusChangeMsg)
          end
        end
        self:SelectRequest(requestsFrame, message.id)
      end
    end
  end
end

function SND:HandleDeliveryNotification(payload, sender)
  local encoded = string.match(payload, "^REQ_NOTIFY%|(.*)$")
  if not encoded then
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    commsError(self, string.format("Comms: HandleDeliveryNotification decode failed from=%s", tostring(sender)))
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    commsError(self, string.format("Comms: HandleDeliveryNotification decompress failed from=%s", tostring(sender)))
    return
  end
  local ok, message = self.comms.serializer:Deserialize(inflated)
  if not ok or type(message) ~= "table" then
    commsError(self, string.format("Comms: HandleDeliveryNotification deserialize failed from=%s", tostring(sender)))
    return
  end

  -- Only show to the requester
  local localPlayerKey = self:GetPlayerKey(UnitName("player"))
  if message.requester ~= localPlayerKey then
    return
  end

  -- Show notification if enabled and not in combat
  local showNotifications = self.db and self.db.config and self.db.config.showNotifications
  if showNotifications and not InCombatLockdown() and message.message then
    self:Print(string.format("|cff00ff00[Delivery]|r %s", message.message))
  end
end

function SND:SendMatsSnapshot(snapshot, isFullState)
  local playerKey = self:GetPlayerKey(UnitName("player"))
  local envelope = {
    id = "mat:" .. tostring(playerKey),
    entityType = "MATS",
    updatedAtServer = self:Now(),
    updatedBy = playerKey,
    version = 1,
    data = snapshot or {},
  }
  local serialized = self.comms.serializer:Serialize(envelope)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  local kind = isFullState and "MAT_FULL" or "MAT"
  self:SendAddonMessage(string.format("%s|%s", kind, encoded))
end

function SND:HandleMatsMessage(payload, sender)
  local encoded = string.match(payload, "^MAT%|(.*)$") or string.match(payload, "^MAT_FULL%|(.*)$")
  if not encoded then
    return
  end
  if #encoded > 80000 then
    commsError(self, string.format("Comms: HandleMatsMessage payload too large bytes=%d from=%s", #encoded, tostring(sender)))
    return
  end
  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    commsError(self, string.format("Comms: HandleMatsMessage decode failed from=%s", tostring(sender)))
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    commsError(self, string.format("Comms: HandleMatsMessage decompress failed from=%s", tostring(sender)))
    return
  end
  local ok, incomingPayload = self.comms.serializer:Deserialize(inflated)
  if not ok or type(incomingPayload) ~= "table" then
    commsError(self, string.format("Comms: HandleMatsMessage deserialize failed from=%s", tostring(sender)))
    return
  end
  local playerKey = self:GetPlayerKey(strsplit("-", sender))
  if not playerKey then
    return
  end

  local envelope = normalizeMatsEnvelope(incomingPayload, playerKey, self:Now())
  if not envelope then
    return
  end

  local entry = self.db.players[playerKey] or {}
  local existingMeta = {
    id = "mat:" .. tostring(playerKey),
    updatedAtServer = tonumber(entry.sharedMatsUpdatedAtServer) or 0,
    updatedBy = tostring(entry.sharedMatsUpdatedBy or ""),
  }
  if not incomingWins(envelope, existingMeta, envelope.id) then
    return
  end

  if next(envelope.data) == nil then
    entry.sharedMats = nil
  else
    entry.sharedMats = envelope.data
  end
  entry.sharedMatsUpdatedAtServer = envelope.updatedAtServer
  entry.sharedMatsUpdatedBy = envelope.updatedBy
  entry.lastSeen = self:Now()
  self.db.players[playerKey] = entry
end

function SND:SendRecipeIndex(isFullState)
  local payload = self:BuildRecipePayload()
  local kind = isFullState and "RCP3_FULL" or "RCP3"
  debugComms(self, string.format(
    "Comms: SendRecipeIndex entries=%d payloadBytes=%d transport=%s full=%s",
    countTableEntries(self.db and self.db.recipeIndex),
    payload and #payload or 0,
    "AceComm",
    tostring(isFullState and true or false)
  ))
  self:SendAddonMessage(string.format("%s|%s", kind, payload))

  if self.comms.sendLegacyRecipeChunks then
    local legacyKind = isFullState and "RCP_FULL" or "RCP"
    local chunks = self:ChunkPayload(payload, legacyKind)
    debugComms(self, string.format(
      "Comms: SendRecipeIndex legacy chunks=%d kind=%s",
      #chunks,
      tostring(legacyKind)
    ))
    for _, chunk in ipairs(chunks) do
      self:SendAddonMessage(chunk)
    end
  end
end

function SND:BuildRecipePayload()
  local now = self:Now()
  local updatedBy = self:GetPlayerKey(UnitName("player"))
  for recipeSpellID, entry in pairs(self.db.recipeIndex or {}) do
    normalizeRecipeEntry(entry, recipeSpellID, now, updatedBy)
  end
  local serialized = self.comms.serializer:Serialize(self.db.recipeIndex)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  return encoded
end

function SND:ChunkPayload(encoded, kind)
  kind = kind or "RCP"
  local maxChunk = 200
  local total = math.ceil(#encoded / maxChunk)
  local msgId = tostring(math.random(100000, 999999)) .. tostring(self:Now())
  local chunks = {}
  for i = 1, total do
    local startIndex = (i - 1) * maxChunk + 1
    local chunk = string.sub(encoded, startIndex, startIndex + maxChunk - 1)
    local packet = string.format("%s|%d|%s|%s|%d/%d|%s", kind, self.comms.version, UnitName("player") or "", msgId, i, total, chunk)
    table.insert(chunks, packet)
  end
  return chunks
end

function SND:IngestRecipeIndexPayload(encoded, sender, kind)
  debugComms(self, string.format(
    "Comms: IngestRecipeIndex enter sender=%s kind=%s encodedLen=%d",
    tostring(sender),
    tostring(kind),
    encoded and #encoded or 0
  ))

  if type(encoded) ~= "string" or encoded == "" then
    commsError(self, "Comms: IngestRecipeIndex abort invalid encoded string")
    return
  end

  if #encoded > 80000 then
    commsError(self, string.format("Comms: IngestRecipeIndex abort payload too large bytes=%d", #encoded))
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    commsError(self, "Comms: IngestRecipeIndex decode failed")
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    commsError(self, "Comms: IngestRecipeIndex decompress failed")
    return
  end
  local ok, recipeIndex = self.comms.serializer:Deserialize(inflated)
  if ok and type(recipeIndex) == "table" then
    local mergedCount = 0
    local now = self:Now()
    local senderKey = self:GetPlayerKey(strsplit("-", sender)) or sender

    for recipeSpellID, entry in pairs(recipeIndex) do
      -- Only process numeric recipe IDs - skip string formats like "classic:185::80"
      -- which cannot be resolved by the WoW API
      if type(recipeSpellID) == "number" then
        local incoming = normalizeRecipeEntry(entry, recipeSpellID, now, senderKey)
        if incoming then
          -- Merge into global recipeIndex if incoming wins
          local existing = self.db.recipeIndex[recipeSpellID]
          if incomingWins(incoming, existing, recipeSpellID) then
            -- Preserve locally-enriched fields the sender may not have
            if existing then
              if not incoming.reagents and existing.reagents then
                incoming.reagents = existing.reagents
              end
              if not incoming.outputItemID and existing.outputItemID then
                incoming.outputItemID = existing.outputItemID
              end
              if not incoming.itemName and existing.itemName then
                incoming.itemName = existing.itemName
              end
              if not incoming.itemIcon and existing.itemIcon then
                incoming.itemIcon = existing.itemIcon
              end
            end
            self.db.recipeIndex[recipeSpellID] = incoming
            mergedCount = mergedCount + 1
          end
        end
      end  -- Close type(recipeSpellID) == "number" check
    end

    debugComms(self, string.format(
      "Comms: IngestRecipeIndex merged sender=%s kind=%s merged=%d total=%d",
      tostring(sender),
      tostring(kind),
      mergedCount,
      countTableEntries(self.db and self.db.recipeIndex)
    ))

    -- Warm item cache for all merged recipes so names/icons/tooltips are available
    if mergedCount > 0 and type(self.WarmItemCache) == "function" then
      local itemsToWarm = {}
      local seen = {}
      for _, entry in pairs(self.db.recipeIndex) do
        local itemID = entry and entry.outputItemID
        if itemID and not seen[itemID] then
          -- Only warm items not already cached
          local name = GetItemInfo(itemID)
          if not name then
            table.insert(itemsToWarm, itemID)
            seen[itemID] = true
          end
        end
      end
      if #itemsToWarm > 0 then
        self:WarmItemCache(itemsToWarm)
      end
    end

    -- Refresh directory UI if recipes were merged (but not during combat to avoid taint)
    if mergedCount > 0 and not InCombatLockdown() and self.mainFrame and self.mainFrame.contentFrames then
      local directoryFrame = self.mainFrame.contentFrames[1]
      if directoryFrame and directoryFrame.searchBox then
        local query = directoryFrame.searchBox:GetText() or ""
        if type(self.UpdateDirectoryResults) == "function" then
          self:UpdateDirectoryResults(query)
        end
      end
    end
  else
    commsError(self, string.format(
      "Comms: IngestRecipeIndex deserialize failed ok=%s type=%s",
      tostring(ok),
      type(recipeIndex)
    ))
  end
end

function SND:HandleRecipeEnvelope(payload, sender)
  -- Try RCP3_FULL first (longer pattern), then fall back to RCP3
  -- Note: Lua patterns don't support | alternation like regex
  local kind, encoded = string.match(payload, "^(RCP3_FULL)%|(.*)$")
  if not kind then
    kind, encoded = string.match(payload, "^(RCP3)%|(.*)$")
  end

  if not kind or not encoded then
    debugComms(self, string.format(
      "Comms: HandleRecipeEnvelope pattern match failed from=%s len=%d",
      tostring(sender),
      payload and #payload or 0
    ))
    return
  end

  debugComms(self, string.format(
    "Comms: HandleRecipeEnvelope kind=%s encodedLen=%d from=%s",
    tostring(kind),
    encoded and #encoded or 0,
    tostring(sender)
  ))

  self:IngestRecipeIndexPayload(encoded, sender, kind)
end

function SND:HandleRecipeChunk(payload, sender)
  -- Try RCP_FULL first (longer pattern), then fall back to RCP
  -- Note: Lua patterns don't support | alternation like regex
  local _, _, kind, _, _, msgId, seq, total, chunk = string.find(payload, "^(RCP_FULL)%|(.-)%|(.-)%|(.-)%|(.-)/(.-)%|(.*)$")
  if not kind then
    _, _, kind, _, _, msgId, seq, total, chunk = string.find(payload, "^(RCP)%|(.-)%|(.-)%|(.-)%|(.-)/(.-)%|(.*)$")
  end

  if not msgId then
    -- Fallback: try simple envelope format (non-chunked)
    local rawKind, encoded = string.match(payload, "^(RCP_FULL)%|(.*)$")
    if not rawKind then
      rawKind, encoded = string.match(payload, "^(RCP)%|(.*)$")
    end
    if rawKind and encoded then
      self:IngestRecipeIndexPayload(encoded, sender, rawKind)
    end
    return
  end

  local key = sender .. "|" .. msgId
  local buffer = self.comms.chunkBuffer[key]
  if not buffer then
    buffer = { parts = {}, total = tonumber(total) or 0, receivedAt = self:Now(), receivedCount = 0 }
    self.comms.chunkBuffer[key] = buffer
    debugComms(self, string.format(
      "Comms: chunk start kind=%s from=%s msgId=%s total=%d",
      tostring(kind),
      tostring(sender),
      tostring(msgId),
      buffer.total
    ))
  end
  if self:Now() - buffer.receivedAt > self.comms.chunkTimeout then
    self.comms.chunkBuffer[key] = nil
    return
  end

  local index = tonumber(seq)
  if index and not buffer.parts[index] then
    buffer.parts[index] = chunk
    buffer.receivedCount = (buffer.receivedCount or 0) + 1
  end

  local complete = true
  for i = 1, buffer.total do
    if not buffer.parts[i] then
      complete = false
      break
    end
  end
  if not complete then
    return
  end

  local combined = table.concat(buffer.parts, "")
  self.comms.chunkBuffer[key] = nil

  debugComms(self, string.format(
    "Comms: chunk complete kind=%s from=%s msgId=%s chunks=%d/%d bytes=%d",
    tostring(kind),
    tostring(sender),
    tostring(msgId),
    buffer.receivedCount or 0,
    buffer.total,
    #combined
  ))

  self:IngestRecipeIndexPayload(combined, sender, kind)
end

function SND:PassRateLimit(sender)
  if not sender then
    return false
  end
  local now = self:Now()
  self.comms.rateState = self.comms.rateState or {}
  local state = self.comms.rateState[sender]
  if not state then
    state = { count = 0, start = now }
    self.comms.rateState[sender] = state
  end
  if now - state.start > self.comms.rate.window then
    state.start = now
    state.count = 0
  end
  state.count = state.count + 1
  return state.count <= self.comms.rate.max
end

function SND:IsGuildMember(sender)
  if not sender or sender == "" then
    return false
  end

  local nameOnly = strsplit("-", sender)

  local cache = self.comms.guildMemberCache
  if type(cache) ~= "table" then
    cache = {}
    self.comms.guildMemberCache = cache
  end

  if cache[nameOnly] then
    return true
  end

  local lastRefresh = tonumber(self.comms.guildMemberCacheLastRefresh) or 0
  if (self:Now() - lastRefresh) >= 30 then
    -- Conservative fallback refresh in case roster events were delayed.
    self:RefreshGuildMemberCacheFromRoster()
    return self.comms.guildMemberCache[nameOnly] == true
  end

  return false
end
