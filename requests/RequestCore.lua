--[[
================================================================================
RequestCore Module
================================================================================
Core request management system for guild craft request board.

Purpose:
  - Create, update, and delete craft requests
  - Manage request lifecycle (OPEN → CLAIMED → CRAFTED → DELIVERED)
  - Enforce permissions and authorization policies
  - Handle request synchronization across guild

Request Lifecycle:
  1. OPEN: Request created, available for claiming
  2. CLAIMED: Assigned to a crafter
  3. CRAFTED: Item has been crafted
  4. DELIVERED: Completed successfully
  5. CANCELLED: Cancelled by requester or moderator

Key Components:
  - Request CRUD operations (Create, Update, Delete)
  - Permission system (requester, claimer, officer, admin roles)
  - Audit trail for all status changes
  - Material snapshot tracking
  - Network synchronization (via Comms module)

Permissions:
  - Requester can: edit notes, cancel own requests
  - Claimer can: mark crafted, delivered
  - Officers/Admins can: moderate (force status, delete)
  - Guild Master has full permissions

Data Structures:
  - Request: {id, recipeSpellID, qty, notes, status, requester, claimedBy, ...}
  - Tombstone: Deletion record for sync
  - Audit: Status change history

Dependencies:
  - Requires: Utils.lua (GetPlayerKey, Now, HashString),
              DB.lua (requests, players, config),
              Comms.lua (SendAddonMessage, serializer, deflate)
  - Used by: RequestUI.lua (all request operations)

Author: SND Team
Last Modified: 2026-02-13
================================================================================
]]--

local addonName = ...
local SND = _G[addonName]

SND.requests = {}

local STATUS_OPEN = "OPEN"
local STATUS_CLAIMED = "CLAIMED"
local STATUS_CRAFTED = "CRAFTED"
local STATUS_DELIVERED = "DELIVERED"
local STATUS_CANCELLED = "CANCELLED"

local MUTATION_ACTION_STATUS_UPDATE = "STATUS_UPDATE"
local MUTATION_ACTION_REQUESTER_CANCEL = "REQUESTER_CANCEL"
local MUTATION_ACTION_MODERATOR_FORCE_STATUS = "MODERATOR_FORCE_STATUS"
local MUTATION_ACTION_MODERATOR_DELETE = "MODERATOR_DELETE"

local GUILD_ROLE_WEIGHT = {
  member = 1,
  officer = 2,
  admin = 3,
  owner = 4,
}

local function buildRequestId(requesterGuid)
  local now = SND:Now()
  local nonce = math.random(100000, 999999)
  local playerKey = SND:GetPlayerKey(UnitName("player")) or "unknown"
  local guildKey = (SND.db and SND.db.guildKey) or "noguild"
  local seed = string.format("%s|%s|%s|%d|%d", guildKey, playerKey, requesterGuid or "unknown", now, nonce)
  return string.format("req-%s", SND:HashString(seed))
end

local function applyRequestMeta(self, request, now)
  request.id = request.id or nil
  request.entityType = "REQUEST"
  request.version = tonumber(request.version) or 1
  request.updatedBy = request.updatedBy or self:GetPlayerKey(UnitName("player"))
  request.updatedAtServer = tonumber(request.updatedAtServer) or now
  request.updatedAt = request.updatedAtServer
  if request.deletedAtServer ~= nil then
    request.deletedAtServer = tonumber(request.deletedAtServer)
  end
  if type(request.audit) ~= "table" then
    request.audit = {}
  end
  if type(request.cancellation) ~= "table" then
    request.cancellation = nil
  end
  if type(request.moderation) ~= "table" then
    request.moderation = nil
  end
end

local function normalizeModerationReason(reason)
  if type(reason) ~= "string" then
    return nil
  end
  local trimmed = tostring(reason):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil
  end
  if #trimmed > 240 then
    trimmed = string.sub(trimmed, 1, 240)
  end
  return trimmed
end

local function buildAuditEntry(actorKey, actionType, reason, source, now)
  return {
    actor = actorKey,
    action = actionType,
    reason = normalizeModerationReason(reason),
    source = source or "unknown",
    atServer = tonumber(now) or 0,
  }
end

function SND:InitRequests()
  self:RegisterEvent("PLAYER_LOGIN", function(selfRef)
    selfRef:EnsureRequestsTable()
  end)
end

function SND:EnsureRequestsTable()
  if not self.db.requests then
    self.db.requests = {}
  end
end

function SND:NormalizeRequestData(request)
  if type(request) ~= "table" then
    return nil
  end

  if self.NormalizeRecipeSpellID then
    request.recipeSpellID = self:NormalizeRecipeSpellID(request.recipeSpellID)
  else
    if type(request.recipeSpellID) == "table" then
      request.recipeSpellID = tonumber(request.recipeSpellID.recipeSpellID)
        or tonumber(request.recipeSpellID.selectedRecipeSpellID)
        or tonumber(request.recipeSpellID.spellID)
    elseif type(request.recipeSpellID) ~= "number" then
      request.recipeSpellID = tonumber(request.recipeSpellID)
    end
  end

  local normalizedQty = tonumber(request.qty)
  normalizedQty = normalizedQty and math.floor(normalizedQty) or 1
  if normalizedQty < 1 then
    normalizedQty = 1
  end
  request.qty = normalizedQty

  if type(request.notes) ~= "string" then
    request.notes = ""
  end

  if request.needsMats == nil then
    request.needsMats = false
  else
    request.needsMats = request.needsMats and true or false
  end

  if type(request.ownedCounts) ~= "table" then
    request.ownedCounts = {}
  end
  for itemID, value in pairs(request.ownedCounts) do
    local itemNum = tonumber(itemID)
    local countNum = tonumber(value)
    countNum = countNum and math.floor(countNum) or 0
    if not itemNum or countNum < 0 then
      request.ownedCounts[itemID] = nil
    else
      request.ownedCounts[itemNum] = countNum
      if itemNum ~= itemID then
        request.ownedCounts[itemID] = nil
      end
    end
  end

  local now = self:Now()
  applyRequestMeta(self, request, now)

  return request
end

function SND:CreateRequest(recipeSpellID, qty, notes, options)
  if self.NormalizeRecipeSpellID then
    recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  else
    if type(recipeSpellID) == "table" then
      recipeSpellID = tonumber(recipeSpellID.recipeSpellID)
        or tonumber(recipeSpellID.selectedRecipeSpellID)
        or tonumber(recipeSpellID.spellID)
    elseif type(recipeSpellID) ~= "number" then
      recipeSpellID = tonumber(recipeSpellID)
    end
  end
  if not recipeSpellID then
    return nil
  end

  local requester = self:GetPlayerKey(UnitName("player"))
  local requestId = buildRequestId(UnitGUID("player"))
  local now = self:Now()
  local normalizedQty = tonumber(qty)
  normalizedQty = normalizedQty and math.floor(normalizedQty) or 1
  if normalizedQty < 1 then
    normalizedQty = 1
  end

  options = options or {}
  local needsMats = options.needsMats and true or false
  local ownedCounts = {}
  if type(options.ownedCounts) == "table" then
    for itemID, value in pairs(options.ownedCounts) do
      local itemNum = tonumber(itemID)
      local countNum = tonumber(value)
      countNum = countNum and math.floor(countNum) or 0
      if itemNum and countNum >= 0 then
        ownedCounts[itemNum] = countNum
      end
    end
  end

  local request = {
    id = requestId,
    entityType = "REQUEST",
    recipeSpellID = recipeSpellID,
    itemID = nil,
    qty = normalizedQty,
    notes = notes or "",
    needsMats = needsMats,
    ownedCounts = ownedCounts,
    requester = requester,
    claimedBy = nil,
    status = STATUS_OPEN,
    createdAt = now,
    updatedAt = now,
    updatedAtServer = now,
    updatedBy = requester,
    version = 1,
    deletedAtServer = nil,
    requesterMatsSnapshot = self:SnapshotMats(recipeSpellID, normalizedQty),
  }

  self:NormalizeRequestData(request)

  self.db.requests[requestId] = request
  self:SendRequestNew(requestId, request)
  return requestId
end

function SND:UpdateRequestStatus(requestId, newStatus, claimedBy, options)
  local request = self.db.requests[requestId]
  if not request then
    return false
  end

  local actorKey = self:GetPlayerKey(UnitName("player"))
  local eval = self:RequestPolicyEvaluateStatusMutation(request, newStatus, actorKey, claimedBy, options)
  if not eval.allowed then
    return false
  end

  local reason = eval.reason
  if type(eval.options) == "table" then
    reason = eval.options.reason
  end
  if eval.requiresModerationReason then
    reason = normalizeModerationReason(reason)
    if not reason then
      return false
    end
  end

  local now = self:Now()
  request.status = newStatus
  request.claimedBy = claimedBy
  request.version = (tonumber(request.version) or 1) + 1
  request.updatedAtServer = now
  request.updatedAt = request.updatedAtServer
  request.updatedBy = actorKey

  request.audit = buildAuditEntry(actorKey, eval.actionType, reason, eval.source, now)

  if eval.actionType == MUTATION_ACTION_REQUESTER_CANCEL then
    request.cancellation = {
      type = MUTATION_ACTION_REQUESTER_CANCEL,
      actor = actorKey,
      reason = reason,
      atServer = now,
      source = eval.source,
    }
    request.moderation = nil
  elseif eval.actionType == MUTATION_ACTION_MODERATOR_FORCE_STATUS then
    request.moderation = {
      actor = actorKey,
      action = MUTATION_ACTION_MODERATOR_FORCE_STATUS,
      reason = reason,
      atServer = now,
      source = eval.source,
    }
    if newStatus == STATUS_CANCELLED then
      request.cancellation = {
        type = MUTATION_ACTION_MODERATOR_FORCE_STATUS,
        actor = actorKey,
        reason = reason,
        atServer = now,
        source = eval.source,
      }
    end
  elseif newStatus ~= STATUS_CANCELLED then
    request.cancellation = nil
  end

  -- Send delivery notification to requester
  if newStatus == STATUS_DELIVERED then
    self:SendDeliveryNotification(request, actorKey)
  end

  self:SendRequestUpdate(requestId, request)
  return true
end

function SND:CancelRequest(requestId)
  return self:UpdateRequestStatus(requestId, STATUS_CANCELLED)
end

function SND:ModerateRequestStatus(requestId, newStatus, reason, claimedBy)
  local normalizedReason = normalizeModerationReason(reason)
  if not normalizedReason then
    return false
  end
  return self:UpdateRequestStatus(requestId, newStatus, claimedBy, {
    source = "local",
    reason = normalizedReason,
  })
end

function SND:IsGuildMaster(actorKey)
  return self:GetGuildRole(actorKey) == "owner"
end

function SND:GetGuildRole(actorKey)
  local playerKey = actorKey or self:GetPlayerKey(UnitName("player"))
  local entry = self.db.players[playerKey]
  if not entry then
    return "member"
  end

  local explicitRole = self.NormalizeGuildRole and self:NormalizeGuildRole(entry.guildRole) or nil
  if explicitRole then
    return explicitRole
  end

  local isGuildMaster = (entry.guildIsMaster == true) or (tonumber(entry.guildRankIndex) == 0)
  if self.DeriveGuildRoleFromRoster then
    return self:DeriveGuildRoleFromRoster(entry.guildRankIndex, isGuildMaster)
  end
  if isGuildMaster then
    return "owner"
  end

  local rankIndex = tonumber(entry.guildRankIndex)
  if rankIndex == nil then
    return "member"
  end
  local config = (self.db and self.db.config) or {}
  local rolePolicy = config.guildRolePolicy or {}
  local adminMaxRankIndex = math.max(0, math.floor(tonumber(rolePolicy.adminMaxRankIndex) or 0))
  local officerMaxRankIndex = math.max(
    adminMaxRankIndex,
    math.floor(tonumber(rolePolicy.officerMaxRankIndex) or tonumber(config.officerRankIndex) or 1)
  )
  if rankIndex <= adminMaxRankIndex then
    return "admin"
  end
  if rankIndex <= officerMaxRankIndex then
    return "officer"
  end
  return "member"
end

function SND:IsGuildRoleAtLeast(actorKey, minRole)
  local role = self:GetGuildRole(actorKey)
  local roleWeight = GUILD_ROLE_WEIGHT[role] or 0
  local minRoleWeight = GUILD_ROLE_WEIGHT[minRole] or 0
  return roleWeight >= minRoleWeight
end

function SND:ResolveRequestPolicyActorKey(actorKey)
  return actorKey or self:GetPlayerKey(UnitName("player"))
end

function SND:RequestPolicyCanManage(request, actorKey)
  return self:RequestPolicyCanEdit(request, actorKey)
end

function SND:RequestPolicyIsModerator(actorKey)
  local playerKey = self:ResolveRequestPolicyActorKey(actorKey)
  return self:IsGuildRoleAtLeast(playerKey, "admin")
end

function SND:RequestPolicyCanEdit(request, actorKey)
  if type(request) ~= "table" then
    return false
  end
  local playerKey = self:ResolveRequestPolicyActorKey(actorKey)
  return request.requester == playerKey or self:RequestPolicyIsModerator(playerKey)
end

function SND:RequestPolicyCanDelete(request, actorKey)
  if type(request) ~= "table" then
    return false
  end
  return self:RequestPolicyIsModerator(actorKey)
end

function SND:RequestPolicyCanCancel(request, actorKey)
  if type(request) ~= "table" then
    return false
  end
  local playerKey = self:ResolveRequestPolicyActorKey(actorKey)
  if request.requester ~= playerKey then
    return false
  end
  return request.status ~= STATUS_CANCELLED and request.status ~= STATUS_DELIVERED
end

function SND:RequestPolicyEvaluateStatusMutation(request, newStatus, actorKey, claimedBy, options)
  if type(request) ~= "table" then
    return { allowed = false, reason = "invalid_request" }
  end

  local policyActorKey = self:ResolveRequestPolicyActorKey(actorKey)
  local currentStatus = request.status
  local isRequester = request.requester == policyActorKey
  local isClaimer = request.claimedBy == policyActorKey
  local isModerator = self:RequestPolicyIsModerator(policyActorKey)
  local source = type(options) == "table" and options.source or "local"
  local reason = type(options) == "table" and options.reason or nil

  if newStatus == STATUS_CANCELLED and self:RequestPolicyCanCancel(request, policyActorKey) then
    return {
      allowed = true,
      actionType = MUTATION_ACTION_REQUESTER_CANCEL,
      requiresModerationReason = false,
      source = source,
      reason = reason,
      options = options,
    }
  end

  if newStatus == STATUS_CLAIMED and currentStatus == STATUS_OPEN and claimedBy == policyActorKey then
    return {
      allowed = true,
      actionType = MUTATION_ACTION_STATUS_UPDATE,
      requiresModerationReason = false,
      source = source,
      reason = reason,
      options = options,
    }
  end

  if newStatus == STATUS_OPEN and currentStatus == STATUS_CLAIMED and isClaimer then
    return {
      allowed = true,
      actionType = MUTATION_ACTION_STATUS_UPDATE,
      requiresModerationReason = false,
      source = source,
      reason = reason,
      options = options,
    }
  end

  if newStatus == STATUS_CRAFTED and currentStatus == STATUS_CLAIMED and isClaimer then
    return {
      allowed = true,
      actionType = MUTATION_ACTION_STATUS_UPDATE,
      requiresModerationReason = false,
      source = source,
      reason = reason,
      options = options,
    }
  end

  if newStatus == STATUS_DELIVERED and currentStatus == STATUS_CRAFTED and isClaimer then
    return {
      allowed = true,
      actionType = MUTATION_ACTION_STATUS_UPDATE,
      requiresModerationReason = false,
      source = source,
      reason = reason,
      options = options,
    }
  end

  if isModerator and (
    newStatus == STATUS_OPEN
    or newStatus == STATUS_CLAIMED
    or newStatus == STATUS_CRAFTED
    or newStatus == STATUS_DELIVERED
    or newStatus == STATUS_CANCELLED
  ) then
    return {
      allowed = true,
      actionType = MUTATION_ACTION_MODERATOR_FORCE_STATUS,
      requiresModerationReason = true,
      source = source,
      reason = reason,
      options = options,
    }
  end

  return {
    allowed = false,
    reason = "invalid_transition",
  }
end

function SND:RequestPolicyCanUpdate(request, newStatus, actorKey, claimedBy, options)
  local eval = self:RequestPolicyEvaluateStatusMutation(request, newStatus, actorKey, claimedBy, options)
  return eval.allowed == true
end

function SND:RequestPolicyAuthorizeInboundMutation(incomingRequest, existingRequest, actorKey)
  if type(incomingRequest) ~= "table" then
    return false, "invalid_request"
  end

  local policyActorKey = self:ResolveRequestPolicyActorKey(actorKey)
  local updatedBy = tostring(incomingRequest.updatedBy or "")
  if updatedBy == "" then
    return false, "updatedBy_missing"
  end
  if updatedBy ~= policyActorKey then
    return false, "updatedBy_mismatch"
  end

  local normalizedIncoming = incomingRequest
  if type(self.NormalizeRequestData) == "function" then
    normalizedIncoming = self:NormalizeRequestData(incomingRequest)
  end

  local baseRequest = existingRequest or normalizedIncoming
  if not existingRequest then
    if type(baseRequest) ~= "table" then
      return false, "invalid_request"
    end
    local isModerator = self:RequestPolicyIsModerator(policyActorKey)
    local incomingStatus = tostring(baseRequest.status or STATUS_OPEN)
    if incomingStatus ~= STATUS_OPEN and not isModerator then
      return false, "invalid_transition"
    end
    if baseRequest.requester == policyActorKey or isModerator then
      return true
    end
    return false, "insufficient_permissions"
  end

  local statusChanged = tostring(existingRequest.status or "") ~= tostring(normalizedIncoming.status or "")
  if statusChanged then
    local eval = self:RequestPolicyEvaluateStatusMutation(
      existingRequest,
      normalizedIncoming.status,
      policyActorKey,
      normalizedIncoming.claimedBy,
      {
        source = "comms",
        reason = normalizedIncoming
          and normalizedIncoming.moderation
          and normalizedIncoming.moderation.reason
          or nil,
      }
    )
    if not eval.allowed then
      return false, eval.reason or "insufficient_permissions"
    end
    if eval.requiresModerationReason then
      local moderation = type(normalizedIncoming.moderation) == "table" and normalizedIncoming.moderation or {}
      local reason = normalizeModerationReason(moderation.reason)
      local actor = tostring(moderation.actor or "")
      if not reason then
        return false, "moderation_reason_missing"
      end
      if actor ~= "" and actor ~= policyActorKey then
        return false, "moderation_actor_mismatch"
      end
    end
    return true
  end

  if self:RequestPolicyCanEdit(existingRequest, policyActorKey) then
    return true
  end

  return false, "insufficient_permissions"
end

function SND:RequestPolicyAuthorizeInboundDelete(existingRequest, tombstone, actorKey)
  if type(tombstone) ~= "table" then
    return false, "invalid_tombstone"
  end

  local policyActorKey = self:ResolveRequestPolicyActorKey(actorKey)
  local updatedBy = tostring(tombstone.updatedBy or "")
  if updatedBy == "" then
    return false, "updatedBy_missing"
  end
  if updatedBy ~= policyActorKey then
    return false, "updatedBy_mismatch"
  end

  if not self:RequestPolicyIsModerator(policyActorKey) then
    return false, "insufficient_permissions"
  end

  if existingRequest and not self:RequestPolicyCanDelete(existingRequest, policyActorKey) then
    return false, "insufficient_permissions"
  end

  local moderation = type(tombstone.moderation) == "table" and tombstone.moderation or {}
  local reason = normalizeModerationReason(moderation.reason)
  local actor = tostring(moderation.actor or "")
  if not reason then
    return false, "moderation_reason_missing"
  end
  if actor ~= "" and actor ~= policyActorKey then
    return false, "moderation_actor_mismatch"
  end

  return true
end

function SND:CanManageRequest(request, actorKey)
  return self:RequestPolicyCanEdit(request, actorKey)
end

function SND:CanEditRequest(request, actorKey)
  return self:RequestPolicyCanEdit(request, actorKey)
end

function SND:CanDeleteRequest(request, actorKey)
  return self:RequestPolicyCanDelete(request, actorKey)
end

function SND:CanCancelRequest(request, actorKey)
  return self:RequestPolicyCanCancel(request, actorKey)
end

function SND:CanUpdateRequest(request, newStatus, actorKey, claimedBy, options)
  local eval = self:RequestPolicyEvaluateStatusMutation(request, newStatus, actorKey, claimedBy, options)
  if not eval.allowed then
    return false
  end
  if eval.requiresModerationReason then
    local reason = type(options) == "table" and options.reason or nil
    return normalizeModerationReason(reason) ~= nil
  end
  return true
end

function SND:IsOfficerOrAbove(actorKey)
  return self:IsGuildRoleAtLeast(actorKey, "officer")
end

function SND:SnapshotMats(recipeSpellID, qty)
  local snapshot = {}
  local reagents = self:GetRecipeReagents(recipeSpellID)
  if not reagents then
    return snapshot
  end

  for itemID, count in pairs(reagents) do
    local required = count * qty
    local have = GetItemCount(itemID, true)
    snapshot[itemID] = have
  end
  return snapshot
end

function SND:GetRecipeReagents(recipeSpellID)
  if self.NormalizeRecipeSpellID then
    recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  else
    if type(recipeSpellID) == "table" then
      recipeSpellID = tonumber(recipeSpellID.recipeSpellID)
        or tonumber(recipeSpellID.selectedRecipeSpellID)
        or tonumber(recipeSpellID.spellID)
    elseif type(recipeSpellID) ~= "number" then
      recipeSpellID = tonumber(recipeSpellID)
    end
  end

  if not recipeSpellID then
    return nil
  end

  -- Check recipeIndex for cached reagents
  local recipeEntry = self.db.recipeIndex[recipeSpellID]
  if recipeEntry and recipeEntry.reagents then
    return recipeEntry.reagents
  end
  
  -- Try to fetch from API if not cached
  if not C_TradeSkillUI or type(C_TradeSkillUI.GetRecipeSchematic) ~= "function" then
    return nil
  end

  local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, false)
  if not schematic or not schematic.reagentSlotSchematics then
    return nil
  end

  local reagents = {}
  for _, slot in ipairs(schematic.reagentSlotSchematics) do
    if slot.reagents then
      for _, reagent in ipairs(slot.reagents) do
        if reagent.itemID then
          reagents[reagent.itemID] = (reagents[reagent.itemID] or 0) + (reagent.quantityRequired or 1)
        end
      end
    end
  end

  -- Cache the fetched reagents in recipeIndex
  if recipeEntry and next(reagents) then
    recipeEntry.reagents = reagents
    recipeEntry.lastUpdated = self:Now()
    --self:DebugLog(string.format("Requests: cached reagents for recipe %s", tostring(recipeSpellID)))
  end

  return next(reagents) and reagents or nil
end

function SND:SendRequestNew(requestId, request)
  local serialized = self.comms.serializer:Serialize({ id = requestId, data = request })
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  -- Use ALERT priority for instant delivery
  self:SendAddonMessage(string.format("REQ_NEW|%s", encoded), "ALERT")
end

function SND:SendRequestUpdate(requestId, request)
  local serialized = self.comms.serializer:Serialize({ id = requestId, data = request })
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  -- Use ALERT priority for instant status updates
  self:SendAddonMessage(string.format("REQ_UPD|%s", encoded), "ALERT")
end

--[[
  SendDeliveryNotification - Notify requester when request is delivered

  Purpose:
    Sends a chat message to the requester when a crafter marks the
    request as delivered.

  Parameters:
    @param request (table) - Request object
    @param crafterKey (string) - Crafter's player key (who delivered)

  Side Effects:
    - Sends addon message to guild with delivery notification
    - Shows local notification if enabled
]]--
function SND:SendDeliveryNotification(request, crafterKey)
  if not request or not request.requester then
    return
  end

  -- Get item name
  local itemName
  if request.itemLink then
    itemName = request.itemLink
  else
    local _, resolvedText = self:ResolveReadableItemDisplay(request.recipeSpellID, {
      itemID = request.itemID,
      itemLink = request.itemLink,
      itemText = request.itemText,
    })
    itemName = resolvedText or "your request"
  end

  -- Get crafter display name
  local crafterName = crafterKey and crafterKey:match("^[^%-]+") or "Unknown"

  -- Create notification message
  local message = string.format("%s has delivered your request: %s", crafterName, itemName)

  -- Send notification via addon message
  local payload = {
    type = "DELIVERY",
    requestId = request.id,
    requester = request.requester,
    crafter = crafterKey,
    message = message,
  }
  local serialized = self.comms.serializer:Serialize(payload)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  -- Use ALERT priority for instant delivery notifications
  self:SendAddonMessage(string.format("REQ_NOTIFY|%s", encoded), "ALERT")

  -- Show local notification if this is the requester
  local localPlayerKey = self:GetPlayerKey(UnitName("player"))
  if request.requester == localPlayerKey then
    if self.db.config.showNotifications then
      self:Print(string.format("|cff00ff00[Delivery]|r %s", message))
    end
  end
end

function SND:DeleteRequest(requestId, reason, source)
  local request = self.db.requests[requestId]
  if not request then
    return false
  end
  if not self:CanDeleteRequest(request) then
    return false
  end
  local normalizedReason = normalizeModerationReason(reason)
  if not normalizedReason then
    return false
  end
  self:SendRequestDelete(requestId, {
    reason = normalizedReason,
    source = source or "local",
  })
  self.db.requests[requestId] = nil
  return true
end

function SND:SendRequestDelete(requestId, options)
  local actorKey = self:GetPlayerKey(UnitName("player"))
  options = options or {}
  local now = self:Now()
  local moderationReason = normalizeModerationReason(options.reason)

  local tombstone = {
    id = requestId,
    entityType = "REQUEST",
    deletedAtServer = now,
    updatedAtServer = now,
    updatedBy = actorKey,
    deleteType = MUTATION_ACTION_MODERATOR_DELETE,
    moderation = {
      actor = actorKey,
      action = MUTATION_ACTION_MODERATOR_DELETE,
      reason = moderationReason or "legacy_delete_without_reason",
      atServer = now,
      source = options.source or "local",
    },
  }
  self.db.requestTombstones = self.db.requestTombstones or {}
  self.db.requestTombstones[requestId] = tombstone
  local serialized = self.comms.serializer:Serialize({ id = requestId, tombstone = tombstone })
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  -- Use ALERT priority for instant deletion updates
  self:SendAddonMessage(string.format("REQ_DEL|%s", encoded), "ALERT")
end

function SND:SendRequestFullState()
  self.db.requestTombstones = self.db.requestTombstones or {}
  local payload = {
    requests = self.db.requests,
    tombstones = self.db.requestTombstones,
    updatedAtServer = self:Now(),
    updatedBy = self:GetPlayerKey(UnitName("player")),
  }
  local serialized = self.comms.serializer:Serialize(payload)
  local compressed = self.comms.deflate:CompressDeflate(serialized)
  local encoded = self.comms.deflate:EncodeForWoWAddonChannel(compressed)
  self:SendAddonMessage(string.format("REQ_FULL|%s", encoded))
end
