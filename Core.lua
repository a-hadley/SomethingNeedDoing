local addonName = ...

local AceAddon = LibStub("AceAddon-3.0")
local AceLocale = LibStub("AceLocale-3.0", true)
local SND = AceAddon:GetAddon(addonName, true)
if not SND then
  SND = AceAddon:NewAddon(addonName, "AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0", "AceBucket-3.0")
end
_G[addonName] = SND

local fallbackLocale = setmetatable({}, {
  __index = function(_, key)
    return key
  end,
})

SND.L = SND.L or (AceLocale and AceLocale:GetLocale(addonName, true)) or fallbackLocale

function SND:Tr(key, ...)
  if AceLocale and (not self.L or self.L == fallbackLocale) then
    local resolved = AceLocale:GetLocale(addonName, true)
    if resolved then
      self.L = resolved
    end
  end
  local value = (self.L and self.L[key]) or key
  if select("#", ...) > 0 then
    return string.format(value, ...)
  end
  return value
end

SND._eventHandlers = SND._eventHandlers or {}
SND._eventWrappers = SND._eventWrappers or {}

local AceRegisterEvent = SND.RegisterEvent
local AceUnregisterEvent = SND.UnregisterEvent

function SND:RegisterEvent(event, handler)
  if type(handler) == "function" then
    self._eventHandlers[event] = handler
    if self._eventWrappers[event] then
      AceUnregisterEvent(self, event)
    end
    local wrapper = function(_, ...)
      local current = self._eventHandlers[event]
      if current then
        current(self, ...)
      end
    end
    self._eventWrappers[event] = wrapper
    return AceRegisterEvent(self, event, wrapper)
  end
  return AceRegisterEvent(self, event, handler)
end

function SND:UnregisterEvent(event)
  self._eventHandlers[event] = nil
  self._eventWrappers[event] = nil
  return AceUnregisterEvent(self, event)
end

function SND:Initialize()
  local getMetadata = GetAddOnMetadata or (C_AddOns and C_AddOns.GetAddOnMetadata)
  self.addonVersion = getMetadata and getMetadata(addonName, "Version") or "0.0.0"
  self:InitDB()
  self:EnsureScanLogBuffer()
  self:DebugLog("Core: startup debug sink initialized", true)
  self:InitUI()
  self:InitComms()
  self:InitRoster()
  self:InitScanner()
  self:InitItemCache()
  self:InitRequests()
  self:InitMinimapButton()
  self:InitOptions()
  self:RegisterSlashCommands()
  self:SendHello()
  self:PurgeStaleData()
  -- Run PurgeStaleData periodically (every 30 minutes)
  self:ScheduleSNDRepeatingTimer(1800, function()
    self:PurgeStaleData()
  end)
end

function SND:OnInitialize()
  self:Initialize()
end

-- ============================================================================
-- Item Cache Manager
-- NOTE: Item cache functions have been moved to modules/ItemCache.lua
-- ============================================================================

-- ============================================================================
-- Recipe Data Resolution
-- NOTE: Recipe data functions have been moved to modules/RecipeData.lua
-- ============================================================================

-- ============================================================================
-- Recipe Search
-- NOTE: Recipe search functions have been moved to modules/RecipeSearch.lua
-- NOTE: NormalizeRecipeSpellID is now defined in RecipeSearch module
-- ============================================================================

-- ============================================================================
-- Directory UI
-- NOTE: Directory UI functions have been moved to modules/DirectoryUI.lua
-- ============================================================================

-- ============================================================================
-- Request Management UI
-- NOTE: Request UI functions have been moved to requests/RequestUI.lua
-- ============================================================================

-- ============================================================================
-- Utility Functions
-- ============================================================================

function SND:WhisperPlayer(playerName, itemLink, itemText, recipeSpellID)
  if not playerName then
    return
  end

  -- If item context is provided, pre-fill a message
  if itemLink or itemText or recipeSpellID then
    local itemDisplay = itemLink or itemText or "an item"

    -- Try to get the recipe/spell link
    local recipeLink = nil
    if recipeSpellID then
      recipeLink = GetSpellLink(recipeSpellID)
    end

    -- Build message with item and optional recipe link
    local message
    if recipeLink then
      message = string.format("/w %s Hi! I'd like to request %s (Recipe: %s). Can you craft this?",
        playerName, itemDisplay, recipeLink)
    else
      message = string.format("/w %s Hi! I'd like to request %s. Can you craft this?",
        playerName, itemDisplay)
    end

    if ChatFrame_OpenChat then
      ChatFrame_OpenChat(message)
    end
  else
    -- Just open empty whisper window
    if ChatFrame_SendTell then
      ChatFrame_SendTell(playerName)
    end
  end
end

function SND:WhisperCrafter(recipeSpellID)
  if not recipeSpellID then
    return
  end
  local directoryFrame = self.mainFrame and self.mainFrame.contentFrames and self.mainFrame.contentFrames[1]
  if not directoryFrame then
    return
  end
  local filters = {
    professionName = directoryFrame.selectedProfession,
    onlineOnly = directoryFrame.onlineOnly,
  }
  local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
  local target = crafters[1]
  if target then
    -- Get the item link and recipe link for context
    local itemLink = self:GetRecipeOutputItemLink(recipeSpellID)
    local itemText = self:GetRecipeOutputItemName(recipeSpellID)
    self:WhisperPlayer(target.name, itemLink, itemText, recipeSpellID)
  end
end

function SND:GetDatabaseStats()
  local totalPlayers, onlinePlayers = 0, 0
  for _, player in pairs(self.db.players or {}) do
    totalPlayers = totalPlayers + 1
    if player.online then onlinePlayers = onlinePlayers + 1 end
  end

  local recipesByProfession = {}
  for _, entry in pairs(self.db.recipeIndex or {}) do
    local profID = entry.professionSkillLineID
    local profName = profID and self:GetProfessionNameBySkillLineID(profID) or "Unknown"
    recipesByProfession[profName] = (recipesByProfession[profName] or 0) + 1
  end

  local totalRequests = 0
  for _ in pairs(self.db.requests or {}) do
    totalRequests = totalRequests + 1
  end

  local craftLogEntries = 0
  for _ in pairs(self.db.craftLog or {}) do
    craftLogEntries = craftLogEntries + 1
  end

  return {
    totalPlayers = totalPlayers,
    onlinePlayers = onlinePlayers,
    recipesByProfession = recipesByProfession,
    totalRequests = totalRequests,
    craftLogEntries = craftLogEntries,
  }
end

function SND:RefreshMeTab(meFrame)
  meFrame = meFrame or self.meTabFrame or (self.mainFrame and self.mainFrame.contentFrames and self.mainFrame.contentFrames[4])
  if not meFrame or not meFrame.scanStatus or not meFrame.professionsList then
    if self.TraceScanLog then
      self:TraceScanLog("Trace: RefreshMeTab skipped (frame unavailable)")
    end
    return
  end

  self.meTabFrame = meFrame

  if self.TraceScanLog then
    self:TraceScanLog("Trace: RefreshMeTab begin")
  end

  self:RefreshScanLogBox()

  local lastScan = self.scanner and self.scanner.lastScan or 0
  if lastScan > 0 then
    meFrame.scanStatus:SetText(self:Tr("Last scan: %s", date("%Y-%m-%d %H:%M", lastScan)))
  else
    meFrame.scanStatus:SetText(self:Tr("Last scan: -"))
  end

  local playerKey = self:GetPlayerKey(UnitName("player"))
  local entry = self.db.players[playerKey]
  if not entry or not entry.professions then
    meFrame.professionsList:SetText(self:Tr("Professions: -"))
  else
    local profLines = {}
    for _, prof in pairs(entry.professions) do
      table.insert(profLines, string.format("%s %d/%d", prof.name or "", prof.rank or 0, prof.maxRank or 0))
    end
    table.sort(profLines)
    if #profLines == 0 then
      meFrame.professionsList:SetText(self:Tr("Professions: -"))
    else
      meFrame.professionsList:SetText(self:Tr("Professions: %s", table.concat(profLines, " | ")))
    end
  end

  if meFrame.matsStatus then
    local lastPublish = self.scanner and self.scanner.lastMatsPublish or 0
    if lastPublish > 0 then
      meFrame.matsStatus:SetText(self:Tr("Mats publish: %s", date("%Y-%m-%d %H:%M", lastPublish)))
    else
      meFrame.matsStatus:SetText(self:Tr("Mats publish: -"))
    end
  end

  if meFrame.matsSummary then
    local contributors = 0
    for _, player in pairs(self.db.players) do
      if player.sharedMats then
        contributors = contributors + 1
      end
    end
    if contributors == 0 then
      meFrame.matsSummary:SetText(self:Tr("Shared mats contributors: -"))
    else
      meFrame.matsSummary:SetText(self:Tr("Shared mats contributors: %d", contributors))
    end
  end

  if meFrame.dbStatsText then
    local dbStats = self:GetDatabaseStats()
    local ps = self:GetPeerStats()
    local lines = {
      string.format("Players: %d (%d online)", dbStats.totalPlayers, dbStats.onlinePlayers),
      string.format("Requests: %d  |  Craft Log: %d", dbStats.totalRequests, dbStats.craftLogEntries),
    }
    -- Recipes by profession
    local profList = {}
    for name, count in pairs(dbStats.recipesByProfession) do
      table.insert(profList, { name = name, count = count })
    end
    table.sort(profList, function(a, b) return a.name < b.name end)
    for _, prof in ipairs(profList) do
      table.insert(lines, string.format("  %s: %d", prof.name, prof.count))
    end
    -- Peer addon versions
    table.insert(lines, string.format("Addon peers: %d  |  v%s (you): %d  |  Other: %d",
      ps.totalPeers, ps.localVersion, ps.onCurrentVersion, ps.outdated))
    local verList = {}
    for ver, count in pairs(ps.byVersion) do
      if ver ~= ps.localVersion then
        table.insert(verList, { ver = ver, count = count })
      end
    end
    table.sort(verList, function(a, b) return a.ver > b.ver end)
    for _, v in ipairs(verList) do
      table.insert(lines, string.format("  v%s: %d", v.ver, v.count))
    end
    meFrame.dbStatsText:SetText(table.concat(lines, "\n"))
  end

  if meFrame.commsStatsText then
    local cs = self:GetCommsMessageCounts()
    local lines = {}

    -- Authority & network role
    local authorityLabel = cs.authority or "unknown"
    if cs.isAuthority then
      authorityLabel = "|cff00ff00" .. authorityLabel .. " (you)|r"
    end
    table.insert(lines, string.format("Authority: %s  |  Peers: %d  |  Next sync: %ds",
      authorityLabel, cs.peerCount, cs.nextFullSync))

    -- RX traffic
    table.insert(lines, string.format("RX: %d (1m) / %d (5m) / %d (60m)",
      cs.oneMin, cs.fiveMin, cs.sixtyMin))
    local rxList = {}
    for msgType, count in pairs(cs.byType) do
      table.insert(rxList, { name = msgType, count = count })
    end
    table.sort(rxList, function(a, b) return a.count > b.count end)
    local rxParts = {}
    for _, rx in ipairs(rxList) do
      table.insert(rxParts, string.format("%s: %d", rx.name, rx.count))
    end
    if #rxParts > 0 then
      table.insert(lines, "  " .. table.concat(rxParts, "  |  "))
    end

    -- TX traffic
    table.insert(lines, string.format("TX: %d total", cs.totalSent))
    local txList = {}
    for msgType, count in pairs(cs.sent) do
      table.insert(txList, { name = msgType, count = count })
    end
    table.sort(txList, function(a, b) return a.count > b.count end)
    local txParts = {}
    for _, tx in ipairs(txList) do
      table.insert(txParts, string.format("%s: %d", tx.name, tx.count))
    end
    if #txParts > 0 then
      table.insert(lines, "  " .. table.concat(txParts, "  |  "))
    end

    -- Health
    local healthParts = {}
    if cs.rateLimited > 0 then table.insert(healthParts, string.format("|cffff0000Rate limited: %d|r", cs.rateLimited)) end
    if cs.errors > 0 then table.insert(healthParts, string.format("|cffff0000Errors: %d|r", cs.errors)) end
    if cs.nonGuild > 0 then table.insert(healthParts, string.format("Non-guild: %d", cs.nonGuild)) end
    if cs.sendBlocked > 0 then table.insert(healthParts, string.format("Send blocked: %d", cs.sendBlocked)) end
    if cs.combatQueued > 0 then table.insert(healthParts, string.format("Combat queued: %d", cs.combatQueued)) end
    if cs.dirtyCount > 0 then table.insert(healthParts, string.format("Dirty: %d", cs.dirtyCount)) end
    if cs.chunkBuffers > 0 then table.insert(healthParts, string.format("Chunks pending: %d", cs.chunkBuffers)) end
    if #healthParts > 0 then
      table.insert(lines, table.concat(healthParts, "  |  "))
    end

    meFrame.commsStatsText:SetText(table.concat(lines, "\n"))
  end
end

function SND:RefreshScanLogBox()
  self:EnsureScanLogBuffer()
  local maxLines = self.scanLogMaxLines or 200
  local totalLines = #self.scanLogBuffer
  local startIndex = math.max(1, totalLines - maxLines + 1)

  self._scanLogPendingDirty = false
  local uiLogKey = string.format("%d|%d", totalLines, maxLines)
  if self._lastScanLogUiKey ~= uiLogKey and self.TraceScanLog then
    self:TraceScanLog(string.format("Trace: ScanLog ui-write lines=%d start=%d", totalLines, startIndex))
  end
  self._lastScanLogUiKey = uiLogKey

  if type(self.RefreshOptions) == "function" then
    self:RefreshOptions()
  end

  if self.scanLogCopyModal and self.scanLogCopyModal:IsShown() and type(self.RefreshScanLogCopyBox) == "function" then
    self:RefreshScanLogCopyBox()
  end
end

function SND:RefreshAllTabs()
  if not self.mainFrame or not self.mainFrame.contentFrames then
    return
  end

  local directoryFrame = self.mainFrame.contentFrames[1]
  local requestsFrame = self.mainFrame.contentFrames[2]
  local statsFrame = self.mainFrame.contentFrames[3]
  local meFrame = self.mainFrame.contentFrames[4]

  if directoryFrame then
    self:UpdateDirectoryResults(directoryFrame.searchBox and directoryFrame.searchBox:GetText() or "")
  end

  if requestsFrame and requestsFrame.listButtons then
    self:RefreshRequestList(requestsFrame)
  end

  if statsFrame and type(self.RefreshStatsTab) == "function" then
    self:RefreshStatsTab(statsFrame)
  end

  if meFrame then
    self:RefreshMeTab(meFrame)
  end
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

function SND:RegisterSlashCommands()
  if self._slashRegistered then
    return
  end
  self:RegisterChatCommand("snd", "HandleSlashCommand")
  self._slashRegistered = true
end

function SND:HandleSlashCommand(input)
  local command = tostring(input or ""):match("^%s*(.-)%s*$")
  if command == "config" or command == "options" then
    self:OpenOptions()
    return
  end
  if command == "debug" then
    -- Debug command to show player counts
    local playerCount = 0
    local playersWithProfs = 0
    local totalRecipes = 0
    for _, player in pairs(self.db.players) do
      playerCount = playerCount + 1
      if player.professions and next(player.professions) then
        playersWithProfs = playersWithProfs + 1
        for _, prof in pairs(player.professions) do
          if prof.recipes then
            for _ in pairs(prof.recipes) do
              totalRecipes = totalRecipes + 1
            end
          end
        end
      end
    end
    local recipeIndexCount = 0
    if self.db.recipeIndex then
      for _ in pairs(self.db.recipeIndex) do
        recipeIndexCount = recipeIndexCount + 1
      end
    end
    self:Print(string.format("Players in DB: %d | With professions: %d | Total recipes: %d", playerCount, playersWithProfs, totalRecipes))
    self:Print(string.format("RecipeIndex entries: %d", recipeIndexCount))

    -- Comms diagnostics
    self:Print("--- Comms Diagnostics ---")
    local guildName = GetGuildInfo and GetGuildInfo("player") or "NONE"
    local isInGuild = IsInGuild()
    self:Print(string.format("In Guild: %s | Guild: %s", tostring(isInGuild), tostring(guildName)))

    local cacheCount = 0
    if self.comms.guildMemberCache then
      for _ in pairs(self.comms.guildMemberCache) do
        cacheCount = cacheCount + 1
      end
    end
    self:Print(string.format("Guild member cache: %d members", cacheCount))
    self:Print(string.format("Combat state: %s", tostring(self.comms.inCombat or false)))
    self:Print(string.format("Pending combat messages: %d", #(self.comms.pendingCombatMessages or {})))
    return
  end
  if command == "broadcast" then
    -- Manual broadcast command for testing
    self:Print("Broadcasting recipe data to guild...")
    if type(self.SendRecipeIndex) == "function" then
      self:SendRecipeIndex(true)
      self:Print("Recipe broadcast sent!")
    else
      self:Print("ERROR: SendRecipeIndex function not available")
    end
    return
  end
  if command == "testguild" then
    -- Test if we can see guild members
    local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
    self:Print(string.format("WoW API reports %d guild members", numMembers))
    if numMembers > 0 then
      for i = 1, math.min(5, numMembers) do
        local name = GetGuildRosterInfo(i)
        local nameOnly = name and strsplit("-", name)
        local isCached = self.comms.guildMemberCache and self.comms.guildMemberCache[nameOnly] or false
        self:Print(string.format("  %d: %s (cached: %s)", i, tostring(nameOnly), tostring(isCached)))
      end
    end
    return
  end
  self:ToggleMainWindow()
  self:DebugPrint(self:Tr("/snd toggles the main window. /snd config opens options."))
end
