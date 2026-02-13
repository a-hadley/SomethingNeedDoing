--[[
================================================================================
RecipeSearch Module
================================================================================
Provides search and filtering capabilities for the recipe directory.

Purpose:
  - Search recipes by name or output item name
  - Filter results by profession, online status, shared materials
  - Rank results by number of available crafters
  - Support real-time search updates

Search Algorithm:
  1. Normalize search query (lowercase, trim whitespace)
  2. Search both recipe name and output item name
  3. Apply profession/online/materials filters
  4. Count matching crafters per recipe
  5. Sort by crafter count (descending), then name (ascending)

Filters Supported:
  - professionName: Filter by specific profession or "All"
  - onlineOnly: Show only online crafters
  - sharedMatsOnly: Show only crafters with available shared materials

Performance:
  - Searches entire recipeIndex (typically 100-1000 recipes)
  - Filters crafter list per recipe (typically 1-50 crafters)
  - Results sorted in-memory before display
  - Empty query returns all recipes (fast path)

Dependencies:
  - Requires: DB.lua (players, recipeIndex), RecipeData.lua (GetRecipeOutputItemName),
              Requests.lua (GetRecipeReagents for shared mats check)
  - Used by: DirectoryUI.lua, RequestUI.lua

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
  normalizeRecipeSpellIDValue - Validate and normalize recipe spell ID

  Purpose:
    Ensures recipe spell IDs are valid positive integers. Handles table objects
    that may contain recipe IDs in various fields.

  Parameters:
    @param value (number|table) - Value to normalize

  Returns:
    @return (number|nil) - Normalized recipe spell ID or nil if invalid
]]--
local function normalizeRecipeSpellIDValue(value)
  -- Handle table objects (may come from UI or API)
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
-- Public API
-- ============================================================================

--[[
  NormalizeRecipeSpellID - Public wrapper for recipe ID normalization

  Purpose:
    Provides a public interface for normalizing recipe spell IDs.

  Parameters:
    @param value (number|table) - Value to normalize

  Returns:
    @return (number|nil) - Normalized recipe spell ID or nil if invalid
]]--
function SND:NormalizeRecipeSpellID(value)
  return normalizeRecipeSpellIDValue(value)
end

-- ============================================================================
-- Recipe Search
-- ============================================================================

--[[
  SearchRecipes - Search for recipes matching query and filters

  Purpose:
    Searches the recipe index for recipes matching the search query and
    applies filters to return only recipes with available crafters.

  Algorithm:
    1. Normalize query (lowercase, trim)
    2. If empty query: return all recipes with crafters
    3. If query provided: search recipe name AND output item name
    4. For each match: count crafters (with filters applied)
    5. Sort by crafter count (desc), then name (asc)

  Parameters:
    @param query (string|nil) - Search query (searches name and output item)
    @param filters (table|nil) - Optional filters:
      - professionName (string) - Filter by profession (e.g., "Blacksmithing", "All")
      - onlineOnly (boolean) - Show only online crafters
      - sharedMatsOnly (boolean) - Show only recipes with shared mats available

  Returns:
    @return (table) - Array of search results:
      [
        {
          recipeSpellID = number,
          name = string,
          crafterCount = number
        },
        ...
      ]
      Sorted by crafterCount (desc), then name (asc)

  Example:
    local results = self:SearchRecipes("iron", {
      professionName = "Blacksmithing",
      onlineOnly = true
    })
]]--
function SND:SearchRecipes(query, filters)
  local cleaned = string.lower((query or ""):gsub("^%s+", ""):gsub("%s+$", ""))

  -- Fast path: empty query returns all recipes
  if cleaned == "" then
    local results = {}
    for recipeSpellID, recipe in pairs(self.db.recipeIndex) do
      local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
      local count = #crafters
      if count > 0 then
        table.insert(results, {
          recipeSpellID = recipeSpellID,
          name = recipe.name or "",
          crafterCount = count
        })
      end
    end

    -- Sort by crafter count (desc), then name (asc)
    table.sort(results, function(a, b)
      if a.crafterCount == b.crafterCount then
        return a.name < b.name
      end
      return a.crafterCount > b.crafterCount
    end)

    return results
  end

  -- Search mode: match query against recipe name or output item name
  local results = {}
  for recipeSpellID, recipe in pairs(self.db.recipeIndex) do
    local name = recipe.name or ""
    local outputName = self:GetRecipeOutputItemName(recipeSpellID)

    -- Case-insensitive substring match
    local nameMatch = string.find(string.lower(name), cleaned, 1, true)
    local outputMatch = outputName and string.find(string.lower(outputName), cleaned, 1, true)

    if nameMatch or outputMatch then
      local crafters = self:GetCraftersForRecipe(recipeSpellID, filters)
      local count = #crafters
      if count > 0 then
        table.insert(results, {
          recipeSpellID = recipeSpellID,
          name = name,
          crafterCount = count
        })
      end
    end
  end

  -- Sort by crafter count (desc), then name (asc)
  table.sort(results, function(a, b)
    if a.crafterCount == b.crafterCount then
      return a.name < b.name
    end
    return a.crafterCount > b.crafterCount
  end)

  return results
end

-- ============================================================================
-- Crafter Lookups
-- ============================================================================

--[[
  CountCraftersForRecipe - Quick count of crafters who know a recipe

  Purpose:
    Fast count of how many guild members know a specific recipe.
    Does not apply filters.

  Parameters:
    @param recipeSpellID (number) - Recipe spell ID

  Returns:
    @return (number) - Count of crafters (0 if none)

  Performance:
    O(players * professions) - typically <100ms for large guilds
]]--
function SND:CountCraftersForRecipe(recipeSpellID)
  local count = 0
  for _, player in pairs(self.db.players) do
    if player.professions then
      for _, prof in pairs(player.professions) do
        if prof.recipes and prof.recipes[recipeSpellID] then
          count = count + 1
          break  -- Count each player only once
        end
      end
    end
  end
  return count
end

--[[
  GetCraftersForRecipe - Get detailed list of crafters for a recipe

  Purpose:
    Returns a filtered list of guild members who know a specific recipe,
    with detailed information about their profession, online status, and
    shared materials availability.

  Parameters:
    @param recipeSpellID (number) - Recipe spell ID
    @param filters (table|nil) - Optional filters (same as SearchRecipes)
      - professionName (string) - Filter by profession
      - onlineOnly (boolean) - Show only online crafters
      - sharedMatsOnly (boolean) - Show only crafters with shared mats

  Returns:
    @return (table) - Array of crafter objects:
      [
        {
          name = string,           -- Player name
          online = boolean,        -- Online status
          profession = string,     -- Profession name
          rank = number,           -- Profession skill level
          maxRank = number,        -- Max profession skill level
          hasSharedMats = boolean  -- Has shared materials available
        },
        ...
      ]
      Sorted by online status (online first), then name (asc)

  Example:
    local crafters = self:GetCraftersForRecipe(12345, {onlineOnly = true})
    for _, crafter in ipairs(crafters) do
      print(crafter.name, crafter.profession, crafter.rank)
    end
]]--
function SND:GetCraftersForRecipe(recipeSpellID, filters)
  local results = {}
  for playerName, player in pairs(self.db.players) do
    if player.professions then
      for _, prof in pairs(player.professions) do
        if prof.recipes and prof.recipes[recipeSpellID] then
          -- Check if player has shared materials for this recipe
          local hasSharedMats = player.sharedMats and self:HasSharedMatsForRecipe(player.sharedMats, recipeSpellID) or false

          -- Apply filters
          local professionMatch = not filters or not filters.professionName or filters.professionName == "All" or filters.professionName == prof.name
          local onlineMatch = not filters or not filters.onlineOnly or player.online
          local sharedMatsMatch = not filters or not filters.sharedMatsOnly or hasSharedMats

          if professionMatch and onlineMatch and sharedMatsMatch then
            table.insert(results, {
              name = playerName,
              online = player.online,
              profession = prof.name,
              rank = prof.rank,
              maxRank = prof.maxRank,
              hasSharedMats = hasSharedMats,
            })
          end
          break  -- Count each player only once (they may have recipe on multiple professions)
        end
      end
    end
  end

  -- Sort: online players first, then alphabetically by name
  table.sort(results, function(a, b)
    if a.online ~= b.online then
      return a.online  -- true > false
    end
    return a.name < b.name
  end)

  return results
end

-- ============================================================================
-- Shared Materials
-- ============================================================================

--[[
  HasSharedMatsForRecipe - Check if player has shared mats for a recipe

  Purpose:
    Determines if a player has any of the required reagents for a recipe
    in their shared materials inventory.

  Parameters:
    @param sharedMats (table) - Player's shared materials: {[itemID] = count, ...}
    @param recipeSpellID (number) - Recipe spell ID

  Returns:
    @return (boolean) - true if player has at least one reagent, false otherwise

  Note:
    This doesn't check if player has ALL required reagents or sufficient quantities,
    just whether they have ANY of the required materials.
]]--
function SND:HasSharedMatsForRecipe(sharedMats, recipeSpellID)
  if not sharedMats then
    return false
  end

  -- Get recipe reagents from Requests module
  local reagents = self:GetRecipeReagents(recipeSpellID)
  if not reagents then
    return false
  end

  -- Check if player has any of the required reagents
  for itemID in pairs(reagents) do
    if sharedMats[itemID] and sharedMats[itemID] > 0 then
      return true
    end
  end

  return false
end

-- ============================================================================
-- UI Helpers
-- ============================================================================

--[[
  GetProfessionFilterOptions - Get list of available professions for filtering

  Purpose:
    Returns a list of all crafting professions (excluding gathering) that
    guild members have. Used to populate profession filter dropdowns.

  Returns:
    @return (table) - Array of profession names (strings)

  Note:
    Excludes gathering professions: Mining, Herbalism, Skinning
]]--
function SND:GetProfessionFilterOptions()
  local gathering = {
    ["Mining"] = true,
    ["Herbalism"] = true,
    ["Skinning"] = true,
  }

  local options = {}
  local seen = {}

  -- Get standard profession options
  for _, option in ipairs(self:GetAllProfessionOptions()) do
    if not gathering[option] then
      table.insert(options, option)
      seen[option] = true
    end
  end

  -- Add professions from active guild members (in case of non-standard professions)
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
