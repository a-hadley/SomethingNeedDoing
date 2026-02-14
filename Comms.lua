local addonName = ...
local SND = _G[addonName]

local AceComm = LibStub("AceComm-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate")

SND.comms = {
  prefix = "SND",
  version = 2,
  rate = { window = 5, max = 25 },
  chunkTimeout = 10,
  fullSyncInterval = 60,  -- Reduced from 300 to 60 seconds for faster updates
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
  self.comms.pendingCombatMessages = self.comms.pendingCombatMessages or {}
  self.comms.inCombat = false
  if self.comms.sendLegacyRecipeChunks == nil then
    self.comms.sendLegacyRecipeChunks = false
  end

  self:RefreshGuildMemberCacheFromRoster()

  -- Combat state tracking for comms
  self:RegisterEvent("PLAYER_REGEN_DISABLED", function(selfRef)
    selfRef.comms.inCombat = true
  end)
  self:RegisterEvent("PLAYER_REGEN_ENABLED", function(selfRef)
    selfRef.comms.inCombat = false
    -- Process pending messages after combat
    if #selfRef.comms.pendingCombatMessages > 0 then
      debugComms(selfRef, string.format("Comms: combat ended, processing %d pending messages", #selfRef.comms.pendingCombatMessages))
      for _, msgData in ipairs(selfRef.comms.pendingCombatMessages) do
        selfRef:HandleAddonMessage(msgData.payload, msgData.channel, msgData.sender)
      end
      selfRef.comms.pendingCombatMessages = {}
    end
  end)

  self.comms.ace:RegisterComm(self.comms.prefix, function(prefix, payload, channel, sender)
    -- Debug: Track message reception
    local messageType = payload and payload:match("^([^|]+)") or "UNKNOWN"
    if self.db and self.db.config and self.db.config.debugMode then
      debugComms(self, string.format("RX: %s from %s on %s", messageType, tostring(sender), tostring(channel)))
    end

    -- Combat protection: queue messages during combat
    if InCombatLockdown() then
      self.comms.inCombat = true
      table.insert(self.comms.pendingCombatMessages, {
        payload = payload,
        channel = channel,
        sender = sender
      })
      if self.db and self.db.config and self.db.config.debugMode then
        debugComms(self, string.format("QUEUED during combat: %s from %s", messageType, tostring(sender)))
      end
      return
    end

    if not self:PassRateLimit(sender) then
      if self.db and self.db.config and self.db.config.debugMode then
        debugComms(self, string.format("RATE LIMITED: %s from %s", messageType, tostring(sender)))
      end
      return
    end
    if not self:IsGuildMember(sender) then
      if self.db and self.db.config and self.db.config.debugMode then
        debugComms(self, string.format("NOT GUILD MEMBER: %s from %s", messageType, tostring(sender)))
      end
      return
    end
    self:HandleAddonMessage(payload, channel, sender)
  end)

  if self.comms.fullSyncTicker then
    self:CancelSNDTimer(self.comms.fullSyncTicker)
  end
  self.comms.fullSyncTicker = self:ScheduleSNDRepeatingTimer(self.comms.fullSyncInterval, function()
    self:BroadcastFullState("ticker")
  end)
  -- Reduced startup delay from 8 to 2 seconds for faster initial sync
  self:ScheduleSNDTimer(2, function()
    self:BroadcastFullState("startup")
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
    self:DebugOnlyLog("RX " .. tostring(channel) .. " " .. tostring(sender) .. " " .. tostring(messageType))
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

  self:SendRecipeIndex(true)
  self:SendMatsSnapshot(self:SnapshotSharedMats() or {}, true)
  if type(self.SendRequestFullState) == "function" then
    self:SendRequestFullState()
  end
  self.comms.lastFullSyncAt = self:Now()
  debugComms(self, string.format(
    "Comms: full-state rebroadcast sent at=%d next=%d",
    self.comms.lastFullSyncAt,
    self.comms.lastFullSyncAt + interval
  ))
end

function SND:SendHello()
  local payload = string.format("HELLO|%d", self.comms.version)
  self:SendAddonMessage(payload)
end

function SND:SendProfSummary()
  local payload = string.format("PROF|%d", self.comms.version)
  self:SendAddonMessage(payload)
end

function SND:SendAddonMessage(payload, priority)
  -- Combat protection: don't send messages during combat
  if InCombatLockdown() then
    debugComms(self, "Comms: message send blocked during combat")
    return
  end
  -- Priority: "BULK" (low), "NORMAL" (default), "ALERT" (high/immediate)
  -- Request messages use "ALERT" to bypass throttling for instant updates
  local prio = priority or "NORMAL"
  self.comms.ace:SendCommMessage(self.comms.prefix, payload, "GUILD", nil, prio)
end

function SND:HandleHello(payload, sender)
  self:DebugOnlyLog("HELLO from " .. tostring(sender))
end

function SND:HandleProf(payload, sender)
  self:DebugOnlyLog("PROF from " .. tostring(sender))
end

function SND:HandleRequestMessage(payload, kind, sender)
  local encoded = string.match(payload, "^" .. kind .. "%|(.*)$")
  if not encoded then
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    return
  end
  local ok, message = self.comms.serializer:Deserialize(inflated)
  if not ok or type(message) ~= "table" then
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
              "|cffff8000Request Status Changed:|r %s → |cff00ff00%s|r",
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
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    return
  end
  local ok, message = self.comms.serializer:Deserialize(inflated)
  if not ok or type(message) ~= "table" then
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
    return
  end
  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    return
  end
  local ok, incomingPayload = self.comms.serializer:Deserialize(inflated)
  if not ok or type(incomingPayload) ~= "table" then
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
    "Publish: recipe index send entries=%d payloadBytes=%d transport=%s full=%s",
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
      "Publish: recipe index legacy-compat send chunks=%d kind=%s",
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
  local msgId = tostring(math.random(1000, 9999)) .. tostring(self:Now())
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
    "IngestRecipeIndexPayload: ENTER sender=%s kind=%s encoded_len=%d",
    tostring(sender),
    tostring(kind),
    encoded and #encoded or 0
  ))

  if type(encoded) ~= "string" or encoded == "" then
    debugComms(self, "IngestRecipeIndexPayload: ABORT - invalid encoded string")
    return
  end

  if #encoded > 80000 then
    debugComms(self, string.format("IngestRecipeIndexPayload: ABORT - encoded too large (%d bytes)", #encoded))
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    debugComms(self, "IngestRecipeIndexPayload: ABORT - decode failed")
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    debugComms(self, "IngestRecipeIndexPayload: ABORT - decompress failed")
    return
  end
  local ok, recipeIndex = self.comms.serializer:Deserialize(inflated)
  if ok and type(recipeIndex) == "table" then
    local mergedCount = 0
    local newRecipesLearned = {}
    local now = self:Now()
    local senderKey = self:GetPlayerKey(strsplit("-", sender)) or sender
    local senderName = strsplit("-", sender)

    -- Ensure sender player entry exists
    local senderEntry = self.db.players[senderKey] or {}
    senderEntry.professions = senderEntry.professions or {}

    for recipeSpellID, entry in pairs(recipeIndex) do
      local incoming = normalizeRecipeEntry(entry, recipeSpellID, now, senderKey)
      local existing = self.db.recipeIndex[recipeSpellID]
      if incoming and incomingWins(incoming, existing, recipeSpellID) then
        self.db.recipeIndex[recipeSpellID] = incoming
        mergedCount = mergedCount + 1

        -- BUGFIX: Also populate sender's profession.recipes table
        -- This ensures GetCraftersForRecipe can find remote players
        if incoming.professionSkillLineID then
          local profKey = incoming.professionSkillLineID
          local profEntry = senderEntry.professions[profKey] or {}
          profEntry.recipes = profEntry.recipes or {}

          -- Track if this is a NEW recipe for this player
          local isNewRecipe = not profEntry.recipes[recipeSpellID]
          if isNewRecipe then
            table.insert(newRecipesLearned, {
              recipeSpellID = recipeSpellID,
              recipeName = incoming.name or ("Recipe " .. tostring(recipeSpellID))
            })
          end

          profEntry.recipes[recipeSpellID] = true
          senderEntry.professions[profKey] = profEntry
        end
      end
    end

    -- Save updated sender entry back to DB
    self.db.players[senderKey] = senderEntry

    -- Notify user about new recipes learned by other players
    -- Only show if notifications enabled and not in combat
    local showNotifications = self.db and self.db.config and self.db.config.showNotifications
    if showNotifications and #newRecipesLearned > 0 and senderKey ~= self:GetPlayerKey(UnitName("player")) and not InCombatLockdown() then
      for _, recipeData in ipairs(newRecipesLearned) do
        local outputName = self:GetRecipeOutputItemName(recipeData.recipeSpellID)
        local displayName = outputName or recipeData.recipeName
        self:Print(string.format("|cff00ff00%s|r learned: |cffffd700%s|r", senderName or "Someone", displayName))
      end
    end

    debugComms(self, string.format(
      "Ingest: recipe index merge sender=%s kind=%s merged=%d localRecipeIndex=%d",
      tostring(sender),
      tostring(kind),
      mergedCount,
      countTableEntries(self.db and self.db.recipeIndex)
    ))

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
    debugComms(self, string.format(
      "IngestRecipeIndexPayload: ABORT - deserialize failed (ok=%s type=%s)",
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
      "HandleRecipeEnvelope: pattern match failed for payload from %s (len=%d)",
      tostring(sender),
      payload and #payload or 0
    ))
    return
  end

  debugComms(self, string.format(
    "HandleRecipeEnvelope: matched kind=%s encoded_len=%d sender=%s",
    tostring(kind),
    encoded and #encoded or 0,
    tostring(sender)
  ))

  self:IngestRecipeIndexPayload(encoded, sender, kind)
end

function SND:HandleRecipeChunk(payload, sender)
  -- Try RCP_FULL first (longer pattern), then fall back to RCP
  -- Note: Lua patterns don't support | alternation like regex
  local _, _, kind, version, senderName, msgId, seq, total, chunk = string.find(payload, "^(RCP_FULL)%|(.-)%|(.-)%|(.-)%|(.-)/(.-)%|(.*)$")
  if not kind then
    _, _, kind, version, senderName, msgId, seq, total, chunk = string.find(payload, "^(RCP)%|(.-)%|(.-)%|(.-)%|(.-)/(.-)%|(.*)$")
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
    self:DebugOnlyLog(string.format(
      "RX CHUNK START %s sender=%s msgId=%s total=%d",
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

  self:DebugOnlyLog(string.format(
    "RX CHUNK DONE %s sender=%s msgId=%s chunks=%d/%d bytes=%d",
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
