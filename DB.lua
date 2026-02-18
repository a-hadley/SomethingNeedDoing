local addonName = ...
local SND = _G[addonName]
local AceDB = LibStub("AceDB-3.0")

local DEFAULT_DB = {
  schemaVersion = 4,
  guildKey = nil,
  guildData = {},
  players = {},
  recipeIndex = {},
  requests = {},
  requestTombstones = {},
  config = {
    autoPublishOnLogin = true,
    autoPublishOnLearn = true,
    officerRankIndex = 1,
    guildRolePolicy = {
      adminMaxRankIndex = 0,
      officerMaxRankIndex = 1,
    },
    showMinimapButton = true,
    minimapAngle = 220,
    minimapIconDB = {
      minimapPos = 220,
      hide = false,
    },
    debugMode = false,
    priceSource = "auto",
    shareMatsExclusions = {},
    filters = {
      directory = {
        selectedProfession = "All",
        onlineOnly = false,
        sharedMatsOnly = false,
        hideOwnRecipes = false,
        sortBy = "name_az",
      },
      requests = {
        professionFilter = "All",
        statusFilter = "ALL",
        onlyMine = false,
        onlyClaimable = false,
        hasMaterialsOnly = false,
      },
    },
  },
}

local ACE_DB_DEFAULTS = {
  profile = DEFAULT_DB,
}

local function shallowCopy(src)
  local dst = {}
  for key, value in pairs(src) do
    dst[key] = value
  end
  return dst
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

local function isLegacyFlatDB(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  if type(tbl.profile) == "table" then
    return false
  end
  return tbl.schemaVersion ~= nil
    or tbl.guildKey ~= nil
    or type(tbl.players) == "table"
    or type(tbl.recipeIndex) == "table"
    or type(tbl.requests) == "table"
    or type(tbl.config) == "table"
end

local function migrateLegacySavedVariables()
  local existing = _G.SomethingNeedDoingDB
  if not isLegacyFlatDB(existing) then
    return
  end
  _G.SomethingNeedDoingDB = {
    profileKeys = {},
    profiles = {
      Default = deepCopy(existing),
    },
  }
end

function SND:InitDB()
  migrateLegacySavedVariables()
  self.dbRoot = AceDB:New("SomethingNeedDoingDB", ACE_DB_DEFAULTS, true)
  self.db = self.dbRoot.profile
  self:EnsureDBDefaults()
  self:EnsureGuildScope()
  self:MigrateRecipeIndexToPlayerProfessions()
  self:CleanInvalidRecipes()

  -- Strip top-level alias fields before WoW serializes saved variables.
  -- EnsureGuildScope() creates aliases (db.players = bucket.players etc.) so the
  -- rest of the codebase can use self.db.players directly. In memory these are the
  -- same table, but WoW's serializer writes both paths independently, doubling the
  -- file size. Nil them out before save; EnsureGuildScope() recreates them on load.
  self.dbRoot.RegisterCallback(self, "OnDatabaseShutdown", "OnDatabaseShutdown")
end

function SND:OnDatabaseShutdown()
  local db = self.dbRoot and self.dbRoot.profile
  if not db then
    return
  end
  db.players = nil
  db.recipeIndex = nil
  db.requests = nil
  db.requestTombstones = nil
  db.craftLog = nil
end

function SND:ResetDB()
  if self.dbRoot and self.dbRoot.ResetProfile then
    self.dbRoot:ResetProfile()
    self.db = self.dbRoot.profile
  else
    _G.SomethingNeedDoingDB = shallowCopy(DEFAULT_DB)
    self.db = _G.SomethingNeedDoingDB
  end
  self:EnsureDBDefaults()
  self:EnsureGuildScope()

  if self.scanner then
    self.scanner.lastScan = 0
    self.scanner.lastPublish = 0
    self.scanner.pendingPublishDueAt = nil
    self.scanner.lastMatsPublish = 0
    self.scanner.activeScanID = nil
    self.scanner.activeScanRecipesFound = 0
    self.scanner.activeScanAlertShown = false
  end

  if self.comms then
    self.comms.chunkBuffer = {}
    self.comms.guildMemberCache = {}
    self.comms.guildMemberCacheLastRefresh = 0
  end

  if type(self.ClearScanLogBuffer) == "function" then
    self:ClearScanLogBuffer()
  end

  if type(self.UpdateMinimapButtonVisibility) == "function" then
    self:UpdateMinimapButtonVisibility()
  end
  if type(self.RefreshOptions) == "function" then
    self:RefreshOptions()
  end
  if type(self.RefreshAllTabs) == "function" then
    self:RefreshAllTabs()
  end
end

function SND:MigrateRecipeIndexToPlayerProfessions()
  -- v2: Clear incorrect profession data for remote players.
  -- Remote player professions are populated exclusively from PROF_DATA messages
  -- (authoritative per-player data). Local player professions are set by Scanner.lua.
  local localPlayerKey = self:GetPlayerKey(UnitName("player"))
  local cleared = 0
  for playerKey, playerEntry in pairs(self.db.players or {}) do
    if playerKey ~= localPlayerKey and playerEntry.professions then
      playerEntry.professions = {}
      cleared = cleared + 1
    end
  end
  if cleared > 0 then
    self:DebugLog(string.format("DB: migration v2 cleared profession data for %d remote players", cleared), true)
  end

  -- Audit local player: remove profession entries with invalid keys or empty recipes
  local localEntry = localPlayerKey and self.db.players[localPlayerKey]
  if localEntry and type(localEntry.professions) == "table" then
    local pruned = 0
    for profKey, profEntry in pairs(localEntry.professions) do
      local invalid = type(profKey) ~= "number"
      local empty = type(profEntry) ~= "table" or type(profEntry.recipes) ~= "table" or next(profEntry.recipes) == nil
      if invalid or empty then
        localEntry.professions[profKey] = nil
        pruned = pruned + 1
      end
    end
    if pruned > 0 then
      self:DebugLog(string.format("DB: migration v2 pruned %d invalid/empty profession entries from local player", pruned), true)
    end
  end
end

function SND:EnsureDBDefaults()
  local db = self.db
  db.schemaVersion = math.max(tonumber(db.schemaVersion) or 0, DEFAULT_DB.schemaVersion)
  if type(db.guildData) ~= "table" then
    db.guildData = {}
  end
  if not db.players then
    db.players = {}
  end
  if not db.recipeIndex then
    db.recipeIndex = {}
  end
  if not db.requests then
    db.requests = {}
  end
  if not db.requestTombstones then
    db.requestTombstones = {}
  end
  if not db.config then
    db.config = shallowCopy(DEFAULT_DB.config)
  else
    for key, value in pairs(DEFAULT_DB.config) do
      if db.config[key] == nil then
        db.config[key] = value
      end
    end
  end

  local minimapHidden = nil
  if type(db.config.minimapIconDB) == "table" and type(db.config.minimapIconDB.hide) == "boolean" then
    minimapHidden = db.config.minimapIconDB.hide
  end

  if db.config.showMinimapButton == nil then
    if minimapHidden ~= nil then
      db.config.showMinimapButton = not minimapHidden
    else
      db.config.showMinimapButton = DEFAULT_DB.config.showMinimapButton
    end
  else
    db.config.showMinimapButton = db.config.showMinimapButton and true or false
  end

  if db.config.minimapAngle == nil then
    db.config.minimapAngle = DEFAULT_DB.config.minimapAngle
  end

  if type(db.config.minimapIconDB) ~= "table" then
    db.config.minimapIconDB = {
      minimapPos = db.config.minimapAngle,
      hide = not (db.config.showMinimapButton and true or false),
    }
  else
    if db.config.minimapIconDB.minimapPos == nil then
      db.config.minimapIconDB.minimapPos = db.config.minimapAngle
    end
    db.config.minimapIconDB.hide = not (db.config.showMinimapButton and true or false)
  end

  if db.config.shareMatsOptIn == nil then
    db.config.shareMatsOptIn = false
  end

  if db.config.autoPublishMats == nil then
    db.config.autoPublishMats = true
  end

  if db.config.shareMatsExclusions == nil then
    db.config.shareMatsExclusions = {}
  end

  if db.config.priceSource == nil then
    db.config.priceSource = "auto"
  end

  if type(db.config.guildRolePolicy) ~= "table" then
    db.config.guildRolePolicy = deepCopy(DEFAULT_DB.config.guildRolePolicy)
  end

  -- Ensure filter settings exist
  if type(db.config.filters) ~= "table" then
    db.config.filters = deepCopy(DEFAULT_DB.config.filters)
  else
    if type(db.config.filters.directory) ~= "table" then
      db.config.filters.directory = deepCopy(DEFAULT_DB.config.filters.directory)
    end
    if type(db.config.filters.requests) ~= "table" then
      db.config.filters.requests = deepCopy(DEFAULT_DB.config.filters.requests)
    end
  end

  local rolePolicy = db.config.guildRolePolicy
  rolePolicy.adminMaxRankIndex = math.max(0, math.floor(tonumber(rolePolicy.adminMaxRankIndex) or 0))

  if rolePolicy.officerMaxRankIndex == nil then
    rolePolicy.officerMaxRankIndex = math.floor(tonumber(db.config.officerRankIndex) or DEFAULT_DB.config.officerRankIndex)
  end
  rolePolicy.officerMaxRankIndex = math.max(rolePolicy.adminMaxRankIndex, math.floor(tonumber(rolePolicy.officerMaxRankIndex) or rolePolicy.adminMaxRankIndex))

  db.config.officerRankIndex = math.max(rolePolicy.adminMaxRankIndex, math.floor(tonumber(db.config.officerRankIndex) or rolePolicy.officerMaxRankIndex))

  if rolePolicy.officerMaxRankIndex ~= db.config.officerRankIndex then
    rolePolicy.officerMaxRankIndex = db.config.officerRankIndex
  end

  -- One-time migration from legacy flat storage into a guild-scoped bucket.
  local hasGuildBuckets = next(db.guildData) ~= nil
  if not hasGuildBuckets then
    local hasFlatData = (next(db.players or {}) ~= nil)
      or (next(db.recipeIndex or {}) ~= nil)
      or (next(db.requests or {}) ~= nil)
      or (next(db.requestTombstones or {}) ~= nil)
    if hasFlatData then
      local bucketKey = db.guildKey
      if not bucketKey or bucketKey == "" then
        bucketKey = self:GetCurrentGuildKey()
      end
      db.guildData[bucketKey] = {
        players = db.players,
        recipeIndex = db.recipeIndex,
        requests = db.requests,
        requestTombstones = db.requestTombstones,
      }
    end
  end
end

function SND:GetCurrentGuildKey()
  local faction = UnitFactionGroup("player") or "Neutral"
  local realm = GetRealmName() or "Unknown"
  local guildName = GetGuildInfo and GetGuildInfo("player") or nil
  if not guildName or guildName == "" then
    guildName = "__NO_GUILD__"
  end
  return string.format("%s|%s|%s", realm, faction, guildName)
end

function SND:EnsureGuildScope(forceGuildKey)
  local db = self.db
  if type(db) ~= "table" then
    return
  end

  db.guildData = type(db.guildData) == "table" and db.guildData or {}

  local guildKey = forceGuildKey
  if not guildKey or guildKey == "" then
    guildKey = self:GetCurrentGuildKey()
  end
  db.guildKey = guildKey

  local bucket = db.guildData[guildKey]
  if type(bucket) ~= "table" then
    bucket = {
      players = {},
      recipeIndex = {},
      requests = {},
      requestTombstones = {},
      craftLog = {},
    }
    db.guildData[guildKey] = bucket
  end

  bucket.players = type(bucket.players) == "table" and bucket.players or {}
  bucket.recipeIndex = type(bucket.recipeIndex) == "table" and bucket.recipeIndex or {}
  bucket.requests = type(bucket.requests) == "table" and bucket.requests or {}
  bucket.requestTombstones = type(bucket.requestTombstones) == "table" and bucket.requestTombstones or {}
  bucket.craftLog = type(bucket.craftLog) == "table" and bucket.craftLog or {}

  -- Keep legacy top-level fields as aliases to the active guild bucket so the
  -- rest of the codebase can continue using self.db.players/requests/etc.
  db.players = bucket.players
  db.recipeIndex = bucket.recipeIndex
  db.requests = bucket.requests
  db.requestTombstones = bucket.requestTombstones
  db.craftLog = bucket.craftLog
end

function SND:SetGuildKey(guildName)
  if not guildName or guildName == "" then
    self:EnsureGuildScope()
    return
  end
  local faction = UnitFactionGroup("player") or "Neutral"
  local realm = GetRealmName() or "Unknown"
  self:EnsureGuildScope(string.format("%s|%s|%s", realm, faction, guildName))
end

function SND:PurgeStaleData()
  local now = self:Now()
  local cutoffPlayers = now - (30 * 24 * 60 * 60)
  local cutoffRequests = now - (45 * 24 * 60 * 60)

  for playerKey, player in pairs(self.db.players) do
    if player.lastSeen and player.lastSeen < cutoffPlayers then
      self.db.players[playerKey] = nil
    end
  end

  for requestId, request in pairs(self.db.requests) do
    if request.updatedAt and request.updatedAt < cutoffRequests then
      if request.status ~= "OPEN" and request.status ~= "CLAIMED" then
        self.db.requests[requestId] = nil
      end
    end
  end

  for requestId, tombstone in pairs(self.db.requestTombstones) do
    local deletedAt = tombstone and tombstone.deletedAtServer
    if deletedAt and deletedAt < cutoffRequests then
      self.db.requestTombstones[requestId] = nil
    end
  end

  -- Purge old craft log entries (6 months)
  if type(self.PurgeStaleCraftLog) == "function" then
    self:PurgeStaleCraftLog()
  end

  -- Prune orphaned recipes (no known crafter for 30+ days)
  self:PruneOrphanedRecipes()
end

function SND:PruneOrphanedRecipes()
  local now = self:Now()
  local cutoff = now - (30 * 24 * 60 * 60)
  local pruned = 0

  for recipeSpellID, entry in pairs(self.db.recipeIndex) do
    local hasCrafter = false
    for _, player in pairs(self.db.players) do
      if not player.leftGuildAt and player.professions then
        for _, prof in pairs(player.professions) do
          if prof.recipes and prof.recipes[recipeSpellID] then
            hasCrafter = true
            break
          end
        end
      end
      if hasCrafter then break end
    end

    if not hasCrafter then
      if not entry.orphanedAt then
        entry.orphanedAt = now
      elseif entry.orphanedAt < cutoff then
        self.db.recipeIndex[recipeSpellID] = nil
        pruned = pruned + 1
      end
    else
      entry.orphanedAt = nil
    end
  end

  if pruned > 0 then
    self:DebugLog(string.format("DB: PruneOrphanedRecipes removed=%d (no known crafters for 30+ days)", pruned), true)
  end
end

function SND:CleanInvalidRecipes()
  -- Remove recipe entries with non-numeric IDs (e.g., "classic:185::80")
  -- These cannot be resolved by the WoW API and should not be in the database
  local removed = 0

  for recipeSpellID, _ in pairs(self.db.recipeIndex) do
    if type(recipeSpellID) ~= "number" then
      self.db.recipeIndex[recipeSpellID] = nil
      removed = removed + 1
    end
  end

  -- Also clean up player profession recipe lists
  for _, player in pairs(self.db.players) do
    if type(player.professions) == "table" then
      for _, profEntry in pairs(player.professions) do
        if type(profEntry.recipes) == "table" then
          for recipeSpellID, _ in pairs(profEntry.recipes) do
            if type(recipeSpellID) ~= "number" then
              profEntry.recipes[recipeSpellID] = nil
            end
          end
        end
      end
    end
  end

  if removed > 0 then
    self:DebugLog(string.format("DB: CleanInvalidRecipes removed=%d invalid recipe entries", removed), true)
  end

  return removed
end
