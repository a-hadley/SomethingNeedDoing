local addonName = ...
local SND = _G[addonName]

local VALID_GUILD_ROLES = {
  owner = true,
  admin = true,
  officer = true,
  member = true,
}

SND.roster = {
  lastScan = 0,
}

local function getNumGuildMembers()
  if GetNumGuildMembers then
    return GetNumGuildMembers()
  end
  return 0
end

local function refreshGuildRoster(self)
  if type(GuildRoster) == "function" then
    GuildRoster()
    return true
  end

  if type(C_GuildInfo) == "table" and type(C_GuildInfo.GuildRoster) == "function" then
    C_GuildInfo.GuildRoster()
    return true
  end

  return false
end

function SND:NormalizeGuildRole(role)
  if type(role) ~= "string" then
    return nil
  end
  local normalized = string.lower(role)
  if VALID_GUILD_ROLES[normalized] then
    return normalized
  end
  return nil
end

function SND:DeriveGuildRoleFromRoster(rankIndex, isGuildMaster)
  if isGuildMaster then
    return "owner"
  end

  local rankNum = tonumber(rankIndex)
  if rankNum == nil then
    return "member"
  end

  local config = (self.db and self.db.config) or {}
  local rolePolicy = type(config.guildRolePolicy) == "table" and config.guildRolePolicy or {}
  local adminMaxRankIndex = math.max(0, math.floor(tonumber(rolePolicy.adminMaxRankIndex) or 0))
  local officerMaxRankIndex = math.max(
    adminMaxRankIndex,
    math.floor(tonumber(rolePolicy.officerMaxRankIndex) or tonumber(config.officerRankIndex) or 1)
  )

  if rankNum <= adminMaxRankIndex then
    return "admin"
  end
  if rankNum <= officerMaxRankIndex then
    return "officer"
  end
  return "member"
end

function SND:InitRoster()
  if self.RegisterBucketEvent then
    self:RegisterBucketEvent("GUILD_ROSTER_UPDATE", 1.0, function()
      self:ScanGuildRoster()
    end)
  else
    self:RegisterEvent("GUILD_ROSTER_UPDATE", function(selfRef)
      selfRef:ScanGuildRoster()
    end)
  end
  if IsInGuild() then
    refreshGuildRoster(self)
  end
end

function SND:ScanGuildRoster()
  if not IsInGuild() then
    self:SetGuildKey(nil)
    if type(self.UpdateGuildMemberCache) == "function" then
      self:UpdateGuildMemberCache({})
    end
    return
  end

  self:SetGuildKey(GetGuildInfo and GetGuildInfo("player") or nil)

  local numMembers = getNumGuildMembers()
  local memberSet = {}
  local localPlayerKey = self:GetPlayerKey(UnitName("player"))
  local localGuildMasterStatus = type(UnitIsGuildLeader) == "function" and UnitIsGuildLeader("player") and true or false
  for index = 1, numMembers do
    local name, _rankName, rankIndex, _, _, _, _, _, online, _, classFilename = GetGuildRosterInfo(index)
    if name then
      local nameOnly = strsplit("-", name)
      local playerKey = self:GetPlayerKey(nameOnly)
      local entry = self.db.players[playerKey] or {}
      local isGuildMaster = (tonumber(rankIndex) == 0)
      if playerKey == localPlayerKey and type(UnitIsGuildLeader) == "function" then
        isGuildMaster = localGuildMasterStatus
      end
      entry.class = classFilename
      entry.guildRankIndex = rankIndex
      entry.guildRole = self:DeriveGuildRoleFromRoster(rankIndex, isGuildMaster)
      entry.guildIsMaster = isGuildMaster and true or false
      entry.lastSeen = self:Now()
      entry.online = online and true or false
      entry.sharedMats = entry.sharedMats or nil
      self.db.players[playerKey] = entry
      memberSet[nameOnly] = true
    end
  end

  -- Detect players who left the guild and mark/purge them
  local leftGuildCutoff = self:Now() - (7 * 24 * 60 * 60)  -- 7 days
  for playerKey, entry in pairs(self.db.players) do
    local nameOnly = strsplit("-", playerKey)
    if not memberSet[nameOnly] and playerKey ~= localPlayerKey then
      if not entry.leftGuildAt then
        entry.leftGuildAt = self:Now()
        entry.online = false
      elseif entry.leftGuildAt < leftGuildCutoff then
        self.db.players[playerKey] = nil
      end
    else
      entry.leftGuildAt = nil  -- Clear if they're in guild
    end
  end

  if type(self.UpdateGuildMemberCache) == "function" then
    self:UpdateGuildMemberCache(memberSet)
  end

  self.roster.lastScan = self:Now()
end
