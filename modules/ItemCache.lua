--[[
================================================================================
ItemCache Module
================================================================================
Manages in-memory caching of WoW item data with asynchronous loading.

Purpose:
  - Maintains a pending queue for items not yet loaded by WoW API
  - Processes items in batches to avoid overwhelming the client
  - Provides callbacks when item data becomes available
  - Automatically cleans up stale requests

Key Components:
  - Pending Items Queue: Items waiting for WoW API to load
  - Cached Items Store: Successfully loaded item data
  - Batch Processor: Throttled loading mechanism (50 items/batch, 0.1s delay)
  - Event Handler: Responds to GET_ITEM_INFO_RECEIVED

Configuration:
  - maxPendingAge: 300 seconds (5 minutes before giving up)
  - batchSize: 50 items per batch
  - batchDelay: 0.1 seconds between batches
  - maxRetries: 5 attempts before giving up

Cache Behavior:
  - Items load asynchronously from WoW's internal cache
  - First request may take time as client fetches from server
  - Subsequent requests are instant once cached
  - Cleanup runs every 60 seconds to remove stale entries

Dependencies:
  - Requires: Utils.lua (Now, DebugLog, Debounce), DB.lua (recipeIndex)
  - Used by: RecipeData.lua, DirectoryUI.lua, RequestUI.lua

Author: SND Team
Last Modified: 2026-02-13
================================================================================
]]--

local addonName = ...
local SND = _G[addonName]

--[[
  InitItemCache - Initialize the item cache subsystem

  Purpose:
    Sets up the in-memory cache structure and registers the GET_ITEM_INFO_RECEIVED
    event handler. Also schedules periodic cleanup of stale pending items.

  Side Effects:
    - Creates self.itemCache table structure
    - Registers GET_ITEM_INFO_RECEIVED event
    - Schedules repeating cleanup timer (60 second interval)
]]--
function SND:InitItemCache()
  -- Initialize item cache structure (in-memory only, not persisted)
  self.itemCache = {
    pendingItems = {},    -- Items waiting for WoW API to load: { [itemID] = {requestedAt, recipeSpellIDs, callbacks, retryCount} }
    cachedItems = {},     -- Successfully loaded items: { [itemID] = {name, icon, link, cachedAt} }
    config = {
      maxPendingAge = 300,  -- 5 minutes before giving up on pending items
      batchSize = 50,       -- Items to process per batch (prevents overwhelming client)
      batchDelay = 0.1,     -- Seconds between batches (throttling)
      maxRetries = 5        -- Max retry attempts per item before marking unavailable
    },
    batchTimer = nil,       -- Active timer handle for next batch
    processingBatch = false -- Mutex flag to prevent concurrent batch processing
  }

  -- Register GET_ITEM_INFO_RECEIVED event to catch async item data loads
  self:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(selfRef, itemID, success)
    selfRef:OnItemInfoReceived(itemID, success)
  end)

  -- Schedule periodic cleanup (every 60 seconds) to remove stale pending items
  if self.ScheduleRepeatingTimer then
    self:ScheduleRepeatingTimer(function()
      self:CleanupItemCache()
    end, 60)
  end

  self:DebugLog("ItemCache: initialized")
end

--[[
  WarmItemCache - Queue items for preloading into cache

  Purpose:
    Queues multiple item IDs for loading. If items are already cached, callbacks
    fire immediately. Otherwise, items are added to pending queue and batch
    processing is triggered.

  Parameters:
    @param itemIDs (table) - Array of item IDs to cache
    @param recipeSpellID (number|nil) - Optional recipe ID to associate with these items
    @param callback (function|nil) - Optional callback(itemID, cachedData) when item loads

  Side Effects:
    - Updates self.itemCache.pendingItems for uncached items
    - Fires callbacks immediately for already-cached items
    - Triggers batch processing via ScheduleItemCacheBatch()

  Example:
    self:WarmItemCache({12345, 67890}, recipeSpellID, function(itemID, data)
      print("Item loaded:", data.name)
    end)
]]--
function SND:WarmItemCache(itemIDs, recipeSpellID, callback)
  if type(itemIDs) ~= "table" then
    return
  end

  local now = self:Now()
  local queued = 0

  for _, itemID in ipairs(itemIDs) do
    itemID = tonumber(itemID)
    if itemID and itemID > 0 then
      -- Check if already cached - fire callback immediately if so
      if self.itemCache.cachedItems[itemID] then
        if callback then
          callback(itemID, self.itemCache.cachedItems[itemID])
        end
      else
        -- Add to pending queue (or update existing entry)
        if not self.itemCache.pendingItems[itemID] then
          self.itemCache.pendingItems[itemID] = {
            requestedAt = now,
            recipeSpellIDs = {},  -- Track which recipes need this item
            callbacks = {},       -- Array of callbacks to fire when loaded
            retryCount = 0
          }
        end

        local pending = self.itemCache.pendingItems[itemID]

        -- Associate this item with the recipe
        if recipeSpellID then
          pending.recipeSpellIDs[recipeSpellID] = true
        end

        -- Register callback (avoid duplicates)
        if callback and not pending.callbacks[callback] then
          table.insert(pending.callbacks, callback)
          pending.callbacks[callback] = true  -- Mark as registered for dedup
        end

        queued = queued + 1
      end
    end
  end

  if queued > 0 then
    self:DebugLog(string.format("ItemCache: queued %d items for warming", queued))
    -- Trigger batch processing
    self:ScheduleItemCacheBatch()
  end
end

--[[
  ScheduleItemCacheBatch - Schedule the next batch processing run

  Purpose:
    Schedules a delayed batch processing run using Ace3 timer. Prevents scheduling
    multiple timers or scheduling while a batch is already processing.

  Side Effects:
    - Creates timer stored in self.itemCache.batchTimer
    - Timer auto-clears when it fires
]]--
function SND:ScheduleItemCacheBatch()
  -- Don't schedule if already scheduled or processing
  if self.itemCache.batchTimer or self.itemCache.processingBatch then
    return
  end

  if self.ScheduleTimer then
    self.itemCache.batchTimer = self:ScheduleTimer(function()
      self.itemCache.batchTimer = nil
      self:ProcessItemCacheBatch()
    end, self.itemCache.config.batchDelay)
  else
    -- Fallback if timer not available (shouldn't happen with Ace3)
    self:ProcessItemCacheBatch()
  end
end

--[[
  ProcessItemCacheBatch - Process a batch of pending items

  Purpose:
    Attempts to load up to batchSize items from the pending queue. For each item,
    calls GetItemInfo() and GetItemIcon() to check if data is available. If successful,
    caches the data and fires callbacks. If not, increments retry count.

  Algorithm:
    1. Process up to batchSize items from pendingItems
    2. For each item, call GetItemInfo/GetItemIcon
    3. If data available:
       - Cache the item data
       - Update associated recipe entries in DB
       - Fire all registered callbacks
       - Remove from pending queue
    4. If data not available:
       - Increment retry count
       - Keep in pending queue
    5. Schedule next batch if items remain
    6. Trigger UI refresh if any items were cached

  Side Effects:
    - Updates self.itemCache.cachedItems
    - Updates self.db.recipeIndex entries
    - Fires registered callbacks
    - Removes items from pendingItems on success
    - Calls RefreshUIAfterCacheWarm() if items cached
]]--
function SND:ProcessItemCacheBatch()
  -- Mutex: prevent concurrent batch processing
  if self.itemCache.processingBatch then
    return
  end

  self.itemCache.processingBatch = true
  local processed = 0
  local cached = 0
  local stillPending = 0

  -- Process up to batchSize items
  for itemID, pending in pairs(self.itemCache.pendingItems) do
    if processed >= self.itemCache.config.batchSize then
      stillPending = stillPending + 1
    else
      processed = processed + 1

      -- Try to get item info from WoW API
      local name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(itemID)
      local icon = GetItemIcon(itemID)

      if name and icon then
        -- Success! Cache the item
        self.itemCache.cachedItems[itemID] = {
          name = name,
          icon = icon,
          link = link,
          cachedAt = self:Now()
        }

        -- Update all associated recipe entries in the database
        for recipeSpellID in pairs(pending.recipeSpellIDs) do
          local entry = self.db.recipeIndex[recipeSpellID]
          if entry then
            if entry.outputItemID == itemID then
              entry.itemName = name
              entry.itemIcon = icon
              entry.itemDataStatus = "cached"
              entry.lastUpdated = self:Now()
            end
          end
        end

        -- Fire all registered callbacks
        for _, callback in ipairs(pending.callbacks) do
          if type(callback) == "function" then
            local ok, err = pcall(callback, itemID, self.itemCache.cachedItems[itemID])
            if not ok then
              self:DebugLog(string.format("ItemCache: callback error for item %d: %s", itemID, tostring(err)))
            end
          end
        end

        -- Remove from pending (successfully cached)
        self.itemCache.pendingItems[itemID] = nil
        cached = cached + 1
      else
        -- Still not available, increment retry count
        pending.retryCount = (pending.retryCount or 0) + 1
        stillPending = stillPending + 1
      end
    end
  end

  self.itemCache.processingBatch = false

  if cached > 0 or processed > 0 then
    self:DebugLog(string.format("ItemCache: batch processed=%d cached=%d stillPending=%d", processed, cached, stillPending))
  end

  -- Schedule next batch if items remain pending
  if stillPending > 0 then
    self:ScheduleItemCacheBatch()
  end

  -- Trigger UI refresh if items were cached (debounced)
  if cached > 0 then
    self:RefreshUIAfterCacheWarm()
  end
end

--[[
  OnItemInfoReceived - Event handler for GET_ITEM_INFO_RECEIVED

  Purpose:
    WoW fires this event when item data becomes available after a GetItemInfo() call.
    This handler attempts to cache pending items that may have just loaded.

  Parameters:
    @param itemID (number) - The item ID that just loaded
    @param success (boolean) - Whether the load was successful

  Side Effects:
    - Same as ProcessItemCacheBatch for the specific item
    - Updates cache, DB entries, fires callbacks, removes from pending
]]--
function SND:OnItemInfoReceived(itemID, success)
  itemID = tonumber(itemID)
  if not itemID then
    return
  end

  local pending = self.itemCache.pendingItems[itemID]
  if not pending then
    return
  end

  -- Retry getting item info
  local name, link = GetItemInfo(itemID)
  local icon = GetItemIcon(itemID)

  if name and icon then
    -- Success! Cache the item
    self.itemCache.cachedItems[itemID] = {
      name = name,
      icon = icon,
      link = link,
      cachedAt = self:Now()
    }

    -- Update all associated recipe entries
    for recipeSpellID in pairs(pending.recipeSpellIDs) do
      local entry = self.db.recipeIndex[recipeSpellID]
      if entry then
        if entry.outputItemID == itemID then
          entry.itemName = name
          entry.itemIcon = icon
          entry.itemDataStatus = "cached"
          entry.lastUpdated = self:Now()
        end
      end
    end

    -- Fire all callbacks
    for _, callback in ipairs(pending.callbacks) do
      if type(callback) == "function" then
        local ok, err = pcall(callback, itemID, self.itemCache.cachedItems[itemID])
        if not ok then
          self:DebugLog(string.format("ItemCache: callback error for item %d: %s", itemID, tostring(err)))
        end
      end
    end

    -- Remove from pending
    self.itemCache.pendingItems[itemID] = nil

    self:DebugLog(string.format("ItemCache: item %d cached via GET_ITEM_INFO_RECEIVED", itemID))

    -- Trigger UI refresh (debounced)
    self:RefreshUIAfterCacheWarm()
  end
end

--[[
  GetCachedItemInfo - Retrieve item data from cache or WoW API

  Purpose:
    Multi-source item data retrieval with fallback:
    1. Check cache first
    2. Try direct API call
    3. Return pending status if queued
    4. Return nil if unavailable

  Parameters:
    @param itemID (number) - The item ID to retrieve

  Returns:
    @return (table|nil) - Cached item data {name, icon, link, cachedAt}
    @return (table) - {isPending=true} if item is in pending queue
    @return nil - If item is not available

  Side Effects:
    - May cache item if API call succeeds
]]--
function SND:GetCachedItemInfo(itemID)
  itemID = tonumber(itemID)
  if not itemID then
    return nil
  end

  -- Check cache first (fastest path)
  if self.itemCache.cachedItems[itemID] then
    return self.itemCache.cachedItems[itemID]
  end

  -- Try direct API call (may succeed if recently loaded)
  local name, link = GetItemInfo(itemID)
  local icon = GetItemIcon(itemID)

  if name and icon then
    -- Cache it for future use
    self.itemCache.cachedItems[itemID] = {
      name = name,
      icon = icon,
      link = link,
      cachedAt = self:Now()
    }
    return self.itemCache.cachedItems[itemID]
  end

  -- Check if pending (gives caller option to wait)
  if self.itemCache.pendingItems[itemID] then
    return { isPending = true }
  end

  return nil
end

--[[
  CleanupItemCache - Remove stale pending items

  Purpose:
    Periodic cleanup of pending items that are too old or have exceeded retry limits.
    Marks associated recipes as "unavailable" in the database.

  Removal Criteria:
    - Age > maxPendingAge (5 minutes)
    - OR retryCount > maxRetries (5 attempts)

  Side Effects:
    - Removes entries from self.itemCache.pendingItems
    - Updates self.db.recipeIndex entries with itemDataStatus="unavailable"
]]--
function SND:CleanupItemCache()
  local now = self:Now()
  local removed = 0

  for itemID, pending in pairs(self.itemCache.pendingItems) do
    local age = now - pending.requestedAt

    -- Remove if too old or too many retries
    if age > self.itemCache.config.maxPendingAge or
       pending.retryCount > self.itemCache.config.maxRetries then

      -- Mark associated recipes as "unavailable"
      for recipeSpellID in pairs(pending.recipeSpellIDs) do
        local entry = self.db.recipeIndex[recipeSpellID]
        if entry then
          entry.itemDataStatus = "unavailable"
        end
      end

      self.itemCache.pendingItems[itemID] = nil
      removed = removed + 1
    end
  end

  if removed > 0 then
    self:DebugLog(string.format("ItemCache: cleaned up %d stale items", removed))
  end
end

--[[
  RefreshUIAfterCacheWarm - Trigger debounced UI refresh

  Purpose:
    Refreshes the main window UI after items are cached. Debounced to prevent
    excessive updates when many items load in quick succession.

  Debouncing:
    - Uses "item_cache_ui_refresh" debounce key
    - 0.5 second delay (multiple cache updates collapse into one refresh)

  Side Effects:
    - Calls self:RefreshAllTabs() after delay (if window is shown)
]]--
function SND:RefreshUIAfterCacheWarm()
  -- Debounced UI refresh to avoid excessive updates
  self:Debounce("item_cache_ui_refresh", 0.5, function()
    if self.mainFrame and self.mainFrame:IsShown() then
      self:RefreshAllTabs()
    end
  end)
end
