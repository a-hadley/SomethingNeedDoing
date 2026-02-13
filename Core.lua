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

local function debugDirectory(self, message)
  self:DebugLog(message, true)
end

local function normalizeRecipeSpellIDValue(value)
  if type(value) == "table" then
    value = value.recipeSpellID or value.selectedRecipeSpellID or value.spellID
  end
  local n = tonumber(value)
  if not n then
    return nil
  end
  n = math.floor(n)
  if n <= 0 then
    return nil
  end
  return n
end

-- ============================================================================
-- Item Cache Manager
-- NOTE: Item cache functions have been moved to modules/ItemCache.lua
-- ============================================================================

local function normalizeItemIDValue(value)
  local n = tonumber(value)
  if not n then
    return nil
  end
  n = math.floor(n)
  if n <= 0 then
    return nil
  end
  return n
end

function SND:NormalizeRecipeSpellID(value)
  return normalizeRecipeSpellIDValue(value)
end

function SND:UpdateDirectoryResults(query)
  if not self.mainFrame or not self.mainFrame.contentFrames then
    return
  end
  local directoryFrame = self.mainFrame.contentFrames[1]
  if not directoryFrame then
    return
  end

  local searchQuery = query
  if searchQuery == nil and directoryFrame.searchBox then
    searchQuery = directoryFrame.searchBox:GetText()
  end
  searchQuery = searchQuery or ""

  local filters = {
    professionName = directoryFrame.selectedProfession,
    onlineOnly = directoryFrame.onlineOnly,
    sharedMatsOnly = directoryFrame.sharedMatsOnly,
  }
  local results = self:SearchRecipes(searchQuery, filters)
  local recipeIndexCount = countTableEntries(self.db and self.db.recipeIndex)
  local summaryKey = table.concat({
    tostring(searchQuery),
    tostring(filters.professionName),
    tostring(filters.onlineOnly),
    tostring(filters.sharedMatsOnly),
    tostring(#results),
    tostring(recipeIndexCount),
  }, "|")
  if self._lastDirectorySummaryLog ~= summaryKey then
    self._lastDirectorySummaryLog = summaryKey
    debugDirectory(self, string.format(
      "Directory: search update query='%s' profession=%s onlineOnly=%s sharedMatsOnly=%s results=%d recipeIndex=%d",
      tostring(searchQuery),
      tostring(filters.professionName),
      tostring(filters.onlineOnly),
      tostring(filters.sharedMatsOnly),
      #results,
      recipeIndexCount
    ))
  end

  if type(self.EnsureDirectoryRowCapacity) == "function" then
    self:EnsureDirectoryRowCapacity(directoryFrame, #results)
  end

  directoryFrame.currentResults = results
  directoryFrame.currentPage = tonumber(directoryFrame.currentPage) or 1
  if directoryFrame.currentPage < 1 then
    directoryFrame.currentPage = 1
  end

  self:RenderDirectoryList(directoryFrame, results)
end

function SND:SearchRecipes(query, filters)
  local cleaned = string.lower((query or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  if cleaned == "" then
    local results = {}
    for recipeSpellID, recipe in pairs(self.db.recipeIndex) do
      local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
      local count = #crafters
      if count > 0 then
        table.insert(results, { recipeSpellID = recipeSpellID, name = recipe.name or "", crafterCount = count })
      end
    end

    table.sort(results, function(a, b)
      if a.crafterCount == b.crafterCount then
        return a.name < b.name
      end
      return a.crafterCount > b.crafterCount
    end)

    return results
  end

  local results = {}
  for recipeSpellID, recipe in pairs(self.db.recipeIndex) do
    local name = recipe.name or ""
    local outputName = self:GetRecipeOutputItemName(recipeSpellID)
    local nameMatch = string.find(string.lower(name), cleaned, 1, true)
    local outputMatch = outputName and string.find(string.lower(outputName), cleaned, 1, true)
    if nameMatch or outputMatch then
      local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
      local count = #crafters
      if count > 0 then
        table.insert(results, { recipeSpellID = recipeSpellID, name = name, crafterCount = count })
      end
    end
  end

  table.sort(results, function(a, b)
    if a.crafterCount == b.crafterCount then
      return a.name < b.name
    end
    return a.crafterCount > b.crafterCount
  end)

  return results
end

function SND:CountCraftersForRecipe(recipeSpellID)
  local count = 0
  for _, player in pairs(self.db.players) do
    if player.professions then
      for _, prof in pairs(player.professions) do
        if prof.recipes and prof.recipes[recipeSpellID] then
          count = count + 1
          break
        end
      end
    end
  end
  return count
end

function SND:GetCraftersForRecipe(recipeSpellID, filters)
  local results = {}
  for playerName, player in pairs(self.db.players) do
    if player.professions then
      for _, prof in pairs(player.professions) do
        if prof.recipes and prof.recipes[recipeSpellID] then
          local hasSharedMats = player.sharedMats and self:HasSharedMatsForRecipe(player.sharedMats, recipeSpellID) or false
          if not filters or not filters.professionName or filters.professionName == "All" or filters.professionName == prof.name then
            if not filters or not filters.onlineOnly or player.online then
              if not filters or not filters.sharedMatsOnly or hasSharedMats then
                table.insert(results, {
                  name = playerName,
                  online = player.online,
                  profession = prof.name,
                  rank = prof.rank,
                  maxRank = prof.maxRank,
                  hasSharedMats = hasSharedMats,
                })
              end
            end
          end
          break
        end
      end
    end
  end
  table.sort(results, function(a, b)
    if a.online ~= b.online then
      return a.online
    end
    return a.name < b.name
  end)
  return results
end

function SND:HasSharedMatsForRecipe(sharedMats, recipeSpellID)
  if not sharedMats then
    return false
  end
  local reagents = self:GetRecipeReagents(recipeSpellID)
  if not reagents then
    return false
  end
  for itemID in pairs(reagents) do
    if sharedMats[itemID] and sharedMats[itemID] > 0 then
      return true
    end
  end
  return false
end

function SND:GetProfessionFilterOptions()
  local gathering = {
    ["Mining"] = true,
    ["Herbalism"] = true,
    ["Skinning"] = true,
  }
  local options = {}
  local seen = {}
  for _, option in ipairs(self:GetAllProfessionOptions()) do
    if not gathering[option] then
      table.insert(options, option)
      seen[option] = true
    end
  end
  for _, player in pairs(self.db.players) do
    if player.professions then
      for _, prof in pairs(player.professions) do
        if prof.name and not gathering[prof.name] and not seen[prof.name] then
          table.insert(options, prof.name)
          seen[prof.name] = true
        end
      end
    end
  end
  return options
end

function SND:RenderDirectoryList(directoryFrame, results)
  if not directoryFrame or not directoryFrame.listButtons then
    return
  end
  local pageSize = tonumber(directoryFrame.directoryPageSize) or #directoryFrame.listButtons
  if pageSize < 1 then
    pageSize = #directoryFrame.listButtons
  end
  local totalPages = math.max(1, math.ceil(#results / pageSize))
  local page = tonumber(directoryFrame.currentPage) or 1
  if page < 1 then
    page = 1
  elseif page > totalPages then
    page = totalPages
  end
  directoryFrame.currentPage = page

  if directoryFrame.directoryPageLabel then
    directoryFrame.directoryPageLabel:SetText(string.format("%d / %d", page, totalPages))
  end
  if directoryFrame.directoryPrevPageButton then
    directoryFrame.directoryPrevPageButton:SetEnabled(page > 1)
  end
  if directoryFrame.directoryNextPageButton then
    directoryFrame.directoryNextPageButton:SetEnabled(page < totalPages)
  end

  if directoryFrame.listScrollFrame and directoryFrame.listScrollFrame.SetVerticalScroll then
    directoryFrame.listScrollFrame:SetVerticalScroll(0)
  end

  if directoryFrame.listScrollChild and directoryFrame.listRowHeight then
    directoryFrame.listScrollChild:SetHeight(#directoryFrame.listButtons * directoryFrame.listRowHeight)
  end

  local startIndex = (page - 1) * pageSize + 1
  local firstSelected = nil
  for i, row in ipairs(directoryFrame.listButtons) do
    local entry = results[startIndex + i - 1]
    if entry then
      row.recipeSpellID = entry.recipeSpellID
      local outputLink = self:GetRecipeOutputItemLink(entry.recipeSpellID)
      local outputName = self:GetRecipeOutputItemName(entry.recipeSpellID)
      local outputIcon = self:GetRecipeOutputItemIcon(entry.recipeSpellID)
      row.outputLink = outputLink
      row.displayItemText = outputLink or outputName or entry.name or ""
      if row.icon then
        row.icon:SetTexture(outputIcon or "Interface/Icons/INV_Misc_QuestionMark")
      end
      if row.label then
        row.label:SetText(string.format("%s\n|cffffd100%d crafters|r", row.displayItemText, entry.crafterCount))
      end
      row:Show()
      if not firstSelected then
        firstSelected = entry.recipeSpellID
      end
    else
      row.recipeSpellID = nil
      row.outputLink = nil
      row.displayItemText = nil
      if row.icon then
        row.icon:SetTexture(nil)
      end
      if row.label then
        row.label:SetText("")
      end
      row:Hide()
    end
  end

  self:SelectDirectoryRecipe(directoryFrame, firstSelected)
end

function SND:SelectDirectoryRecipe(directoryFrame, recipeSpellID)
  directoryFrame.selectedRecipeSpellID = recipeSpellID
  directoryFrame.selectedRecipeLink = nil
  if not directoryFrame.detailTitle or not directoryFrame.crafterRows then
    return
  end
  if not recipeSpellID then
    directoryFrame.detailTitle:SetText(self:Tr("Select a recipe"))
    if directoryFrame.detailSummaryText then
      directoryFrame.detailSummaryText:SetText("")
    end
    if directoryFrame.itemPreviewTitle then
      directoryFrame.itemPreviewTitle:SetText(self:Tr("Select an item"))
    end
    if directoryFrame.itemPreviewIcon then
      directoryFrame.itemPreviewIcon:SetTexture(nil)
    end
    if directoryFrame.itemPreviewMeta then
      directoryFrame.itemPreviewMeta:SetText("")
    end
    if directoryFrame.itemPreviewCrafter then
      directoryFrame.itemPreviewCrafter:SetText("")
    end
    if directoryFrame.itemPreviewMats then
      directoryFrame.itemPreviewMats:SetText("")
    end
    if directoryFrame.sharedMatsSummary then
      directoryFrame.sharedMatsSummary:SetText("")
      directoryFrame.sharedMatsSummary:Hide()
    end
    if directoryFrame.crafterEmptyLabel then
      directoryFrame.crafterEmptyLabel:Hide()
    end
    for _, row in ipairs(directoryFrame.crafterRows) do
      row.crafterName = nil
      row.recipeSpellID = nil
      if row.nameText then
        row.nameText:SetText("")
      end
      if row.statusText then
        row.statusText:SetText("")
      end
      if row.professionText then
        row.professionText:SetText("")
      end
      if row.matsText then
        row.matsText:SetText("")
      end
      row:Hide()
    end
    return
  end

  local recipe = self.db.recipeIndex[recipeSpellID]
  local title = recipe and recipe.name or "Recipe"
  local outputLink = self:GetRecipeOutputItemLink(recipeSpellID)
  local outputName = self:GetRecipeOutputItemName(recipeSpellID)
  local outputText = outputLink or outputName or (recipe and recipe.name) or ("Recipe " .. tostring(recipeSpellID))
  directoryFrame.selectedRecipeLink = outputLink
  if outputLink then
    title = outputLink
  end
  directoryFrame.detailTitle:SetText(title)

  if directoryFrame.detailSummaryText then
    directoryFrame.detailSummaryText:SetText(outputText)
  end

  local filters = {
    professionName = directoryFrame.selectedProfession,
    onlineOnly = directoryFrame.onlineOnly,
    sharedMatsOnly = directoryFrame.sharedMatsOnly,
  }
  local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
  local maxRows = #directoryFrame.crafterRows
  for i, row in ipairs(directoryFrame.crafterRows) do
    local crafter = crafters[i]
    if crafter then
      row.crafterName = crafter.name
      row.crafterProfession = crafter.profession
      row.crafterOnline = crafter.online and true or false
      row.crafterHasSharedMats = crafter.hasSharedMats and true or false
      row.recipeSpellID = recipeSpellID
      row.itemLink = outputLink
      row.itemText = outputText
      local displayName = crafter.name and crafter.name:match("^[^-]+") or ""
      if row.nameText then
        row.nameText:SetText(displayName)
      end
      if row.statusText then
        row.statusText:SetText(crafter.online and self:Tr("Online") or self:Tr("Offline"))
      end
      if row.matsText then
        row.matsText:SetText(crafter.hasSharedMats and self:Tr("Yes") or "-")
      end
      row:Show()
    else
      row.crafterName = nil
      row.crafterProfession = nil
      row.crafterOnline = nil
      row.crafterHasSharedMats = nil
      row.recipeSpellID = nil
      row.itemLink = nil
      row.itemText = nil
      if row.nameText then
        row.nameText:SetText("")
      end
      if row.statusText then
        row.statusText:SetText("")
      end
      if row.matsText then
        row.matsText:SetText("")
      end
      row:Hide()
    end
  end
  if directoryFrame.crafterScrollChild and directoryFrame.crafterRowHeight then
    directoryFrame.crafterScrollChild:SetHeight(math.max(#crafters, maxRows) * directoryFrame.crafterRowHeight)
  end
  if directoryFrame.crafterEmptyLabel then
    if #crafters == 0 then
      directoryFrame.crafterEmptyLabel:Show()
    else
      directoryFrame.crafterEmptyLabel:Hide()
    end
  end

  if directoryFrame.itemPreviewTitle then
    directoryFrame.itemPreviewTitle:SetText(outputText)
  end
  if directoryFrame.itemPreviewButton then
    directoryFrame.itemPreviewButton.recipeSpellID = recipeSpellID
    directoryFrame.itemPreviewButton.outputLink = outputLink
  end

  local itemID = self:GetRecipeOutputItemID(recipeSpellID)
  local icon = self:GetRecipeOutputItemIcon(recipeSpellID)
  if directoryFrame.itemPreviewIcon then
    directoryFrame.itemPreviewIcon:SetTexture(icon or "Interface/Icons/INV_Misc_QuestionMark")
  end

  if directoryFrame.itemPreviewMeta then
    local itemType, itemSubType, equipLoc
    if itemID then
      local _, _, _, _, _, it, ist, _, loc = GetItemInfo(itemID)
      itemType = it
      itemSubType = ist
      equipLoc = loc
    end
    local metaParts = {}
    if equipLoc and equipLoc ~= "" then
      table.insert(metaParts, _G[equipLoc] or equipLoc)
    end
    if itemSubType and itemSubType ~= "" then
      table.insert(metaParts, itemSubType)
    elseif itemType and itemType ~= "" then
      table.insert(metaParts, itemType)
    end
    directoryFrame.itemPreviewMeta:SetText(table.concat(metaParts, " • "))
  end

  if directoryFrame.itemPreviewCrafter then
    local topCrafter = crafters[1]
    if topCrafter then
      directoryFrame.itemPreviewCrafter:SetText(string.format(
        self:Tr("Crafted by %s (%s)"),
        topCrafter.name and topCrafter.name:match("^[^-]+") or self:Tr("Unknown"),
        topCrafter.online and self:Tr("Online") or self:Tr("Offline")
      ))
    else
      directoryFrame.itemPreviewCrafter:SetText(self:Tr("No crafters available"))
    end
  end

  if directoryFrame.itemPreviewMats then
    local reagents = self:GetRecipeReagents(recipeSpellID)
    local mats = {}
    for itemKey, amount in pairs(reagents or {}) do
      local id = tonumber(itemKey) or itemKey
      local name = GetItemInfo(id) or ("Item " .. tostring(id))
      table.insert(mats, { name = name, amount = tonumber(amount) or 0 })
    end
    table.sort(mats, function(a, b)
      return a.name < b.name
    end)
    if #mats == 0 then
      directoryFrame.itemPreviewMats:SetText(self:Tr("No material data"))
    else
      local lines = {}
      for _, mat in ipairs(mats) do
        table.insert(lines, string.format("• %s x%d", mat.name, mat.amount))
      end
      directoryFrame.itemPreviewMats:SetText(table.concat(lines, "\n"))
    end
  end

  if directoryFrame.sharedMatsSummary then
    local sharedCount = 0
    for _, player in pairs(self.db.players) do
      if player.sharedMats and self:HasSharedMatsForRecipe(player.sharedMats, recipeSpellID) then
        sharedCount = sharedCount + 1
      end
    end
    if directoryFrame.sharedMatsOnly then
      directoryFrame.sharedMatsSummary:SetText(self:Tr("Shared mats available from: %d crafters", sharedCount))
      directoryFrame.sharedMatsSummary:Show()
    else
      directoryFrame.sharedMatsSummary:SetText("")
      directoryFrame.sharedMatsSummary:Hide()
    end
  end
end

function SND:GetRecipeOutputItemName(recipeSpellID)
  recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  if not recipeSpellID then
    return nil
  end
  
  -- Check recipeIndex for cached name
  local entry = self.db.recipeIndex[recipeSpellID]
  if entry and entry.itemName then
    return entry.itemName
  end
  
  local itemID = self:GetRecipeOutputItemID(recipeSpellID)
  if not itemID then
    return nil
  end
  
  -- Try to get from item cache
  local cachedInfo = self:GetCachedItemInfo(itemID)
  if cachedInfo then
    if cachedInfo.name then
      -- Cache hit - store in recipeIndex
      if entry then
        entry.itemName = cachedInfo.name
        entry.itemDataStatus = "cached"
      end
      return cachedInfo.name
    elseif cachedInfo.isPending then
      -- Item is loading
      return nil
    end
  end
  
  -- Try direct API call
  local name = GetItemInfo(itemID)
  if name then
    -- Success - cache it
    if entry then
      entry.itemName = name
      entry.itemDataStatus = "cached"
    end
    return name
  end
  
  -- Failed - queue for warming
  self:WarmItemCache({itemID}, recipeSpellID, function()
    -- Update recipeIndex when available
    local retryName = GetItemInfo(itemID)
    if retryName and entry then
      entry.itemName = retryName
      entry.itemDataStatus = "cached"
      entry.lastUpdated = self:Now()
    end
  end)
  
  -- Mark as pending
  if entry then
    entry.itemDataStatus = "pending"
  end
  
  return nil
end

function SND:GetRecipeOutputItemLink(recipeSpellID)
  recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  if not recipeSpellID then
    return nil
  end
  self.outputLinkCache = self.outputLinkCache or {}
  if self.outputLinkCache[recipeSpellID] then
    return self.outputLinkCache[recipeSpellID]
  end
  local itemID = self:GetRecipeOutputItemID(recipeSpellID)
  if not itemID then
    return nil
  end
  local _, link = GetItemInfo(itemID)
  self.outputLinkCache[recipeSpellID] = link
  return link
end

local function normalizeDisplayText(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil
  end
  if trimmed:match("^%d+$") then
    return nil
  end
  if trimmed:match("^item:%d+$") then
    return nil
  end
  if trimmed:match("^Item%s+%d+$") then
    return nil
  end
  if trimmed:match("^Recipe%s+%d+$") then
    return nil
  end
  if trimmed:match("^Recipe%s+table:%s*0?x?[%x]+$") then
    return nil
  end
  if trimmed:match("^Recipe%s+userdata:%s*0?x?[%x]+$") then
    return nil
  end
  if trimmed:match("^table:%s*0?x?[%x]+$") then
    return nil
  end
  if trimmed:match("^userdata:%s*0?x?[%x]+$") then
    return nil
  end
  return trimmed
end

function SND:ResolveRecipeDisplayData(recipeSpellID, prefill)
  local normalizedRecipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  local context = type(prefill) == "table" and prefill or {}
  local recipe = normalizedRecipeSpellID and self.db and self.db.recipeIndex and self.db.recipeIndex[normalizedRecipeSpellID] or nil

  local explicitItemID = normalizeItemIDValue(context.itemID)
  local explicitItemLink = normalizeDisplayText(context.itemLink)
  local explicitItemText = normalizeDisplayText(context.itemText)

  local explicitItemIDLink = explicitItemID and select(2, GetItemInfo(explicitItemID)) or nil
  explicitItemIDLink = normalizeDisplayText(explicitItemIDLink)
  local explicitItemIDText = explicitItemID and normalizeDisplayText(GetItemInfo(explicitItemID)) or nil

  local recipeOutputItemID = normalizedRecipeSpellID and normalizeItemIDValue(self:GetRecipeOutputItemID(normalizedRecipeSpellID)) or nil
  local recipeOutputItemLink = normalizedRecipeSpellID and normalizeDisplayText(self:GetRecipeOutputItemLink(normalizedRecipeSpellID)) or nil
  local recipeOutputItemText = normalizedRecipeSpellID and normalizeDisplayText(self:GetRecipeOutputItemName(normalizedRecipeSpellID)) or nil

  local dbOutputItemID = normalizeItemIDValue(recipe and recipe.outputItemID)
  local dbOutputItemLink = normalizeDisplayText(recipe and recipe.outputItemLink)
  local dbOutputItemText = normalizeDisplayText(recipe and (recipe.outputItemName or recipe.outputName))

  local itemID = explicitItemID or recipeOutputItemID or dbOutputItemID
  local itemLink = explicitItemLink or explicitItemIDLink or recipeOutputItemLink or dbOutputItemLink
  local itemText = explicitItemText

  if not itemLink and itemID then
    local _, resolvedLink = GetItemInfo(itemID)
    itemLink = normalizeDisplayText(resolvedLink)
  end

  if itemLink then
    itemText = itemLink
  end

  if not itemText then
    itemText = explicitItemIDText
  end
  if not itemText then
    itemText = recipeOutputItemText
  end
  if not itemText then
    itemText = dbOutputItemText
  end
  if not itemText and itemID then
    itemText = normalizeDisplayText(GetItemInfo(itemID))
  end
  if not itemText and normalizedRecipeSpellID then
    itemText = "Recipe #" .. tostring(normalizedRecipeSpellID)
  end
  if not itemText then
    itemText = "-"
  end

  local icon = nil
  if itemID then
    icon = GetItemIcon(itemID)
  end
  if not icon and normalizedRecipeSpellID then
    icon = self:GetRecipeOutputItemIcon(normalizedRecipeSpellID)
  end

  local entry = self.db.recipeIndex[normalizedRecipeSpellID]
  local itemDataStatus = entry and entry.itemDataStatus or "unknown"

  return {
    recipeSpellID = normalizedRecipeSpellID,
    itemID = itemID,
    itemLink = itemLink,
    itemText = itemText,
    icon = icon,
    itemDataStatus = itemDataStatus,  -- NEW: "cached", "pending", "unknown"
  }
end

function SND:ResolveReadableItemDisplay(recipeSpellID, context)
  local resolved = self:ResolveRecipeDisplayData(recipeSpellID, context)
  if not resolved then
    return nil, "-"
  end
  return resolved.itemLink, resolved.itemText
end

function SND:GetRecipeOutputItemID(recipeSpellID)
  recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  if not recipeSpellID then
    return nil
  end
  local entry = self.db.recipeIndex[recipeSpellID]
  if entry and entry.outputItemID then
    return entry.outputItemID
  end
  if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then
    return entry and entry.outputItemID or nil
  end
  local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, false)
  if not schematic or not schematic.outputItemID then
    return nil
  end
  if entry then
    entry.outputItemID = schematic.outputItemID
    entry.lastUpdated = self:Now()
  end
  return schematic.outputItemID
end

function SND:GetRecipeOutputItemIcon(recipeSpellID)
  recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  if not recipeSpellID then
    return nil
  end
  
  -- Check recipeIndex for cached icon
  local entry = self.db.recipeIndex[recipeSpellID]
  if entry and entry.itemIcon then
    return entry.itemIcon
  end
  
  local itemID = self:GetRecipeOutputItemID(recipeSpellID)
  if not itemID then
    return nil
  end
  
  -- Try to get from item cache
  local cachedInfo = self:GetCachedItemInfo(itemID)
  if cachedInfo and cachedInfo.icon then
    if entry then
      entry.itemIcon = cachedInfo.icon
      entry.itemDataStatus = "cached"
    end
    return cachedInfo.icon
  end
  
  -- Try direct API call
  local icon = GetItemIcon(itemID)
  if icon then
    if entry then
      entry.itemIcon = icon
      entry.itemDataStatus = "cached"
    end
    return icon
  end
  
  -- Failed - queue for warming
  self:WarmItemCache({itemID}, recipeSpellID, function()
    local retryIcon = GetItemIcon(itemID)
    if retryIcon and entry then
      entry.itemIcon = retryIcon
      entry.itemDataStatus = "cached"
      entry.lastUpdated = self:Now()
    end
  end)
  
  if entry then
    entry.itemDataStatus = "pending"
  end
  
  return nil
end

function SND:PromptNewRequest(recipeSpellID, context)
  recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  if not recipeSpellID then
    return
  end

  local recipe = self.db and self.db.recipeIndex and self.db.recipeIndex[recipeSpellID] or nil
  local resolvedDisplay = self:ResolveRecipeDisplayData(recipeSpellID, {
    itemID = type(context) == "table" and context.itemID or nil,
    itemLink = type(context) == "table" and context.itemLink or nil,
    itemText = type(context) == "table" and context.itemText or nil,
  })
  local prefill = {
    recipeSpellID = recipeSpellID,
    recipeName = recipe and recipe.name or nil,
    itemID = resolvedDisplay and resolvedDisplay.itemID or nil,
    itemLink = resolvedDisplay and resolvedDisplay.itemLink or nil,
    itemText = resolvedDisplay and resolvedDisplay.itemText or nil,
    professionSkillLineID = recipe and recipe.professionSkillLineID or nil,
    crafterName = type(context) == "table" and context.crafterName or nil,
    crafterOnline = type(context) == "table" and context.crafterOnline or nil,
    crafterHasSharedMats = type(context) == "table" and context.crafterHasSharedMats or nil,
    crafterProfession = type(context) == "table" and context.crafterProfession or nil,
  }

  local directoryFrame = self.mainFrame and self.mainFrame.contentFrames and self.mainFrame.contentFrames[1]
  if directoryFrame and directoryFrame.selectedRecipeSpellID == recipeSpellID then
    local filters = {
      professionName = directoryFrame.selectedProfession,
      onlineOnly = directoryFrame.onlineOnly,
      sharedMatsOnly = directoryFrame.sharedMatsOnly,
    }
    local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
    if not prefill.crafterName and crafters[1] and crafters[1].name then
      prefill.crafterName = crafters[1].name
      prefill.crafterProfession = crafters[1].profession
      prefill.crafterOnline = crafters[1].online and true or false
      prefill.crafterHasSharedMats = crafters[1].hasSharedMats and true or false
    end
    if crafters[1] and crafters[1].profession then
      prefill.professionName = crafters[1].profession
    end
  end

  self:DebugLog(string.format(
    "Request prefill: recipeSpellID=%s recipeName=%s itemID=%s professionSkillLineID=%s professionName=%s",
    tostring(prefill.recipeSpellID),
    tostring(prefill.recipeName),
    tostring(prefill.itemID),
    tostring(prefill.professionSkillLineID),
    tostring(prefill.professionName)
  ))

  self:ShowRequestModalForRecipe(recipeSpellID, prefill)
end

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

function SND:RefreshRequestList(requestsFrame)
  if not requestsFrame or not requestsFrame.listButtons then
    return
  end
  local results = self:FilterRequests(requestsFrame)
  local pageSize = tonumber(requestsFrame.pageSize) or #requestsFrame.listButtons
  if pageSize < 1 then
    pageSize = #requestsFrame.listButtons
  end
  local totalPages = math.max(1, math.ceil(#results / pageSize))
  local page = tonumber(requestsFrame.currentPage) or 1
  if page < 1 then
    page = 1
  elseif page > totalPages then
    page = totalPages
  end
  requestsFrame.currentPage = page

  if requestsFrame.pageLabel then
    requestsFrame.pageLabel:SetText(string.format("%d / %d", page, totalPages))
  end
  if requestsFrame.prevPageButton then
    requestsFrame.prevPageButton:SetEnabled(page > 1)
  end
  if requestsFrame.nextPageButton then
    requestsFrame.nextPageButton:SetEnabled(page < totalPages)
  end

  if requestsFrame.listScrollFrame and requestsFrame.listScrollFrame.SetVerticalScroll then
    requestsFrame.listScrollFrame:SetVerticalScroll(0)
  end

  local startIndex = (page - 1) * pageSize + 1
  local firstSelected = nil
  for i, row in ipairs(requestsFrame.listButtons) do
    local entry = results[startIndex + i - 1]
    if entry then
      row.requestId = entry.id
      local request = entry.data or {}
      local requester = (request.requester and request.requester:match("^[^-]+")) or (request.requester or "-")
      local status = request.status or ""
      local rowName = entry.name or "Request"

      if row.requesterText then
        row.requesterText:SetText(requester)
      end
      if row.itemText then
        row.itemText:SetText(rowName)
      end
      if row.statusText then
        row.statusText:SetText(status)
      end
      if row.icon then
        local icon = self:GetRecipeOutputItemIcon(request.recipeSpellID)
        if not icon and request.itemID then
          icon = GetItemIcon(request.itemID)
        end
        row.icon:SetTexture(icon or "Interface/Icons/INV_Misc_QuestionMark")
      end
      row.outputLink = request.itemLink or self:GetRecipeOutputItemLink(request.recipeSpellID)
      row.displayItemText = rowName
      if row.quickClaimButton then
        row.quickClaimButton:SetShown(status == "OPEN")
        row.quickClaimButton:SetEnabled(status == "OPEN")
      end
      if row.label then
        row.label:SetText(rowName)
      end
      row:Show()
      if not firstSelected then
        firstSelected = entry.id
      end
    else
      row.requestId = nil
      if row.requesterText then
        row.requesterText:SetText("")
      end
      if row.itemText then
        row.itemText:SetText("")
      end
      if row.statusText then
        row.statusText:SetText("")
      end
      if row.icon then
        row.icon:SetTexture(nil)
      end
      row.outputLink = nil
      row.displayItemText = nil
      if row.quickClaimButton then
        row.quickClaimButton:Hide()
      end
      if row.label then
        row.label:SetText("")
      end
      row:Hide()
    end
  end
  self:SelectRequest(requestsFrame, firstSelected)
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

function SND:FilterRequests(requestsFrame)
  local results = {}
  local query = string.lower((requestsFrame.searchQuery or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  local professionFilter = requestsFrame.professionFilter or "All"
  for requestId, request in pairs(self.db.requests) do
    local recipe = self.db.recipeIndex[request.recipeSpellID]
    local _, sanitizedText = self:ResolveReadableItemDisplay(request.recipeSpellID, {
      itemID = request.itemID,
      itemLink = request.itemLink,
      itemText = request.itemText,
      recipeName = recipe and recipe.name or nil,
    })
    request.itemText = sanitizedText
    if not request.itemLink then
      local sanitizedLink = self:GetRecipeOutputItemLink(request.recipeSpellID)
      if sanitizedLink and sanitizedLink ~= "" then
        request.itemLink = sanitizedLink
      end
    end
    if not request.itemID then
      request.itemID = self:GetRecipeOutputItemID(request.recipeSpellID)
    end
    local _, resolvedText = self:ResolveReadableItemDisplay(request.recipeSpellID, {
      itemID = request.itemID,
      itemLink = request.itemLink,
      itemText = request.itemText,
      recipeName = recipe and recipe.name or nil,
    })
    local name = resolvedText or ((recipe and recipe.name) or ("Recipe " .. tostring(request.recipeSpellID)))
    local requester = request.requester or ""
    local recipeProfession = (recipe and (recipe.professionName or recipe.profession)) or ""
    local requesterEntry = self.db.players and self.db.players[requester] or nil
    local requesterOnline = requesterEntry and requesterEntry.online and true or false
    local hasMaterials = request.needsMats == false

    local queryMatch = (query == "")
      or string.find(string.lower(name), query, 1, true)
      or string.find(string.lower(requester), query, 1, true)

    local professionMatch = (professionFilter == "All") or (professionFilter == recipeProfession)
    local onlineMatch = (not requestsFrame.onlyMine) or requesterOnline
    local hasMaterialsMatch = (not requestsFrame.hasMaterialsOnly) or hasMaterials

    if requestsFrame.statusFilter == "ALL" or request.status == requestsFrame.statusFilter then
      if not requestsFrame.onlyClaimable or request.status == "OPEN" then
        if queryMatch and professionMatch and onlineMatch and hasMaterialsMatch then
          table.insert(results, { id = requestId, data = request, name = name })
        end
      end
    end
  end
  table.sort(results, function(a, b)
    return (a.data.updatedAt or 0) > (b.data.updatedAt or 0)
  end)
  return results
end

function SND:SelectRequest(requestsFrame, requestId)
  requestsFrame.selectedRequestId = requestId
  if not requestId then
    requestsFrame.detailTitle:SetText("Select a request")
    if requestsFrame.detailRequester then
      requestsFrame.detailRequester:SetText("")
    end
    if requestsFrame.detailItemButton then
      requestsFrame.detailItemButton.itemLink = nil
      requestsFrame.detailItemButton.recipeSpellID = nil
    end
    if requestsFrame.detailItemTitle then
      requestsFrame.detailItemTitle:SetText("-")
    end
    if requestsFrame.detailItemIcon then
      requestsFrame.detailItemIcon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
    end
    if requestsFrame.statusLine then
      requestsFrame.statusLine:SetText("Status: -")
    end
    requestsFrame.detailInfo:SetText("")
    requestsFrame.materialsList:SetText("")
    if requestsFrame.notesBox then
      requestsFrame.notesBox:SetText("")
    end
    return
  end
  local request = self.db.requests[requestId]
  if not request then
    return
  end
  local recipe = self.db.recipeIndex[request.recipeSpellID]
  local _, resolvedTitle = self:ResolveReadableItemDisplay(request.recipeSpellID, {
    itemID = request.itemID,
    itemLink = request.itemLink,
    itemText = request.itemText,
    recipeName = recipe and recipe.name or nil,
  })
  requestsFrame.detailTitle:SetText(resolvedTitle or (recipe and recipe.name) or "Request")

  local itemLink = request.itemLink
  if not itemLink then
    itemLink = self:GetRecipeOutputItemLink(request.recipeSpellID)
  end
  local itemIcon = self:GetRecipeOutputItemIcon(request.recipeSpellID)
  if not itemIcon and request.itemID then
    itemIcon = GetItemIcon(request.itemID)
  end
  if requestsFrame.detailItemButton then
    requestsFrame.detailItemButton.itemLink = itemLink
    requestsFrame.detailItemButton.recipeSpellID = request.recipeSpellID
  end
  if requestsFrame.detailItemTitle then
    requestsFrame.detailItemTitle:SetText(resolvedTitle or "-")
  end
  if requestsFrame.detailItemIcon then
    requestsFrame.detailItemIcon:SetTexture(itemIcon or "Interface/Icons/INV_Misc_QuestionMark")
  end

  local requesterShort = request.requester and request.requester:match("^[^-]+") or (request.requester or "-")
  if requestsFrame.detailRequester then
    requestsFrame.detailRequester:SetText(string.format("Requested by: %s", requesterShort))
  end
  local claimer = request.claimedBy or "-"
  local createdAt = request.createdAt and date("%Y-%m-%d %H:%M", request.createdAt) or "-"
  local updatedAt = request.updatedAt and date("%Y-%m-%d %H:%M", request.updatedAt) or "-"
  requestsFrame.detailInfo:SetText(string.format("Requester: %s\nClaimer: %s\nStatus: %s\nCreated: %s\nUpdated: %s", request.requester or "-", claimer, request.status or "", createdAt, updatedAt))
  if requestsFrame.statusLine then
    requestsFrame.statusLine:SetText(string.format("Status: %s", request.status or "-"))
  end

  local materials = self:GetRequestMaterialsText(request)
  requestsFrame.materialsList:SetText(materials)
  if requestsFrame.materialsScrollChild then
    local lines = 1
    for _ in string.gmatch(materials or "", "\n") do
      lines = lines + 1
    end
    requestsFrame.materialsScrollChild:SetHeight(math.max(140, lines * 22))
  end

  if requestsFrame.notesBox then
    requestsFrame.notesBox:SetText(request.notes or "")
  end

  self:UpdateRequestActionButtons(requestsFrame, request)
end

function SND:UpdateRequestActionButtons(requestsFrame, request)
  local playerKey = self:GetPlayerKey(UnitName("player"))
  local isRequester = request.requester == playerKey
  local isClaimer = request.claimedBy == playerKey
  local canEdit = self:CanEditRequest(request)
  local canCancel = self:CanCancelRequest(request)
  local canDelete = self:CanDeleteRequest(request)
  local canClaim = self:CanUpdateRequest(request, "CLAIMED", playerKey, playerKey)
  local canUnclaim = self:CanUpdateRequest(request, "OPEN", playerKey, nil)
  local canCraft = self:CanUpdateRequest(request, "CRAFTED", playerKey, request.claimedBy)
  local canDeliver = self:CanUpdateRequest(request, "DELIVERED", playerKey, request.claimedBy)

  requestsFrame.claimButton:SetEnabled(canClaim)
  requestsFrame.unclaimButton:SetEnabled(canUnclaim)
  requestsFrame.craftedButton:SetEnabled(canCraft)
  requestsFrame.deliveredButton:SetEnabled(canDeliver)
  if requestsFrame.editButton then
    requestsFrame.editButton:SetEnabled(canEdit)
  end
  if requestsFrame.cancelButton then
    requestsFrame.cancelButton:SetEnabled(canCancel)
  end
  if requestsFrame.deleteButton then
    requestsFrame.deleteButton:SetEnabled(canDelete)
  end
  if requestsFrame.saveNotesButton then
    requestsFrame.saveNotesButton:SetEnabled(canEdit)
  end
end

function SND:SaveInlineNotes(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  local request = self.db.requests[requestId]
  if not request or not self:CanEditRequest(request) then
    return
  end
  local text = ""
  if requestsFrame.notesBox then
    text = requestsFrame.notesBox:GetText() or ""
  end
  request.notes = text
  request.version = (tonumber(request.version) or 1) + 1
  request.updatedAtServer = self:Now()
  request.updatedAt = request.updatedAtServer
  request.updatedBy = self:GetPlayerKey(UnitName("player"))
  self:SendRequestUpdate(requestId, request)
  self:RefreshRequestList(requestsFrame)
end

function SND:UpdateRequestSearchResults(query)
  if not self.requestModal then
    return
  end
  if self.requestModal.lockRecipeSelection then
    local buttons = self.requestModal.resultButtons or {}
    for _, button in ipairs(buttons) do
      button.recipeSpellID = nil
      button.recipeName = nil
      button:Hide()
    end
    self.requestModal.searchResults = {}
    return
  end
  local results = self:SearchRecipes(query, nil)
  local buttons = self.requestModal.resultButtons or {}
  local page = self.requestModal.searchPage or 1
  local pageSize = self.requestModal.pageSize or #buttons
  local startIndex = (page - 1) * pageSize + 1
  for i, button in ipairs(buttons) do
    local entry = results[startIndex + i - 1]
    if entry then
      button.recipeSpellID = entry.recipeSpellID
      button.recipeName = entry.name
      button:SetText(entry.name)
      button:Show()
    else
      button.recipeSpellID = nil
      button.recipeName = nil
      button:Hide()
    end
  end

  if self.requestModal.pageLabel then
    local totalPages = math.max(1, math.ceil(#results / pageSize))
    self.requestModal.pageLabel:SetText(string.format("Page %d/%d", page, totalPages))
  end

  self.requestModal.searchResults = results
end

function SND:GetRequestMaterialsText(request)
  if not request then
    return ""
  end
  local reagents = self:GetRecipeReagents(request.recipeSpellID)
  if not reagents then
    return "No reagent data yet."
  end
  local lines = {}
  for itemID, count in pairs(reagents) do
    local required = count * (request.qty or 1)
    local have = 0
    if request.ownedCounts and request.ownedCounts[itemID] ~= nil then
      have = request.ownedCounts[itemID] or 0
    elseif request.requesterMatsSnapshot then
      have = request.requesterMatsSnapshot[itemID] or 0
    end
    local need = math.max(0, required - have)
    local itemName = GetItemInfo(itemID) or ("Item " .. itemID)
    table.insert(lines, string.format("%s: %d / %d (need %d)", itemName, have, required, need))
  end
  return table.concat(lines, "\n")
end

function SND:ShowNewRequestDialog()
  if self.requestModal and self.requestModal:IsShown() then
    return
  end
  self:CreateRequestModal()
  self:ShowRequestModal()
end

function SND:ClaimSelectedRequest(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "CLAIMED", self:GetPlayerKey(UnitName("player")))
  self:RefreshRequestList(requestsFrame)
end

function SND:UnclaimSelectedRequest(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "OPEN", nil)
  self:RefreshRequestList(requestsFrame)
end

function SND:MarkSelectedRequestCrafted(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "CRAFTED", self.db.requests[requestId] and self.db.requests[requestId].claimedBy)
  self:RefreshRequestList(requestsFrame)
end

function SND:MarkSelectedRequestDelivered(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "DELIVERED", self.db.requests[requestId] and self.db.requests[requestId].claimedBy)
  self:RefreshRequestList(requestsFrame)
end

function SND:EditSelectedRequestNotes(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  local request = self.db.requests[requestId]
  if not request or not self:CanEditRequest(request) then
    return
  end
  if not StaticPopupDialogs.SND_EDIT_NOTES then
    StaticPopupDialogs.SND_EDIT_NOTES = {
      text = "Edit request notes:",
      button1 = "Save",
      button2 = "Cancel",
      hasEditBox = true,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3,
      OnShow = function(popup)
        if popup.editBox then
          popup.editBox:SetText(popup.data or "")
          popup.editBox:HighlightText()
        end
      end,
      OnAccept = function(popup)
        local text = popup.editBox:GetText() or ""
        request.notes = text
        request.version = (tonumber(request.version) or 1) + 1
        request.updatedAtServer = SND:Now()
        request.updatedAt = request.updatedAtServer
        request.updatedBy = SND:GetPlayerKey(UnitName("player"))
        SND:SendRequestUpdate(requestId, request)
        SND:RefreshRequestList(requestsFrame)
      end,
    }
  end
  StaticPopup_Show("SND_EDIT_NOTES", nil, nil, request.notes or "")
end

function SND:CancelSelectedRequest(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  local request = self.db.requests[requestId]
  if not request or not self:CanCancelRequest(request) then
    return
  end
  if self:CancelRequest(requestId) then
    self:RefreshRequestList(requestsFrame)
  end
end

function SND:DeleteSelectedRequest(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  local request = self.db.requests[requestId]
  if not request or not self:CanDeleteRequest(request) then
    return
  end

  if not StaticPopupDialogs.SND_DELETE_REQUEST_REASON then
    StaticPopupDialogs.SND_DELETE_REQUEST_REASON = {
      text = "Moderator delete reason:",
      button1 = "Delete",
      button2 = "Cancel",
      hasEditBox = true,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3,
      OnShow = function(popup)
        if popup.editBox then
          popup.editBox:SetText("")
          popup.editBox:HighlightText()
        end
      end,
      OnAccept = function(popup)
        local reason = popup and popup.editBox and popup.editBox:GetText() or ""
        if SND:DeleteRequest(requestId, reason, "ui") then
          SND:RefreshRequestList(requestsFrame)
        end
      end,
    }
  end

  StaticPopup_Show("SND_DELETE_REQUEST_REASON")
end

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
  self:ToggleMainWindow()
  self:DebugPrint(self:Tr("/snd toggles the main window. /snd config opens options."))
end
