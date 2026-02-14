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
  self:InitDB()
  self:EnsureScanLogBuffer()
  self:DebugLog("MARK startup: debug sink initialized", true)
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

function SND:WhisperPlayer(playerName)
  if not playerName then
    return
  end
  if ChatFrame_SendTell then
    ChatFrame_SendTell(playerName)
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
    self:WhisperPlayer(target.name)
  end
end

function SND:RefreshMeTab(meFrame)
  meFrame = meFrame or self.meTabFrame or (self.mainFrame and self.mainFrame.contentFrames and self.mainFrame.contentFrames[3])
  if not meFrame or not meFrame.scanStatus or not meFrame.professionsList then
    if self.TraceScanLog then
      self:TraceScanLog("ui-refresh: RefreshMeTab skipped (me frame unavailable)")
    end
    return
  end

  self.meTabFrame = meFrame

  if self.TraceScanLog then
    self:TraceScanLog("ui-refresh: RefreshMeTab begin")
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
    return
  end
  local lines = {}
  for _, prof in pairs(entry.professions) do
    table.insert(lines, string.format("%s %d/%d", prof.name or "", prof.rank or 0, prof.maxRank or 0))
  end
  table.sort(lines)
  if #lines == 0 then
    meFrame.professionsList:SetText(self:Tr("Professions: -"))
  else
    meFrame.professionsList:SetText(self:Tr("Professions: %s", table.concat(lines, " | ")))
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

  if meFrame.sharedMatsSearchBox then
    self:RefreshSharedMatsList(meFrame)
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
    self:TraceScanLog(string.format("MARK ui-write: lines=%d replayStart=%d", totalLines, startIndex))
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
  local meFrame = self.mainFrame.contentFrames[3]

  if directoryFrame then
    self:UpdateDirectoryResults(directoryFrame.searchBox and directoryFrame.searchBox:GetText() or "")
  end

  if requestsFrame and requestsFrame.listButtons then
    self:RefreshRequestList(requestsFrame)
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
