--[[
================================================================================
RequestUI Module  
================================================================================
Manages the Requests tab UI and request lifecycle interactions.

Purpose:
  - Display guild-wide craft request board
  - Filter by status, profession, requester
  - Show request details, materials, and notes
  - Provide action buttons for claiming, crafting, delivering
  - Support moderator actions (force status, delete)

Request Workflow:
  1. OPEN: Available for claiming
  2. CLAIMED: Assigned to a crafter
  3. CRAFTED: Item has been crafted
  4. DELIVERED: Completed successfully
  5. CANCELLED: Cancelled by requester or moderator

UI Components:
  - Search/filter controls
  - Paginated request list
  - Request detail pane
  - Material requirements display
  - Inline notes editor
  - Action buttons (Claim, Unclaim, Crafted, Delivered, Cancel, Delete)

Permissions:
  - Requester can edit notes, cancel own requests
  - Claimer can mark crafted, delivered
  - Officers/Admins can moderate (force status, delete)

Dependencies:
  - Requires: RequestCore.lua (all request operations), RecipeData.lua,
              RecipeSearch.lua, Utils.lua (Tr, GetPlayerKey)
  - Used by: UI.lua (requests tab initialization)

Author: SND Team
Last Modified: 2026-02-13
================================================================================
]]--

local addonName = ...
local SND = _G[addonName]

-- ============================================================================
-- Request Creation
-- ============================================================================

--[[
  PromptNewRequest - Show request creation modal for a recipe

  Purpose:
    Displays the new request creation modal with prefilled data for the
    specified recipe.

  Parameters:
    @param recipeSpellID (number) - Recipe spell ID
    @param context (table|nil) - Optional context data:
      - itemID (number) - Item ID
      - itemLink (string) - Item link
      - itemText (string) - Display text
      - crafterName (string) - Crafter name
      - crafterOnline (boolean) - Crafter online status
      - crafterHasSharedMats (boolean) - Has shared materials
      - crafterProfession (string) - Crafter profession

  Side Effects:
    - Calls ShowRequestModalForRecipe with prefilled data
]]--
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

  --self:DebugLog(string.format(
    --"Request prefill: recipeSpellID=%s recipeName=%s itemID=%s professionSkillLineID=%s professionName=%s",
    --tostring(prefill.recipeSpellID),
    --tostring(prefill.recipeName),
    --tostring(prefill.itemID),
    --tostring(prefill.professionSkillLineID),
    --tostring(prefill.professionName)
  --))

  self:ShowRequestModalForRecipe(recipeSpellID, prefill)
end

-- ============================================================================
-- Request List Rendering
-- ============================================================================

--[[
  RefreshRequestList - Render paginated request list

  Purpose:
    Renders the request list with pagination. Updates all visible rows
    with request data and handles page navigation.

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Updates all listButtons with request data
    - Updates pagination controls
    - Calls SelectRequest for first visible request
]]--
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

-- ============================================================================
-- Request Filtering
-- ============================================================================

--[[
  FilterRequests - Filter and sort requests

  Purpose:
    Filters requests by search query, profession, status, and other criteria.
    Returns sorted array of matching requests.

  Parameters:
    @param requestsFrame (table) - Requests frame with filter state

  Returns:
    @return (table) - Array of filtered requests sorted by updatedAt (desc)
]]--
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

-- ============================================================================
-- Request Detail Display
-- ============================================================================

--[[
  SelectRequest - Display details for selected request

  Purpose:
    Updates the detail pane with comprehensive information about the selected
    request including materials, notes, and action buttons.

  Parameters:
    @param requestsFrame (table) - Requests UI frame
    @param requestId (string|nil) - Request ID to select (nil clears selection)

  Side Effects:
    - Updates requestsFrame.selectedRequestId
    - Updates all detail pane UI elements
    - Calls UpdateRequestActionButtons
]]--
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
    if requestsFrame.workflowStatus then
      requestsFrame.workflowStatus:SetText("")
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

  -- Update workflow status display
  if requestsFrame.workflowStatus then
    local workflowText = self:GetRequestWorkflowText(request)
    requestsFrame.workflowStatus:SetText(workflowText)
  end

  self:UpdateRequestActionButtons(requestsFrame, request)
end

-- ============================================================================
-- Action Button Management
-- ============================================================================

--[[
  UpdateRequestActionButtons - Enable/disable action buttons based on permissions

  Parameters:
    @param requestsFrame (table) - Requests UI frame
    @param request (table) - Request object

  Side Effects:
    - Enables/disables all action buttons based on permissions
]]--
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

-- ============================================================================
-- Request Editing
-- ============================================================================

--[[
  SaveInlineNotes - Save inline notes for a request

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Updates request.notes in database
    - Sends request update to guild
    - Refreshes request list
]]--
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

-- ============================================================================
-- Request Modal Search
-- ============================================================================

--[[
  UpdateRequestSearchResults - Update search results in request modal

  Parameters:
    @param query (string) - Search query

  Side Effects:
    - Updates requestModal.resultButtons with search results
    - Updates pagination in modal
]]--
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

-- ============================================================================
-- Helper Functions
-- ============================================================================

--[[
  GetRequestMaterialsText - Format materials list for request

  Parameters:
    @param request (table) - Request object

  Returns:
    @return (string) - Formatted materials list
]]--
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

--[[
  GetRequestWorkflowText - Generate workflow status display text

  Purpose:
    Creates a visual representation of the request workflow showing
    the full state chain and highlighting the current status.

  Parameters:
    @param request (table) - Request object

  Returns:
    @return (string) - Formatted workflow text with current state highlighted

  Example Output:
    "Workflow: OPEN → |cff00ff00CLAIMED|r → CRAFTED → DELIVERED
     Next: Mark as Crafted (you claimed this)"
]]--
function SND:GetRequestWorkflowText(request)
  if not request or not request.status then
    return ""
  end

  local playerKey = self:GetPlayerKey(UnitName("player"))
  local status = request.status
  local isRequester = request.requester == playerKey
  local isClaimer = request.claimedBy == playerKey

  -- Build workflow chain with current status highlighted
  local states = {"OPEN", "CLAIMED", "CRAFTED", "DELIVERED"}
  local stateDisplay = {}
  for _, state in ipairs(states) do
    if state == status then
      table.insert(stateDisplay, string.format("|cff00ff00%s|r", state))
    else
      table.insert(stateDisplay, state)
    end
  end

  local workflowLine = "Workflow: " .. table.concat(stateDisplay, " → ")

  -- Determine next action text
  local nextAction = ""
  if status == "OPEN" then
    nextAction = "Available to claim"
  elseif status == "CLAIMED" then
    if isClaimer then
      nextAction = "Next: Mark as Crafted (you claimed this)"
    else
      local claimerName = request.claimedBy and request.claimedBy:match("^[^-]+") or "Unknown"
      nextAction = string.format("Claimed by %s", claimerName)
    end
  elseif status == "CRAFTED" then
    if isClaimer then
      nextAction = "Next: Mark as Delivered (you claimed this)"
    else
      nextAction = "Waiting for delivery"
    end
  elseif status == "DELIVERED" then
    nextAction = "Completed"
  elseif status == "CANCELLED" then
    return "|cffff0000Request was cancelled|r"
  end

  if isRequester and status ~= "DELIVERED" and status ~= "CANCELLED" then
    nextAction = nextAction .. " • You can cancel this request"
  end

  return workflowLine .. "\n" .. nextAction
end

--[[
  ShowNewRequestDialog - Show new request creation modal

  Side Effects:
    - Creates and shows request modal
]]--
function SND:ShowNewRequestDialog()
  if self.requestModal and self.requestModal:IsShown() then
    return
  end
  self:CreateRequestModal()
  self:ShowRequestModal()
end

-- ============================================================================
-- Request Status Actions
-- ============================================================================

--[[
  ClaimSelectedRequest - Claim the selected request

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Updates request status to CLAIMED
    - Refreshes request list
]]--
function SND:ClaimSelectedRequest(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "CLAIMED", self:GetPlayerKey(UnitName("player")))
  self:RefreshRequestList(requestsFrame)
  -- Immediately refresh detail pane to show updated status and buttons
  self:SelectRequest(requestsFrame, requestId)
end

--[[
  UnclaimSelectedRequest - Unclaim the selected request with confirmation

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Shows confirmation dialog
    - Updates request status to OPEN if confirmed
    - Refreshes request list
]]--
function SND:UnclaimSelectedRequest(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end

  -- Show confirmation dialog
  if not StaticPopupDialogs["SND_CONFIRM_UNCLAIM"] then
    StaticPopupDialogs["SND_CONFIRM_UNCLAIM"] = {
      text = "Unclaim this request?\n\nIt will return to the open pool for other crafters.",
      button1 = "Unclaim",
      button2 = "Cancel",
      OnAccept = function(_, data)
        if data and data.requestId and data.addon and data.requestsFrame then
          data.addon:UpdateRequestStatus(data.requestId, "OPEN", nil)
          data.addon:RefreshRequestList(data.requestsFrame)
          -- Immediately refresh detail pane to show updated status and buttons
          data.addon:SelectRequest(data.requestsFrame, data.requestId)
        end
      end,
      timeout = 0,
      whileDead = false,
      hideOnEscape = true,
    }
  end

  StaticPopup_Show("SND_CONFIRM_UNCLAIM", nil, nil, {
    requestId = requestId,
    addon = self,
    requestsFrame = requestsFrame,
  })
end

--[[
  MarkSelectedRequestCrafted - Mark selected request as crafted

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Updates request status to CRAFTED
    - Refreshes request list
]]--
function SND:MarkSelectedRequestCrafted(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "CRAFTED", self.db.requests[requestId] and self.db.requests[requestId].claimedBy)
  self:RefreshRequestList(requestsFrame)
  -- Immediately refresh detail pane to show updated status and buttons
  self:SelectRequest(requestsFrame, requestId)
end

--[[
  MarkSelectedRequestDelivered - Mark selected request as delivered

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Updates request status to DELIVERED
    - Refreshes request list
]]--
function SND:MarkSelectedRequestDelivered(requestsFrame)
  local requestId = requestsFrame.selectedRequestId
  if not requestId then
    return
  end
  self:UpdateRequestStatus(requestId, "DELIVERED", self.db.requests[requestId] and self.db.requests[requestId].claimedBy)
  self:RefreshRequestList(requestsFrame)
  -- Immediately refresh detail pane to show updated status and buttons
  self:SelectRequest(requestsFrame, requestId)
end

--[[
  EditSelectedRequestNotes - Edit request notes via dialog

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Shows StaticPopupDialog for editing notes
    - Updates request on save
]]--
function SND:EditSelectedRequestNotes(requestsFrame)
  -- Don't show dialogs during combat
  if InCombatLockdown() then
    self:Print("Cannot edit request notes during combat")
    return
  end

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

--[[
  CancelSelectedRequest - Cancel the selected request

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Updates request status to CANCELLED
    - Refreshes request list
]]--
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
    -- Immediately refresh detail pane to show updated status and buttons
    self:SelectRequest(requestsFrame, requestId)
  end
end

--[[
  DeleteSelectedRequest - Delete the selected request (moderator only)

  Parameters:
    @param requestsFrame (table) - Requests UI frame

  Side Effects:
    - Shows StaticPopupDialog for deletion reason
    - Deletes request on confirm
]]--
function SND:DeleteSelectedRequest(requestsFrame)
  -- Don't show dialogs during combat
  if InCombatLockdown() then
    self:Print("Cannot delete requests during combat")
    return
  end

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
