--[[
================================================================================
DirectoryUI Module
================================================================================
Manages the Directory tab UI including recipe list rendering and pagination.

Purpose:
  - Display searchable, filterable recipe directory
  - Show crafter availability and online status
  - Provide pagination for large result sets
  - Display recipe details and material requirements

UI Components:
  - Search box with real-time filtering
  - Profession/status filter dropdowns
  - Paginated recipe list (scrollable)
  - Recipe detail pane (crafters, materials, preview)
  - Item preview section with icon and metadata

Pagination:
  - Configurable page size (default: number of visible rows)
  - Previous/Next navigation buttons
  - Page indicator (current/total)
  - Scroll position reset on page change

Dependencies:
  - Requires: RecipeSearch.lua, RecipeData.lua, ItemCache.lua,
              Requests.lua (GetRecipeReagents), Utils.lua (Tr)
  - Used by: UI.lua (tab initialization)

Author: SND Team
Last Modified: 2026-02-13
================================================================================
]]--

local addonName = ...
local SND = _G[addonName]

-- ============================================================================
-- Helper Functions
-- ============================================================================

--[[
  countTableEntries - Count number of entries in a table

  Purpose:
    Counts entries in tables that don't use consecutive integer keys.

  Parameters:
    @param tbl (table) - Table to count

  Returns:
    @return (number) - Number of entries (0 if not a table)
]]--
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

--[[
  debugDirectory - Log directory-specific debug messages

  Purpose:
    Wrapper for debug logging specific to directory operations.

  Parameters:
    @param self (table) - SND addon object
    @param message (string) - Debug message
]]--
local function debugDirectory(self, message)
  self:DebugLog(message, true)
end

-- ============================================================================
-- Directory Search and Update
-- ============================================================================

--[[
  UpdateDirectoryResults - Refresh directory search results

  Purpose:
    Updates the directory list based on search query and filters.
    Calls SearchRecipes and triggers list rendering.

  Algorithm:
    1. Extract search query from UI (or use parameter)
    2. Build filters from UI state
    3. Call SearchRecipes with query and filters
    4. Log search summary (for debugging)
    5. Update UI with results

  Parameters:
    @param query (string|nil) - Optional search query (defaults to searchBox text)

  Side Effects:
    - Updates directoryFrame.currentResults
    - Calls RenderDirectoryList to update UI
    - Logs search summary for debugging
]]--
function SND:UpdateDirectoryResults(query)
  if not self.mainFrame or not self.mainFrame.contentFrames then
    return
  end
  local directoryFrame = self.mainFrame.contentFrames[1]
  if not directoryFrame then
    return
  end

  -- Get search query from parameter or UI
  local searchQuery = query
  if searchQuery == nil and directoryFrame.searchBox then
    searchQuery = directoryFrame.searchBox:GetText()
  end
  searchQuery = searchQuery or ""

  -- Build filters from UI state
  local filters = {
    professionName = directoryFrame.selectedProfession,
    onlineOnly = directoryFrame.onlineOnly,
    sharedMatsOnly = directoryFrame.sharedMatsOnly,
    hideOwnRecipes = directoryFrame.hideOwnRecipes,
  }

  -- Execute search
  local results = self:SearchRecipes(searchQuery, filters)
  local recipeIndexCount = countTableEntries(self.db and self.db.recipeIndex)

  -- Debug logging (with deduplication)
  local summaryKey = table.concat({
    tostring(searchQuery),
    tostring(filters.professionName),
    tostring(filters.onlineOnly),
    tostring(filters.sharedMatsOnly),
    tostring(filters.hideOwnRecipes),
    tostring(#results),
    tostring(recipeIndexCount),
  }, "|")
  if self._lastDirectorySummaryLog ~= summaryKey then
    self._lastDirectorySummaryLog = summaryKey
    debugDirectory(self, string.format(
      "Directory: search update query='%s' profession=%s onlineOnly=%s sharedMatsOnly=%s hideOwn=%s results=%d recipeIndex=%d",
      tostring(searchQuery),
      tostring(filters.professionName),
      tostring(filters.onlineOnly),
      tostring(filters.sharedMatsOnly),
      tostring(filters.hideOwnRecipes),
      #results,
      recipeIndexCount
    ))
  end

  -- Ensure row capacity (optional optimization)
  if type(self.EnsureDirectoryRowCapacity) == "function" then
    self:EnsureDirectoryRowCapacity(directoryFrame, #results)
  end

  -- Update UI state
  directoryFrame.currentResults = results
  directoryFrame.currentPage = tonumber(directoryFrame.currentPage) or 1
  if directoryFrame.currentPage < 1 then
    directoryFrame.currentPage = 1
  end

  -- Render updated list
  self:RenderDirectoryList(directoryFrame, results)
end

-- ============================================================================
-- Directory List Rendering
-- ============================================================================

--[[
  RenderDirectoryList - Render paginated recipe list

  Purpose:
    Renders the recipe list with pagination controls. Updates all visible
    rows with recipe data and handles page navigation.

  Algorithm:
    1. Calculate pagination (page size, total pages, current page)
    2. Update pagination UI (page label, prev/next buttons)
    3. Reset scroll position to top
    4. Populate visible rows with recipe data
    5. Auto-select first recipe

  Parameters:
    @param directoryFrame (table) - Directory UI frame
    @param results (table) - Search results array from SearchRecipes

  Side Effects:
    - Updates all listButtons with recipe data
    - Updates pagination controls
    - Calls SelectDirectoryRecipe for first visible recipe
]]--
function SND:RenderDirectoryList(directoryFrame, results)
  if not directoryFrame or not directoryFrame.listButtons then
    return
  end

  -- Calculate pagination
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

  -- Update pagination UI
  if directoryFrame.directoryPageLabel then
    directoryFrame.directoryPageLabel:SetText(string.format("%d / %d", page, totalPages))
  end
  if directoryFrame.directoryPrevPageButton then
    directoryFrame.directoryPrevPageButton:SetEnabled(page > 1)
  end
  if directoryFrame.directoryNextPageButton then
    directoryFrame.directoryNextPageButton:SetEnabled(page < totalPages)
  end

  -- Reset scroll position to top
  if directoryFrame.listScrollFrame and directoryFrame.listScrollFrame.SetVerticalScroll then
    directoryFrame.listScrollFrame:SetVerticalScroll(0)
  end

  -- Set scroll child height
  if directoryFrame.listScrollChild and directoryFrame.listRowHeight then
    directoryFrame.listScrollChild:SetHeight(#directoryFrame.listButtons * directoryFrame.listRowHeight)
  end

  -- Populate visible rows
  local startIndex = (page - 1) * pageSize + 1
  local firstSelected = nil
  for i, row in ipairs(directoryFrame.listButtons) do
    local entry = results[startIndex + i - 1]
    if entry then
      -- Recipe exists for this row
      row.recipeSpellID = entry.recipeSpellID
      local outputLink = self:GetRecipeOutputItemLink(entry.recipeSpellID)
      local outputName = self:GetRecipeOutputItemName(entry.recipeSpellID)
      local outputIcon = self:GetRecipeOutputItemIcon(entry.recipeSpellID)
      row.outputLink = outputLink
      row.displayItemText = outputLink or outputName or entry.name or ""

      -- Update row UI
      if row.icon then
        row.icon:SetTexture(outputIcon or "Interface/Icons/INV_Misc_QuestionMark")
      end
      if row.label then
        row.label:SetText(string.format("%s\n|cffffd100%d crafters|r", row.displayItemText, entry.crafterCount))
      end
      row:Show()

      -- Track first visible recipe for auto-selection
      if not firstSelected then
        firstSelected = entry.recipeSpellID
      end
    else
      -- No recipe for this row (beyond result set)
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

  -- Auto-select first recipe
  self:SelectDirectoryRecipe(directoryFrame, firstSelected)
end

-- ============================================================================
-- Recipe Detail Display
-- ============================================================================

--[[
  SelectDirectoryRecipe - Display details for selected recipe

  Purpose:
    Updates the detail pane with comprehensive information about the selected
    recipe including crafters, materials, item preview, and metadata.

  UI Updates:
    - Recipe title and summary
    - Crafter list (name, online status, shared mats)
    - Item preview (icon, name, type, slot)
    - Material requirements list
    - Shared materials summary

  Parameters:
    @param directoryFrame (table) - Directory UI frame
    @param recipeSpellID (number|nil) - Recipe to select (nil clears selection)

  Side Effects:
    - Updates directoryFrame.selectedRecipeSpellID
    - Updates all detail pane UI elements
    - Updates item preview section
    - Updates crafter rows
]]--
function SND:SelectDirectoryRecipe(directoryFrame, recipeSpellID)
  directoryFrame.selectedRecipeSpellID = recipeSpellID
  directoryFrame.selectedRecipeLink = nil

  if not directoryFrame.detailTitle or not directoryFrame.crafterRows then
    return
  end

  -- Clear selection state
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

    -- Clear all crafter rows
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

  -- Get recipe data
  local recipe = self.db.recipeIndex[recipeSpellID]
  local title = recipe and recipe.name or "Recipe"
  local outputLink = self:GetRecipeOutputItemLink(recipeSpellID)
  local outputName = self:GetRecipeOutputItemName(recipeSpellID)
  local outputText = outputLink or outputName or (recipe and recipe.name) or ("Recipe " .. tostring(recipeSpellID))
  directoryFrame.selectedRecipeLink = outputLink

  -- Use link for title if available
  if outputLink then
    title = outputLink
  end

  -- Update detail title
  directoryFrame.detailTitle:SetText(title)

  if directoryFrame.detailSummaryText then
    directoryFrame.detailSummaryText:SetText(outputText)
  end

  -- Get crafters (with filters applied)
  local filters = {
    professionName = directoryFrame.selectedProfession,
    onlineOnly = directoryFrame.onlineOnly,
    sharedMatsOnly = directoryFrame.sharedMatsOnly,
  }
  local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)

  -- Update crafter rows
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

      -- Extract name without realm
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
      -- No crafter for this row
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

  -- Update crafter scroll child height
  if directoryFrame.crafterScrollChild and directoryFrame.crafterRowHeight then
    directoryFrame.crafterScrollChild:SetHeight(math.max(#crafters, maxRows) * directoryFrame.crafterRowHeight)
  end

  -- Show/hide empty label
  if directoryFrame.crafterEmptyLabel then
    if #crafters == 0 then
      directoryFrame.crafterEmptyLabel:Show()
    else
      directoryFrame.crafterEmptyLabel:Hide()
    end
  end

  -- Update item preview section
  if directoryFrame.itemPreviewTitle then
    directoryFrame.itemPreviewTitle:SetText(outputText)
  end
  if directoryFrame.itemPreviewButton then
    directoryFrame.itemPreviewButton.recipeSpellID = recipeSpellID
    directoryFrame.itemPreviewButton.outputLink = outputLink
  end

  -- Update item icon
  local itemID = self:GetRecipeOutputItemID(recipeSpellID)
  local icon = self:GetRecipeOutputItemIcon(recipeSpellID)
  if directoryFrame.itemPreviewIcon then
    directoryFrame.itemPreviewIcon:SetTexture(icon or "Interface/Icons/INV_Misc_QuestionMark")
  end

  -- Update item metadata (type, slot, etc.)
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

  -- Update top crafter info
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

  -- Update materials list
  if directoryFrame.itemPreviewMats then
    local reagents = self:GetRecipeReagents(recipeSpellID)
    local mats = {}
    for itemKey, amount in pairs(reagents or {}) do
      local id = tonumber(itemKey) or itemKey
      local name = GetItemInfo(id) or ("Item " .. tostring(id))
      table.insert(mats, { name = name, amount = tonumber(amount) or 0 })
    end

    -- Sort by name
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

  -- Update shared materials summary
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
