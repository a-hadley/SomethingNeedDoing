local addonName = ...
local SND = _G[addonName]

-- ============================================================================
-- Craft Log Entry Creation
-- ============================================================================

function SND:RecordCraftLogEntry(requestId, request)
  if not requestId or type(request) ~= "table" then
    return nil
  end
  if request.status ~= "DELIVERED" then
    return nil
  end

  self.db.craftLog = self.db.craftLog or {}

  local logId = "log-" .. self:HashString(requestId)

  -- Don't overwrite if already recorded
  if self.db.craftLog[logId] then
    return logId
  end

  local recipe = self.db.recipeIndex and self.db.recipeIndex[request.recipeSpellID] or nil
  local now = self:Now()

  local entry = {
    id = logId,
    entityType = "CRAFT_LOG",
    recipeSpellID = request.recipeSpellID,
    itemID = request.itemID or self:GetRecipeOutputItemID(request.recipeSpellID),
    qty = request.qty or 1,
    professionSkillLineID = recipe and recipe.professionSkillLineID or nil,
    professionName = recipe and (recipe.professionName or recipe.profession or self:GetProfessionNameBySkillLineID(recipe.professionSkillLineID)) or nil,
    crafter = request.claimedBy or request.updatedBy,
    requester = request.requester,
    deliveredAt = request.updatedAt or now,
    updatedAtServer = now,
    updatedBy = self:GetPlayerKey(UnitName("player")),
    version = 1,
  }

  self.db.craftLog[logId] = entry
  if type(self.MarkDirty) == "function" then
    self:MarkDirty("craftLog", logId)
  end
  self:SendCraftLogEntry(entry)
  self:InvalidateStatsCache()

  return logId
end

-- Record from inbound comms (no broadcast)
function SND:IngestCraftLogEntry(entry)
  if type(entry) ~= "table" or not entry.id then
    return false
  end

  self.db.craftLog = self.db.craftLog or {}

  local existing = self.db.craftLog[entry.id]
  if existing then
    -- LWW: only update if incoming is newer
    local inTs = tonumber(entry.updatedAtServer) or 0
    local exTs = tonumber(existing.updatedAtServer) or 0
    if inTs <= exTs then
      return false
    end
  end

  self.db.craftLog[entry.id] = entry
  self:InvalidateStatsCache()
  return true
end

-- ============================================================================
-- Comms: Send/Receive Craft Log
-- ============================================================================

function SND:SendCraftLogEntry(entry)
  if type(entry) ~= "table" then
    return
  end
  local serialized = self.comms.serializer:Serialize(entry)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  self:SendAddonMessage(string.format("STAT_LOG|%s", encoded), "ALERT")
end

function SND:SendCraftLogFullState()
  self.db.craftLog = self.db.craftLog or {}
  local payload = {
    craftLog = self.db.craftLog,
    updatedAtServer = self:Now(),
    updatedBy = self:GetPlayerKey(UnitName("player")),
  }
  local serialized = self.comms.serializer:Serialize(payload)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  self:SendAddonMessage(string.format("STAT_FULL|%s", encoded))
end

function SND:HandleStatLogMessage(payload, sender)
  local encoded = string.match(payload, "^STAT_LOG%|(.*)$")
  if not encoded then
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    self:DebugOnlyLog(string.format("Stats: HandleStatLogMessage decode failed from=%s", tostring(sender)))
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    self:DebugOnlyLog(string.format("Stats: HandleStatLogMessage decompress failed from=%s", tostring(sender)))
    return
  end
  local ok, entry = self.comms.serializer:Deserialize(inflated)
  if not ok or type(entry) ~= "table" then
    self:DebugOnlyLog(string.format("Stats: HandleStatLogMessage deserialize failed from=%s", tostring(sender)))
    return
  end

  if self:IngestCraftLogEntry(entry) then
    self:RefreshStatsTabIfVisible()
  end
end

function SND:HandleStatFullMessage(payload, sender)
  local encoded = string.match(payload, "^STAT_FULL%|(.*)$")
  if not encoded then
    return
  end

  local decoded = self.comms.deflate:DecodeForWoWAddonChannel(encoded)
  if not decoded then
    self:DebugOnlyLog(string.format("Stats: HandleStatFullMessage decode failed from=%s", tostring(sender)))
    return
  end
  local inflated = self.comms.deflate:DecompressDeflate(decoded)
  if not inflated then
    self:DebugOnlyLog(string.format("Stats: HandleStatFullMessage decompress failed from=%s", tostring(sender)))
    return
  end
  local ok, message = self.comms.serializer:Deserialize(inflated)
  if not ok or type(message) ~= "table" then
    self:DebugOnlyLog(string.format("Stats: HandleStatFullMessage deserialize failed from=%s", tostring(sender)))
    return
  end

  local craftLog = type(message.craftLog) == "table" and message.craftLog or {}
  local merged = 0
  for logId, entry in pairs(craftLog) do
    if type(entry) == "table" then
      entry.id = entry.id or logId
      if self:IngestCraftLogEntry(entry) then
        merged = merged + 1
      end
    end
  end

  if merged > 0 then
    self:RefreshStatsTabIfVisible()
  end
end

-- ============================================================================
-- Stats Cache
-- ============================================================================

function SND:InvalidateStatsCache()
  self.statsCache = nil
end

function SND:RebuildStatsCache()
  local now = self:Now()
  local weekAgo = now - (7 * 24 * 60 * 60)
  local monthAgo = now - (30 * 24 * 60 * 60)

  local byPlayer = {}

  for _, entry in pairs(self.db.craftLog or {}) do
    if type(entry) == "table" and entry.crafter then
      local playerKey = entry.crafter
      local qty = tonumber(entry.qty) or 1
      local deliveredAt = tonumber(entry.deliveredAt) or 0
      local profKey = entry.professionName
          or (entry.professionSkillLineID and self:GetProfessionNameBySkillLineID(entry.professionSkillLineID))
          or "Unknown"

      if not byPlayer[playerKey] then
        byPlayer[playerKey] = {
          total = 0,
          weekly = 0,
          monthly = 0,
          byProfession = {},
          byItem = {},
        }
      end

      local stats = byPlayer[playerKey]
      stats.total = stats.total + qty
      if deliveredAt >= weekAgo then
        stats.weekly = stats.weekly + qty
      end
      if deliveredAt >= monthAgo then
        stats.monthly = stats.monthly + qty
      end

      if not stats.byProfession[profKey] then
        stats.byProfession[profKey] = { total = 0, weekly = 0, monthly = 0 }
      end
      local profStats = stats.byProfession[profKey]
      profStats.total = profStats.total + qty
      if deliveredAt >= weekAgo then
        profStats.weekly = profStats.weekly + qty
      end
      if deliveredAt >= monthAgo then
        profStats.monthly = profStats.monthly + qty
      end

      -- Track per-item counts
      local itemKey = entry.recipeSpellID
      if itemKey then
        if not stats.byItem[itemKey] then
          stats.byItem[itemKey] = { total = 0, weekly = 0, monthly = 0 }
        end
        local itemStats = stats.byItem[itemKey]
        itemStats.total = itemStats.total + qty
        if deliveredAt >= weekAgo then
          itemStats.weekly = itemStats.weekly + qty
        end
        if deliveredAt >= monthAgo then
          itemStats.monthly = itemStats.monthly + qty
        end
      end
    end
  end

  self.statsCache = {
    byPlayer = byPlayer,
    builtAt = now,
  }

  return self.statsCache
end

function SND:EnsureStatsCache()
  if not self.statsCache then
    self:RebuildStatsCache()
  end
  return self.statsCache
end

-- ============================================================================
-- Leaderboard Queries
-- ============================================================================

function SND:GetLeaderboard(period, professionFilter)
  local cache = self:EnsureStatsCache()
  period = period or "total"

  local results = {}
  for playerKey, stats in pairs(cache.byPlayer) do
    local count = 0
    if professionFilter and professionFilter ~= "All" then
      local profStats = stats.byProfession[professionFilter]
      if profStats then
        count = profStats[period] or 0
      end
    else
      count = stats[period] or 0
    end

    if count > 0 then
      local shortName = playerKey:match("^([^%-]+)") or playerKey

      -- Find top profession for this player in the selected period
      local topProf, topProfCount = nil, 0
      for profName, profStats in pairs(stats.byProfession) do
        local profCount = profStats[period] or 0
        if profCount > topProfCount then
          topProf = profName
          topProfCount = profCount
        end
      end

      -- Find top item for this player in the selected period
      local topItemKey, topItemCount = nil, 0
      for itemKey, itemStats in pairs(stats.byItem or {}) do
        local itemCount = itemStats[period] or 0
        if itemCount > topItemCount then
          topItemKey = itemKey
          topItemCount = itemCount
        end
      end

      local topItemName = nil
      if topItemKey then
        topItemName = self:GetRecipeOutputItemName(topItemKey) or "Unknown"
      end

      table.insert(results, {
        playerKey = playerKey,
        name = shortName,
        count = count,
        topProfession = topProf,
        topItem = topItemName,
      })
    end
  end

  table.sort(results, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.name < b.name
  end)

  -- Assign ranks
  for i, entry in ipairs(results) do
    entry.rank = i
  end

  return results
end

function SND:GetPlayerStats(playerKey)
  local cache = self:EnsureStatsCache()
  return cache.byPlayer[playerKey] or nil
end

-- ============================================================================
-- History Queries
-- ============================================================================

function SND:GetCraftHistory(filters)
  filters = filters or {}
  local query = string.lower((filters.query or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  local crafterFilter = filters.crafter
  local requesterFilter = filters.requester
  local professionFilter = filters.profession

  local results = {}
  for _, entry in pairs(self.db.craftLog or {}) do
    if type(entry) == "table" then
      local matches = true

      if crafterFilter and crafterFilter ~= "" then
        local crafterShort = (entry.crafter or ""):match("^([^%-]+)") or ""
        if string.lower(crafterShort) ~= string.lower(crafterFilter) then
          matches = false
        end
      end

      if requesterFilter and requesterFilter ~= "" then
        local requesterShort = (entry.requester or ""):match("^([^%-]+)") or ""
        if string.lower(requesterShort) ~= string.lower(requesterFilter) then
          matches = false
        end
      end

      if professionFilter and professionFilter ~= "All" then
        local entryProfName = entry.professionName
            or (entry.professionSkillLineID and self:GetProfessionNameBySkillLineID(entry.professionSkillLineID))
            or "Unknown"
        if entryProfName ~= professionFilter then
          matches = false
        end
      end

      if query ~= "" and matches then
        local crafterName = string.lower((entry.crafter or ""):match("^([^%-]+)") or "")
        local requesterName = string.lower((entry.requester or ""):match("^([^%-]+)") or "")
        local itemName = string.lower(self:GetRecipeOutputItemName(entry.recipeSpellID) or "")
        if not (string.find(crafterName, query, 1, true)
            or string.find(requesterName, query, 1, true)
            or string.find(itemName, query, 1, true)) then
          matches = false
        end
      end

      if matches then
        table.insert(results, entry)
      end
    end
  end

  table.sort(results, function(a, b)
    return (a.deliveredAt or 0) > (b.deliveredAt or 0)
  end)

  return results
end

-- ============================================================================
-- Purge Old Entries
-- ============================================================================

function SND:PurgeStaleCraftLog()
  local now = self:Now()
  local cutoff = now - (180 * 24 * 60 * 60) -- 6 months
  local removed = 0

  for logId, entry in pairs(self.db.craftLog or {}) do
    if type(entry) == "table" and entry.deliveredAt and entry.deliveredAt < cutoff then
      self.db.craftLog[logId] = nil
      removed = removed + 1
    end
  end

  if removed > 0 then
    self:InvalidateStatsCache()
    self:DebugLog(string.format("Stats: PurgeStaleCraftLog removed=%d (older than 6 months)", removed), true)
  end
end

-- ============================================================================
-- UI Refresh Helper
-- ============================================================================

function SND:RefreshStatsTabIfVisible()
  if not self.mainFrame or not self.mainFrame.contentFrames then
    return
  end
  -- Stats tab is index 3 (Directory=1, Requests=2, Stats=3, Options=4)
  if self.mainFrame.activeTab == 3 then
    local statsFrame = self.mainFrame.contentFrames[3]
    if statsFrame and type(self.RefreshStatsTab) == "function" then
      self:RefreshStatsTab(statsFrame)
    end
  end
end
