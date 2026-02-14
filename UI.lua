local addonName = ...
local SND = _G[addonName]

local function T(key, ...)
  if SND and SND.Tr then
    return SND:Tr(key, ...)
  end
  if select("#", ...) > 0 then
    return string.format(key, ...)
  end
  return key
end

local MAIN_FRAME_WIDTH = 1280
local MAIN_FRAME_HEIGHT = 800
local SND_MAIN_STRATA = "HIGH"
local SND_MODAL_STRATA = "DIALOG"
local SND_FRONT_LEVEL_OFFSET = 40

function SND:BringAddonFrameToFront(frame, strata)
  if not frame then
    return
  end

  if strata then
    frame:SetFrameStrata(strata)
  end

  local parent = frame:GetParent()
  local baseLevel = 0
  if parent and parent.GetFrameLevel then
    baseLevel = parent:GetFrameLevel() or 0
  end

  local desiredLevel = baseLevel + SND_FRONT_LEVEL_OFFSET
  if frame.GetFrameLevel and frame.SetFrameLevel and frame:GetFrameLevel() < desiredLevel then
    frame:SetFrameLevel(desiredLevel)
  end

  if frame.Raise then
    frame:Raise()
  end
end

local function CreateBoundedCheckbox(parent, labelText)
  local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  box:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  box:SetBackdropColor(0.05, 0.05, 0.08, 1)
  box:SetSize(180, 28)

  local checkbox = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
  checkbox:SetPoint("LEFT", 6, 0)
  checkbox.text:ClearAllPoints()
  checkbox.text:SetPoint("LEFT", checkbox, "RIGHT", 6, 0)
  checkbox.text:SetText(labelText)

  local textWidth = checkbox.text:GetStringWidth() or 0
  box:SetWidth(math.max(160, 26 + textWidth + 28))

  return box, checkbox
end

function SND:BuildSharedMatsList(query)
  local cleaned = string.lower((query or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  local exclusions = (self.db.config and self.db.config.shareMatsExclusions) or {}
  local seen = {}
  local items = {}
  local maxItems = 200

  for _, entry in pairs(self.db.recipeIndex or {}) do
    local reagents = entry.reagents
    if reagents then
      for itemID in pairs(reagents) do
        if not seen[itemID] then
          seen[itemID] = true
          local name = GetItemInfo(itemID) or ("Item " .. itemID)
          local count = GetItemCount(itemID, true) or 0
          local matches = cleaned == "" or string.find(string.lower(name), cleaned, 1, true) or string.find(tostring(itemID), cleaned, 1, true)
          if matches then
            table.insert(items, {
              itemID = itemID,
              name = name,
              count = count,
              excluded = exclusions[itemID] and true or false,
            })
          end
          if #items >= maxItems then
            table.sort(items, function(a, b)
              return a.name < b.name
            end)
            return items
          end
        end
      end
    end
  end

  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return items
end

function SND:RefreshSharedMatsList(meFrame)
  if not meFrame or not meFrame.sharedMatsRows then
    return
  end
  local query = meFrame.sharedMatsSearchBox and meFrame.sharedMatsSearchBox:GetText() or ""
  local items = self:BuildSharedMatsList(query)
  local rows = meFrame.sharedMatsRows

  for i, row in ipairs(rows) do
    local item = items[i]
    if item then
      row.itemID = item.itemID
      row.nameText:SetText(item.name)
      row.countText:SetText(tostring(item.count))
      row:SetChecked(not item.excluded)
      row:Show()
    else
      row.itemID = nil
      row:Hide()
    end
  end

  if meFrame.sharedMatsEmptyLabel then
    if #items == 0 then
      meFrame.sharedMatsEmptyLabel:Show()
    else
      meFrame.sharedMatsEmptyLabel:Hide()
    end
  end

  if meFrame.sharedMatsScrollChild then
    local rowHeight = meFrame.sharedMatsRowHeight or 22
    meFrame.sharedMatsScrollChild:SetHeight(math.max(#items, #rows) * rowHeight)
  end
end

function SND:RefreshScanLogCopyBox(meFrame)
  local editBox = self.scanLogCopyEditBox
  if not editBox then
    return
  end

  local logText = ""
  if self.GetScanLogText then
    logText = self:GetScanLogText() or ""
  end

  editBox:SetText(logText)
  if self.scanLogCopyScroll and self.scanLogCopyScroll.SetVerticalScroll then
    self.scanLogCopyScroll:SetVerticalScroll(0)
  end
end

function SND:OpenScanLogCopyBox(meFrame)
  if not self.scanLogCopyModal or not self.scanLogCopyEditBox then
    return
  end

  self:RefreshScanLogCopyBox()
  self:BringAddonFrameToFront(self.scanLogCopyModal, SND_MODAL_STRATA)
  self.scanLogCopyModal:Show()
  self:BringAddonFrameToFront(self.scanLogCopyModal, SND_MODAL_STRATA)
  self.scanLogCopyEditBox:SetFocus()
  self.scanLogCopyEditBox:HighlightText()
end

function SND:CloseScanLogCopyBox(meFrame)
  if not self.scanLogCopyModal then
    return
  end
  self.scanLogCopyModal:Hide()
end

function SND:InitUI()
  self:CreateMainWindow()
  self:CreateRequestPopup()
end

function SND:CreateMainWindow()
  local frame = CreateFrame("Frame", "SNDMainFrame", UIParent, "BackdropTemplate")

  -- Restore saved size or use defaults
  local savedWidth = self.db and self.db.config and self.db.config.windowWidth
  local savedHeight = self.db and self.db.config and self.db.config.windowHeight
  local width = savedWidth or MAIN_FRAME_WIDTH
  local height = savedHeight or MAIN_FRAME_HEIGHT

  frame:SetSize(width, height)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata(SND_MAIN_STRATA)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetScript("OnShow", function(shownFrame)
    SND:BringAddonFrameToFront(shownFrame, SND_MAIN_STRATA)
  end)
  frame:SetScript("OnMouseDown", function(mouseFrame)
    SND:BringAddonFrameToFront(mouseFrame, SND_MAIN_STRATA)
  end)
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(720, 420, 1200, 800)
  else
    if frame.SetMinResize then
      frame:SetMinResize(720, 420)
    end
    if frame.SetMaxResize then
      frame:SetMaxResize(1200, 800)
    end
  end
  frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  frame:SetBackdropColor(0.08, 0.08, 0.1, 1)
  frame:Hide()

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  title:SetPoint("TOP", 0, -16)
  title:SetText(T("Something Need Doing?"))

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  -- Add resize grip
  local resizeButton = CreateFrame("Button", nil, frame)
  resizeButton:SetSize(16, 16)
  resizeButton:SetPoint("BOTTOMRIGHT", -6, 6)
  resizeButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  resizeButton:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  resizeButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  resizeButton:SetScript("OnMouseDown", function()
    frame:StartSizing("BOTTOMRIGHT")
  end)
  resizeButton:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    SND:SaveWindowSize()
  end)

  local tabs = {}
  local tabNames = { T("Directory"), T("Requests"), T("Options"), }
  for i, label in ipairs(tabNames) do
    local tab = CreateFrame("Button", "SNDMainFrameTab" .. i, frame, "OptionsFrameTabButtonTemplate")
    tab:SetID(i)
    tab:SetText(label)
    tab:SetScript("OnClick", function()
      SND:SelectTab(i)
    end)
    tabs[i] = tab
    if i == 1 then
      tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -28)
    else
      tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", 8, 0)
    end
  end

  frame.tabs = tabs
  frame.activeTab = 1
  PanelTemplates_SetNumTabs(frame, #tabs)
  PanelTemplates_SetTab(frame, 1)

  frame.contentFrames = {
    self:CreateDirectoryTab(frame),
    self:CreateRequestsTab(frame),
    self:CreateMeTab(frame),
  }
  self:BringAddonFrameToFront(frame, SND_MAIN_STRATA)
  self.mainFrame = frame
  self:SelectTab(1)
end

function SND:SelectTab(index)
  if not self.mainFrame then
    return
  end
  if self.TraceScanLog then
    self:TraceScanLog(string.format("ui-tab: select index=%s", tostring(index)))
  end
  self.mainFrame.activeTab = index
  PanelTemplates_SetTab(self.mainFrame, index)

  for i, tab in ipairs(self.mainFrame.tabs or {}) do
    if i == index then
      tab:SetAlpha(1)
    else
      tab:SetAlpha(0.6)
    end
  end

  for i, content in ipairs(self.mainFrame.contentFrames or {}) do
    if i == index then
      content:Show()
    else
      content:Hide()
    end
  end

  if index == 2 then
    local requestsFrame = self.mainFrame.contentFrames[2]
    if requestsFrame then
      SND:RefreshRequestList(requestsFrame)
    end
  elseif index == 3 then
    local meFrame = self.meTabFrame or self.mainFrame.contentFrames[3]
    if meFrame then
      self.meTabFrame = meFrame
      if self.TraceScanLog then
        self:TraceScanLog(string.format("ui-tab: me activated pendingDirty=%s", tostring(self._scanLogPendingDirty)))
      end
      SND:RefreshMeTab(meFrame)
      if self.PushScanLogLineToUI then
        self:PushScanLogLineToUI("LOG VIEWER READY")
      end
      if self._scanLogPendingDirty and self.TraceScanLog then
        self:TraceScanLog("ui-tab: replay pending dirty scan log")
      end
    end
  end
end

function SND:ToggleMainWindow()
  if not self.mainFrame then
    self:CreateMainWindow()
  end
  if self.mainFrame:IsShown() then
    self.mainFrame:Hide()
  else
    self:BringAddonFrameToFront(self.mainFrame, SND_MAIN_STRATA)
    self.mainFrame:Show()
    self:BringAddonFrameToFront(self.mainFrame, SND_MAIN_STRATA)
  end
end

function SND:CreateContentFrame(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetPoint("TOPLEFT", 12, -38)
  frame:SetPoint("BOTTOMRIGHT", -12, 12)
  frame:Hide()
  return frame
end

function SND:CreateDirectoryTab(parent)
  local frame = self:CreateContentFrame(parent)

  local filterBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  filterBar:SetPoint("TOPLEFT", 8, -12)
  filterBar:SetPoint("TOPRIGHT", -8, -12)
  filterBar:SetHeight(110)
  filterBar:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  filterBar:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local searchBox = CreateFrame("EditBox", nil, filterBar, "InputBoxTemplate")
  searchBox:SetSize(180, 28)
  searchBox:SetPoint("TOPLEFT", 14, -22)
  searchBox:SetAutoFocus(false)
  searchBox:SetScript("OnEnterPressed", function(edit)
    edit:ClearFocus()
    SND:UpdateDirectoryResults(edit:GetText())
  end)
  searchBox:SetScript("OnTextChanged", function(edit)
    SND:Debounce("directory_search", 0.2, function()
      SND:UpdateDirectoryResults(edit:GetText())
    end)
  end)
  searchBox:SetScript("OnEscapePressed", function(edit)
    edit:ClearFocus()
  end)

  local searchLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  searchLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 0, -4)
  searchLabel:SetText(T("Search"))

  local professionLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  professionLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPRIGHT", 12, -4)
  professionLabel:SetText(T("Profession"))

  local professionDrop = CreateFrame("Frame", "SNDProfessionDropDown", filterBar, "UIDropDownMenuTemplate")
  professionDrop:SetPoint("LEFT", professionLabel, "RIGHT", -10, -16)

  local onlineBox, onlineOnly = CreateBoundedCheckbox(filterBar, T("Online Only"))
  onlineBox:SetPoint("LEFT", professionDrop, "RIGHT", 0, -4)
  onlineOnly:SetScript("OnClick", function(btn)
    frame.onlineOnly = btn:GetChecked() and true or false
    SND:UpdateDirectoryResults(searchBox:GetText())
  end)

  local matsBox, matsOnly = CreateBoundedCheckbox(filterBar, T("Has Materials"))
  matsBox:SetPoint("LEFT", onlineBox, "RIGHT", 2, 0)
  matsOnly:SetScript("OnClick", function(btn)
    frame.sharedMatsOnly = btn:GetChecked() and true or false
    SND:UpdateDirectoryResults(searchBox:GetText())
  end)

  local hideOwnBox, hideOwnCheckbox = CreateBoundedCheckbox(filterBar, T("Hide My Recipes"))
  hideOwnBox:SetPoint("LEFT", matsBox, "RIGHT", 2, 0)
  hideOwnCheckbox:SetScript("OnClick", function(btn)
    frame.hideOwnRecipes = btn:GetChecked() and true or false
    SND:UpdateDirectoryResults(searchBox:GetText())
  end)

  -- Sort dropdown
  local sortLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sortLabel:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -36)
  sortLabel:SetText(T("Sort by"))

  local sortDrop = CreateFrame("Frame", "SNDSortDropDown", filterBar, "UIDropDownMenuTemplate")
  sortDrop:SetPoint("LEFT", sortLabel, "RIGHT", -10, -16)

  UIDropDownMenu_Initialize(sortDrop, function(dropdown, level)
    local options = {
      { value = "name_az", text = T("Name (A-Z)") },
      { value = "name_za", text = T("Name (Z-A)") },
      { value = "rarity", text = T("Rarity (High to Low)") },
      { value = "level", text = T("Level (High to Low)") },
    }
    for _, option in ipairs(options) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = option.text
      info.checked = option.value == frame.sortBy
      info.func = function()
        frame.sortBy = option.value
        UIDropDownMenu_SetText(sortDrop, option.text)
        SND:UpdateDirectoryResults(searchBox:GetText())
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(sortDrop, 150)
  UIDropDownMenu_SetText(sortDrop, T("Name (A-Z)"))

  local columnGap = 10

  local listContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  listContainer:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -8)
  listContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 12)
  -- Use relative positioning: ~26% of parent width (min 720px * 0.26 = 187px)
  listContainer:SetPoint("RIGHT", frame, "LEFT", 195, 0)
  listContainer:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  listContainer:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local listTitle = listContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  listTitle:SetPoint("TOPLEFT", 8, -8)
  listTitle:SetText(T("Matching Items"))

  local scrollFrame = CreateFrame("ScrollFrame", "SNDDirectoryScrollFrame", listContainer, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", 6, -28)
  scrollFrame:SetPoint("BOTTOMRIGHT", -26, 6)

  local scrollChild = CreateFrame("Frame", nil, scrollFrame)
  scrollChild:SetSize(256, 120)
  scrollFrame:SetScrollChild(scrollChild)

  local detailContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  detailContainer:SetPoint("TOPLEFT", listContainer, "TOPRIGHT", columnGap, 0)
  detailContainer:SetPoint("BOTTOMLEFT", listContainer, "BOTTOMRIGHT", columnGap, 0)
  -- Use relative positioning: ~25% of parent width (min 720px * 0.25 = 180px)
  detailContainer:SetPoint("RIGHT", frame, "LEFT", 390, 0)
  detailContainer:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  detailContainer:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local rightContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  rightContainer:SetPoint("TOPLEFT", detailContainer, "TOPRIGHT", columnGap, 0)
  rightContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 12)
  rightContainer:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  rightContainer:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local detailTitle = CreateFrame("Button", nil, detailContainer)
  detailTitle:SetPoint("TOPLEFT", 8, -8)
  detailTitle:SetPoint("TOPRIGHT", -8, -8)
  detailTitle:SetHeight(22)
  local detailTitleText = detailTitle:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detailTitleText:SetPoint("LEFT")
  detailTitleText:SetPoint("RIGHT")
  detailTitleText:SetJustifyH("LEFT")
  detailTitleText:SetText(T("Select a recipe"))
  detailTitle:SetScript("OnEnter", function()
    if frame.selectedRecipeLink then
      GameTooltip:SetOwner(detailTitle, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(frame.selectedRecipeLink)
      GameTooltip:Show()
    end
  end)
  detailTitle:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  local detailSummaryText = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detailSummaryText:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -4)
  detailSummaryText:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  detailSummaryText:SetJustifyH("LEFT")
  detailSummaryText:SetWordWrap(true)

  local sharedMatsSummary = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  sharedMatsSummary:SetPoint("TOPLEFT", detailSummaryText, "BOTTOMLEFT", 0, -4)
  sharedMatsSummary:SetText("")
  sharedMatsSummary:Hide()

  local craftersTitle = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  craftersTitle:SetPoint("TOPLEFT", sharedMatsSummary, "BOTTOMLEFT", 0, -8)
  craftersTitle:SetText(T("Available Crafters"))

  local nameColumnWidth = 74
  local statusColumnWidth = 48
  local matsColumnWidth = 26
  local actionColumnWidth = 26
  local columnNameX = 4
  local columnStatusX = columnNameX + nameColumnWidth + columnGap
  local columnMatsX = columnStatusX + statusColumnWidth + columnGap
  local ColumnActionsX = columnMatsX + matsColumnWidth + columnGap
  local actionRightPadding = 6
  local actionButtonGap = 4
  local whisperButtonWidth = 34
  local requestButtonWidth = 52
  -- Scroll child width will be set dynamically based on parent

  local crafterHeaderName = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderName:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", columnNameX, -6)
  crafterHeaderName:SetText(T("Crafter"))

  local crafterHeaderStatus = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderStatus:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", columnStatusX, -6)
  crafterHeaderStatus:SetText(T("Status"))

  local crafterHeaderMats = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderMats:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", columnMatsX, -6)
  crafterHeaderMats:SetText(T("Mats"))

  local crafterHeaderActions = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderActions:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", ColumnActionsX, -6)
  crafterHeaderActions:SetJustifyH("LEFT")
  crafterHeaderActions:SetText(T("Actions"))

  local crafterScrollFrame = CreateFrame("ScrollFrame", nil, detailContainer, "UIPanelScrollFrameTemplate")
  crafterScrollFrame:SetPoint("TOPLEFT", crafterHeaderName, "BOTTOMLEFT", -4, -4)
  crafterScrollFrame:SetPoint("BOTTOMRIGHT", detailContainer, "BOTTOMRIGHT", -26, 8)

  local crafterScrollChild = CreateFrame("Frame", nil, crafterScrollFrame)
  crafterScrollChild:SetSize(280, 120)
  crafterScrollFrame:SetScrollChild(crafterScrollChild)

  local crafterRows = {}
  local crafterRowHeight = 24
  for i = 1, 10 do
    local row = CreateFrame("Frame", nil, crafterScrollChild)
    row:SetHeight(crafterRowHeight)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * crafterRowHeight)
    row:SetPoint("RIGHT", crafterScrollChild, "RIGHT", 0, 0)

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameText:SetPoint("LEFT", columnNameX, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWidth(nameColumnWidth)

    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusText:SetPoint("LEFT", row, "LEFT", columnStatusX, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWidth(statusColumnWidth)

    local matsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    matsText:SetPoint("LEFT", row, "LEFT", columnMatsX, 0)
    matsText:SetJustifyH("LEFT")
    matsText:SetWidth(matsColumnWidth)

    local requestButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    requestButton:SetPoint("LEFT", row, "LEFT", ColumnActionsX, 0)
    requestButton:SetSize(requestButtonWidth, 26)
    requestButton:SetText(T("Request"))
    requestButton:SetScript("OnClick", function()
      if row.recipeSpellID then
        SND:PromptNewRequest(row.recipeSpellID, {
          itemLink = row.itemLink,
          itemText = row.itemText,
          crafterName = row.crafterName,
          crafterProfession = row.crafterProfession,
          crafterOnline = row.crafterOnline,
          crafterHasSharedMats = row.crafterHasSharedMats,
        })
      end
    end)

    --local whisperButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    --whisperButton:SetPoint("RIGHT", requestButton, "LEFT", -actionButtonGap, 0)
    --whisperButton:SetSize(whisperButtonWidth, 20)
    --whisperButton:SetText(T("Whisper"))
    --whisperButton:SetScript("OnClick", function()
      --if row.crafterName then
        --SND:WhisperPlayer(row.crafterName)
      --end
    --end)

    row.nameText = nameText
    row.statusText = statusText
    row.matsText = matsText
    row.requestButton = requestButton
    --row.whisperButton = whisperButton
    row:Hide()
    crafterRows[i] = row
  end

  local crafterEmptyLabel = crafterScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  crafterEmptyLabel:SetPoint("TOPLEFT", 4, -4)
  crafterEmptyLabel:SetText(T("No crafters found."))
  crafterEmptyLabel:Hide()

  local itemPreviewHeader = rightContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  itemPreviewHeader:SetPoint("TOPLEFT", 8, -8)
  itemPreviewHeader:SetText(T("Item Details"))

  local itemPreviewButton = CreateFrame("Button", nil, rightContainer)
  itemPreviewButton:SetPoint("TOPLEFT", itemPreviewHeader, "BOTTOMLEFT", 0, -6)
  itemPreviewButton:SetPoint("TOPRIGHT", -8, -30)
  itemPreviewButton:SetHeight(40)
  itemPreviewButton:SetScript("OnEnter", function(btn)
    local link = btn.outputLink
    if not link and btn.recipeSpellID then
      link = SND:GetRecipeOutputItemLink(btn.recipeSpellID)
    end
    if link then
      GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(link)
      GameTooltip:Show()
    end
  end)
  itemPreviewButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  local itemPreviewIcon = itemPreviewButton:CreateTexture(nil, "ARTWORK")
  itemPreviewIcon:SetSize(32, 32)
  itemPreviewIcon:SetPoint("LEFT", 0, 0)

  local itemPreviewTitle = itemPreviewButton:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  itemPreviewTitle:SetPoint("LEFT", itemPreviewIcon, "RIGHT", 8, 0)
  itemPreviewTitle:SetPoint("RIGHT", -4, 0)
  itemPreviewTitle:SetJustifyH("LEFT")
  itemPreviewTitle:SetText(T("Select an item"))

  local itemPreviewMeta = rightContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  itemPreviewMeta:SetPoint("TOPLEFT", itemPreviewButton, "BOTTOMLEFT", 0, -8)
  itemPreviewMeta:SetPoint("RIGHT", rightContainer, "RIGHT", -8, 0)
  itemPreviewMeta:SetJustifyH("LEFT")

  local itemPreviewCrafter = rightContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  itemPreviewCrafter:SetPoint("TOPLEFT", itemPreviewMeta, "BOTTOMLEFT", 0, -8)
  itemPreviewCrafter:SetPoint("RIGHT", rightContainer, "RIGHT", -8, 0)
  itemPreviewCrafter:SetJustifyH("LEFT")

  local matsHeader = rightContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  matsHeader:SetPoint("TOPLEFT", itemPreviewCrafter, "BOTTOMLEFT", 0, -10)
  matsHeader:SetText(T("Required Materials"))

  local matsScrollFrame = CreateFrame("ScrollFrame", nil, rightContainer, "UIPanelScrollFrameTemplate")
  matsScrollFrame:SetPoint("TOPLEFT", matsHeader, "BOTTOMLEFT", 0, -6)
  matsScrollFrame:SetPoint("BOTTOMRIGHT", rightContainer, "BOTTOMRIGHT", -26, 8)

  local matsScrollChild = CreateFrame("Frame", nil, matsScrollFrame)
  matsScrollChild:SetSize(230, 220)
  matsScrollFrame:SetScrollChild(matsScrollChild)

  local itemPreviewMats = matsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  itemPreviewMats:SetPoint("TOPLEFT", 0, 0)
  itemPreviewMats:SetPoint("RIGHT", matsScrollChild, "RIGHT", -4, 0)
  itemPreviewMats:SetJustifyH("LEFT")
  itemPreviewMats:SetJustifyV("TOP")
  itemPreviewMats:SetWordWrap(true)

  local listButtons = {}
  local listRowHeight = 48
  local function createDirectoryRow(index)
    local row = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
    row:SetSize(252, 44)
    if index == 1 then
      row:SetPoint("TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", listButtons[index - 1], "BOTTOMLEFT", 0, -2)
    end

    row:SetBackdrop({
      bgFile = "Interface/Buttons/WHITE8x8",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      edgeSize = 8,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    row:SetBackdropColor(0, 0, 0, 1)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("LEFT", 6, 0)
    row.icon = icon

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
    label:SetPoint("RIGHT", -8, 0)
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetWordWrap(true)
    row.label = label

    row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
    local highlight = row:GetHighlightTexture()
    if highlight then
      highlight:SetAllPoints(row)
      highlight:SetBlendMode("ADD")
    end

    row:SetScript("OnClick", function(btn)
      SND:SelectDirectoryRecipe(frame, btn.recipeSpellID)
      for _, other in ipairs(listButtons) do
        if other then
          other:UnlockHighlight()
          if other.SetBackdropColor then
            other:SetBackdropColor(0, 0, 0, 1)
          end
        end
      end
      btn:LockHighlight()
      if btn.SetBackdropColor then
        btn:SetBackdropColor(0.35, 0.25, 0.1, 1)
      end
    end)
    row:SetScript("OnEnter", function(btn)
      if btn.recipeSpellID then
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        if btn.outputLink then
          GameTooltip:SetHyperlink(btn.outputLink)
        else
          GameTooltip:SetText(btn.displayItemText or (btn.label and btn.label:GetText() or ""))
        end
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    row:Hide()
    listButtons[index] = row
    return row
  end

  -- Create more rows to support scrolling (100 max visible results)
  for i = 1, 100 do
    createDirectoryRow(i)
  end

  scrollChild:SetHeight(#listButtons * listRowHeight)

  frame.searchBox = searchBox
  frame.listButtons = listButtons
  frame.listScrollFrame = scrollFrame
  frame.listScrollChild = scrollChild
  frame.listRowHeight = listRowHeight
  frame.createDirectoryRow = createDirectoryRow
  frame.detailTitle = detailTitleText
  frame.detailTitleButton = detailTitle
  frame.detailSummaryText = detailSummaryText
  frame.sharedMatsSummary = sharedMatsSummary
  frame.crafterRows = crafterRows
  frame.crafterScrollChild = crafterScrollChild
  frame.crafterRowHeight = crafterRowHeight
  frame.crafterEmptyLabel = crafterEmptyLabel
  frame.itemPreviewButton = itemPreviewButton
  frame.itemPreviewTitle = itemPreviewTitle
  frame.itemPreviewIcon = itemPreviewIcon
  frame.itemPreviewMeta = itemPreviewMeta
  frame.itemPreviewCrafter = itemPreviewCrafter
  frame.itemPreviewMats = itemPreviewMats
  frame.itemPreviewMatsScrollChild = matsScrollChild
  frame.selectedProfession = "All"
  frame.onlineOnly = false
  frame.sharedMatsOnly = false
  frame.hideOwnRecipes = false
  frame.sortBy = "name_az"

  UIDropDownMenu_Initialize(professionDrop, function(dropdown, level)
    local options = SND:GetProfessionFilterOptions()
    for _, option in ipairs(options) do
      local value = option
      local info = UIDropDownMenu_CreateInfo()
      info.text = value
      info.checked = value == frame.selectedProfession
      info.func = function()
        frame.selectedProfession = value
        UIDropDownMenu_SetText(professionDrop, value)
        SND:UpdateDirectoryResults(searchBox:GetText())
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(professionDrop, 110)
  UIDropDownMenu_SetText(professionDrop, frame.selectedProfession)

  return frame
end

function SND:EnsureDirectoryRowCapacity(directoryFrame, requiredCount)
  if not directoryFrame or not directoryFrame.listButtons or type(directoryFrame.createDirectoryRow) ~= "function" then
    return
  end

  local target = tonumber(requiredCount) or 0
  local pageSize = tonumber(directoryFrame.directoryPageSize)
  if pageSize and pageSize > 0 then
    target = pageSize
  end
  if target < 0 then
    target = 0
  end

  while #directoryFrame.listButtons < target do
    directoryFrame.createDirectoryRow(#directoryFrame.listButtons + 1)
  end

  if directoryFrame.listScrollChild and directoryFrame.listRowHeight then
    directoryFrame.listScrollChild:SetHeight(#directoryFrame.listButtons * directoryFrame.listRowHeight)
  end
end

function SND:CreateRequestsTab(parent)
  local frame = self:CreateContentFrame(parent)

  local filterBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  filterBar:SetPoint("TOPLEFT", 8, -12)
  filterBar:SetPoint("TOPRIGHT", -8, -12)
  filterBar:SetHeight(112)
  filterBar:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  filterBar:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local searchBox = CreateFrame("EditBox", nil, filterBar, "InputBoxTemplate")
  searchBox:SetSize(180, 28)
  searchBox:SetPoint("TOPLEFT", 14, -22)
  searchBox:SetAutoFocus(false)
  searchBox:SetScript("OnEnterPressed", function(edit)
    edit:ClearFocus()
    frame.searchQuery = edit:GetText() or ""
    SND:RefreshRequestList(frame)
  end)
  searchBox:SetScript("OnTextChanged", function(edit)
    SND:Debounce("requests_search", 0.2, function()
      frame.searchQuery = edit:GetText() or ""
      SND:RefreshRequestList(frame)
    end)
  end)
  searchBox:SetScript("OnEscapePressed", function(edit)
    edit:ClearFocus()
  end)

  local searchLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  searchLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 0, 4)
  searchLabel:SetText("Search")

  local professionLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  professionLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPRIGHT", 12, 4)
  professionLabel:SetText("Profession")

  local professionDrop = CreateFrame("Frame", "SNDRequestProfessionDropDown", filterBar, "UIDropDownMenuTemplate")
  professionDrop:SetPoint("TOPLEFT", searchBox, "TOPRIGHT", 8, 2)

  local statusLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusLabel:SetPoint("BOTTOMLEFT", professionDrop, "TOPRIGHT", 8, 2)
  statusLabel:SetText("Status")

  local statusDrop = CreateFrame("Frame", "SNDRequestStatusDropDown", filterBar, "UIDropDownMenuTemplate")
  statusDrop:SetPoint("TOPLEFT", professionDrop, "TOPRIGHT", 12, 0)

  local onlyMineBox, onlyMine = CreateBoundedCheckbox(filterBar, T("Online Only"))
  onlyMineBox:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -12)
  onlyMine:SetScript("OnClick", function(btn)
    frame.onlyMine = btn:GetChecked() and true or false
    SND:RefreshRequestList(frame)
  end)

  local onlyClaimableBox, onlyClaimable = CreateBoundedCheckbox(filterBar, "Unclaimed Only")
  onlyClaimableBox:SetPoint("LEFT", onlyMineBox, "RIGHT", 8, 0)
  onlyClaimable:SetScript("OnClick", function(btn)
    frame.onlyClaimable = btn:GetChecked() and true or false
    SND:RefreshRequestList(frame)
  end)

  local hasMatsBox, hasMatsCheck = CreateBoundedCheckbox(filterBar, "Has Materials")
  hasMatsBox:SetPoint("LEFT", onlyClaimableBox, "RIGHT", 8, 0)
  hasMatsCheck:SetScript("OnClick", function(btn)
    frame.hasMaterialsOnly = btn:GetChecked() and true or false
    SND:RefreshRequestList(frame)
  end)

  local columnGap = 10
  local listContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  listContainer:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -8)
  listContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 12)
  -- Use relative positioning: ~40% of parent width (min 720px * 0.40 = 288px)
  listContainer:SetPoint("RIGHT", frame, "LEFT", 296, 0)
  listContainer:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  listContainer:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local listHeader = listContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  listHeader:SetPoint("TOPLEFT", 8, -8)
  listHeader:SetText("Requestor")

  local itemHeader = listContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  itemHeader:SetPoint("TOPLEFT", listHeader, "TOPLEFT", 168, 0)
  itemHeader:SetText("Item")

  local statusHeaderText = listContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusHeaderText:SetPoint("TOPLEFT", itemHeader, "TOPLEFT", 186, 0)
  statusHeaderText:SetText("Status")

  local pageBar = CreateFrame("Frame", nil, listContainer)
  pageBar:SetPoint("BOTTOMLEFT", 8, 6)
  pageBar:SetPoint("BOTTOMRIGHT", -8, 6)
  pageBar:SetHeight(24)

  local prevPage = CreateFrame("Button", nil, pageBar, "UIPanelButtonTemplate")
  prevPage:SetPoint("LEFT", 0, 0)
  prevPage:SetSize(30, 20)
  prevPage:SetText("<")

  local nextPage = CreateFrame("Button", nil, pageBar, "UIPanelButtonTemplate")
  nextPage:SetPoint("LEFT", prevPage, "RIGHT", 6, 0)
  nextPage:SetSize(30, 20)
  nextPage:SetText(">")

  local pageLabel = pageBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  pageLabel:SetPoint("LEFT", nextPage, "RIGHT", 12, 0)
  pageLabel:SetText("1 / 1")

  prevPage:SetScript("OnClick", function()
    local page = tonumber(frame.currentPage) or 1
    if page > 1 then
      frame.currentPage = page - 1
      SND:RefreshRequestList(frame)
    end
  end)

  nextPage:SetScript("OnClick", function()
    local page = tonumber(frame.currentPage) or 1
    frame.currentPage = page + 1
    SND:RefreshRequestList(frame)
  end)

  local scrollFrame = CreateFrame("ScrollFrame", "SNDRequestsScrollFrame", listContainer, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", 4, -28)
  scrollFrame:SetPoint("BOTTOMRIGHT", pageBar, "TOPRIGHT", -18, 4)

  local scrollChild = CreateFrame("Frame", nil, scrollFrame)
  scrollChild:SetSize(530, 240)
  scrollFrame:SetScrollChild(scrollChild)

  local detailContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  detailContainer:SetPoint("TOPLEFT", listContainer, "TOPRIGHT", columnGap, 0)
  detailContainer:SetPoint("BOTTOMRIGHT", -8, 12)
  detailContainer:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  detailContainer:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local detailTitle = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detailTitle:SetPoint("TOPLEFT", 8, -8)
  detailTitle:SetText("Unclaimed Request")

  local detailRequester = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detailRequester:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -8)
  detailRequester:SetText("")

  local detailItemHeader = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  detailItemHeader:SetPoint("TOPLEFT", detailRequester, "BOTTOMLEFT", 0, -8)
  detailItemHeader:SetText(T("Item Details"))

  local detailItemButton = CreateFrame("Button", nil, detailContainer)
  detailItemButton:SetPoint("TOPLEFT", detailItemHeader, "BOTTOMLEFT", 0, -4)
  detailItemButton:SetPoint("TOPRIGHT", detailContainer, "TOPRIGHT", -8, -56)
  detailItemButton:SetHeight(40)
  detailItemButton:SetScript("OnEnter", function(btn)
    local link = btn.itemLink
    if not link and btn.recipeSpellID then
      link = SND:GetRecipeOutputItemLink(btn.recipeSpellID)
    end
    if link then
      GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(link)
      GameTooltip:Show()
    end
  end)
  detailItemButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  local detailItemIcon = detailItemButton:CreateTexture(nil, "ARTWORK")
  detailItemIcon:SetSize(32, 32)
  detailItemIcon:SetPoint("LEFT", 0, 0)
  detailItemIcon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")

  local detailItemTitle = detailItemButton:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  detailItemTitle:SetPoint("LEFT", detailItemIcon, "RIGHT", 8, 0)
  detailItemTitle:SetPoint("RIGHT", detailItemButton, "RIGHT", -4, 0)
  detailItemTitle:SetJustifyH("LEFT")
  detailItemTitle:SetText("-")

  local detailInfo = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detailInfo:SetPoint("TOPLEFT", detailItemButton, "BOTTOMLEFT", 0, -6)
  detailInfo:SetJustifyH("LEFT")
  detailInfo:Hide()

  local notesTitle = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  notesTitle:SetPoint("TOPLEFT", detailInfo, "BOTTOMLEFT", 0, -8)
  notesTitle:SetText("Notes")

  local notesBox = CreateFrame("EditBox", nil, detailContainer, "InputBoxTemplate")
  notesBox:SetPoint("TOPLEFT", notesTitle, "BOTTOMLEFT", 0, -4)
  notesBox:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  notesBox:SetHeight(54)
  notesBox:SetMultiLine(true)
  notesBox:SetAutoFocus(false)

  local statusLine = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusLine:SetPoint("TOPLEFT", notesBox, "BOTTOMLEFT", 0, -8)
  statusLine:SetText("Status: -")

  local workflowStatus = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  workflowStatus:SetPoint("TOPLEFT", statusLine, "BOTTOMLEFT", 0, -4)
  workflowStatus:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  workflowStatus:SetJustifyH("LEFT")
  workflowStatus:SetJustifyV("TOP")
  workflowStatus:SetWordWrap(true)
  workflowStatus:SetText("")

  local materialsTitle = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  materialsTitle:SetPoint("TOPLEFT", workflowStatus, "BOTTOMLEFT", 0, -8)
  materialsTitle:SetText("Materials Supplied")

  local materialsScroll = CreateFrame("ScrollFrame", nil, detailContainer, "UIPanelScrollFrameTemplate")
  materialsScroll:SetPoint("TOPLEFT", materialsTitle, "BOTTOMLEFT", 0, -4)
  materialsScroll:SetPoint("RIGHT", detailContainer, "RIGHT", -26, 0)

  local materialsChild = CreateFrame("Frame", nil, materialsScroll)
  materialsChild:SetSize(300, 150)
  materialsScroll:SetScrollChild(materialsChild)

  local materialsList = materialsChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  materialsList:SetPoint("TOPLEFT", 0, 0)
  materialsList:SetPoint("RIGHT", materialsChild, "RIGHT", -4, 0)
  materialsList:SetJustifyH("LEFT")
  materialsList:SetJustifyV("TOP")
  materialsList:SetWordWrap(true)

  local actionBarMetaBottom = CreateFrame("Frame", nil, detailContainer)
  actionBarMetaBottom:SetPoint("BOTTOMLEFT", detailContainer, "BOTTOMLEFT", 8, 8)
  actionBarMetaBottom:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  actionBarMetaBottom:SetHeight(26)

  local actionBarMeta = CreateFrame("Frame", nil, detailContainer)
  actionBarMeta:SetPoint("BOTTOMLEFT", actionBarMetaBottom, "TOPLEFT", 0, 6)
  actionBarMeta:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  actionBarMeta:SetHeight(26)

  local actionBarBottom = CreateFrame("Frame", nil, detailContainer)
  actionBarBottom:SetPoint("BOTTOMLEFT", actionBarMeta, "TOPLEFT", 0, 6)
  actionBarBottom:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  actionBarBottom:SetHeight(26)

  local actionBarTop = CreateFrame("Frame", nil, detailContainer)
  actionBarTop:SetPoint("BOTTOMLEFT", actionBarBottom, "TOPLEFT", 0, 6)
  actionBarTop:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  actionBarTop:SetHeight(26)

  materialsScroll:SetPoint("BOTTOMRIGHT", actionBarTop, "TOPRIGHT", -18, 10)

  local claimButton = CreateFrame("Button", nil, actionBarTop, "UIPanelButtonTemplate")
  claimButton:SetPoint("LEFT", 0, 0)
  claimButton:SetSize(110, 24)
  claimButton:SetText("Claim")
  claimButton:SetScript("OnClick", function()
    SND:ClaimSelectedRequest(frame)
  end)

  local unclaimButton = CreateFrame("Button", nil, actionBarTop, "UIPanelButtonTemplate")
  unclaimButton:SetPoint("LEFT", claimButton, "RIGHT", 6, 0)
  unclaimButton:SetSize(110, 24)
  unclaimButton:SetText("Unclaim")
  unclaimButton:SetScript("OnClick", function()
    SND:UnclaimSelectedRequest(frame)
  end)

  local craftedButton = CreateFrame("Button", nil, actionBarBottom, "UIPanelButtonTemplate")
  craftedButton:SetPoint("LEFT", 0, 0)
  craftedButton:SetSize(110, 24)
  craftedButton:SetText("Fulfill")
  craftedButton:SetScript("OnClick", function()
    SND:MarkSelectedRequestCrafted(frame)
  end)

  local deliveredButton = CreateFrame("Button", nil, actionBarBottom, "UIPanelButtonTemplate")
  deliveredButton:SetPoint("LEFT", craftedButton, "RIGHT", 6, 0)
  deliveredButton:SetSize(110, 24)
  deliveredButton:SetText("Deliver")
  deliveredButton:SetScript("OnClick", function()
    SND:MarkSelectedRequestDelivered(frame)
  end)

  local editButton = CreateFrame("Button", nil, actionBarMeta, "UIPanelButtonTemplate")
  editButton:SetPoint("LEFT", 0, 0)
  editButton:SetSize(70, 24)
  editButton:SetText("Edit")
  editButton:SetScript("OnClick", function()
    SND:EditSelectedRequestNotes(frame)
  end)

  local cancelButton = CreateFrame("Button", nil, actionBarMeta, "UIPanelButtonTemplate")
  cancelButton:SetPoint("LEFT", editButton, "RIGHT", 6, 0)
  cancelButton:SetSize(82, 24)
  cancelButton:SetText("Decline")
  cancelButton:SetScript("OnClick", function()
    SND:CancelSelectedRequest(frame)
  end)

  local deleteButton = CreateFrame("Button", nil, actionBarMeta, "UIPanelButtonTemplate")
  deleteButton:SetPoint("LEFT", cancelButton, "RIGHT", 6, 0)
  deleteButton:SetSize(84, 24)
  deleteButton:SetText("Remove")
  deleteButton:SetScript("OnClick", function()
    SND:DeleteSelectedRequest(frame)
  end)

  local saveNotesButton = CreateFrame("Button", nil, actionBarMetaBottom, "UIPanelButtonTemplate")
  saveNotesButton:SetPoint("LEFT", 0, 0)
  saveNotesButton:SetSize(110, 24)
  saveNotesButton:SetText("Save")
  saveNotesButton:SetScript("OnClick", function()
    SND:SaveInlineNotes(frame)
  end)

  local listButtons = {}
  local requestRowHeight = 54
  local iconSize = 38
  local requestorColumnX = 48
  local itemColumnX = 170
  local statusColumnX = 356
  for i = 1, 10 do
    local row = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
    row:SetHeight(requestRowHeight)
    if i == 1 then
      row:SetPoint("TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", listButtons[i - 1], "BOTTOMLEFT", 0, -2)
    end
    row:SetPoint("RIGHT", scrollChild, "RIGHT", -2, 0)

    row:SetBackdrop({
      bgFile = "Interface/Buttons/WHITE8x8",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      edgeSize = 8,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    row:SetBackdropColor(0, 0, 0, 1)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT", 6, 0)

    local requesterText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    requesterText:SetPoint("LEFT", row, "LEFT", requestorColumnX, 0)
    requesterText:SetWidth(112)
    requesterText:SetJustifyH("LEFT")

    local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemText:SetPoint("LEFT", row, "LEFT", itemColumnX, 0)
    itemText:SetWidth(178)
    itemText:SetJustifyH("LEFT")

    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("LEFT", row, "LEFT", statusColumnX, 0)
    statusText:SetWidth(74)
    statusText:SetJustifyH("LEFT")

    local quickClaimButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    quickClaimButton:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    quickClaimButton:SetSize(86, 22)
    quickClaimButton:SetText("Claim")
    quickClaimButton:SetScript("OnClick", function(btn)
      local parentRow = btn:GetParent()
      if parentRow and parentRow.requestId then
        SND:SelectRequest(frame, parentRow.requestId)
        SND:ClaimSelectedRequest(frame)
      end
    end)

    row.icon = icon
    row.requesterText = requesterText
    row.itemText = itemText
    row.statusText = statusText
    row.quickClaimButton = quickClaimButton

    row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
    local highlight = row:GetHighlightTexture()
    if highlight then
      highlight:SetAllPoints(row)
      highlight:SetBlendMode("ADD")
    end

    row:SetScript("OnClick", function(btn)
      SND:SelectRequest(frame, btn.requestId)
      for _, other in ipairs(listButtons) do
        if other then
          other:UnlockHighlight()
          if other.SetBackdropColor then
            other:SetBackdropColor(0, 0, 0, 1)
          end
        end
      end
      btn:LockHighlight()
      if btn.SetBackdropColor then
        btn:SetBackdropColor(0.35, 0.25, 0.1, 1)
      end
    end)
    row:SetScript("OnEnter", function(btn)
      if btn.requestId then
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetText(btn.itemText and btn.itemText:GetText() or "")
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    row:Hide()
    listButtons[i] = row
  end

  scrollChild:SetHeight(10 * (requestRowHeight + 2))

  frame.searchBox = searchBox
  frame.listScrollFrame = scrollFrame
  frame.listButtons = listButtons
  frame.requestRowHeight = requestRowHeight
  frame.pageSize = #listButtons
  frame.currentPage = 1
  frame.prevPageButton = prevPage
  frame.nextPageButton = nextPage
  frame.pageLabel = pageLabel
  frame.detailTitle = detailTitle
  frame.detailRequester = detailRequester
  frame.detailItemButton = detailItemButton
  frame.detailItemTitle = detailItemTitle
  frame.detailItemIcon = detailItemIcon
  frame.statusLine = statusLine
  frame.workflowStatus = workflowStatus
  frame.detailInfo = detailInfo
  frame.materialsList = materialsList
  frame.materialsScrollChild = materialsChild
  frame.notesBox = notesBox
  frame.claimButton = claimButton
  frame.unclaimButton = unclaimButton
  frame.craftedButton = craftedButton
  frame.deliveredButton = deliveredButton
  frame.editButton = editButton
  frame.cancelButton = cancelButton
  frame.deleteButton = deleteButton
  frame.saveNotesButton = saveNotesButton
  frame.selectedRequestId = nil
  frame.searchQuery = ""
  frame.professionFilter = "All"
  frame.statusFilter = "ALL"
  frame.onlyMine = false
  frame.onlyClaimable = false
  frame.hasMaterialsOnly = false

  UIDropDownMenu_Initialize(professionDrop, function(dropdown, level)
    local options = SND:GetProfessionFilterOptions()
    for _, option in ipairs(options or {}) do
      local value = option
      local info = UIDropDownMenu_CreateInfo()
      info.text = value
      info.checked = value == frame.professionFilter
      info.func = function()
        frame.professionFilter = value
        UIDropDownMenu_SetText(professionDrop, value)
        SND:RefreshRequestList(frame)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(professionDrop, 130)
  UIDropDownMenu_SetText(professionDrop, frame.professionFilter)

  UIDropDownMenu_Initialize(statusDrop, function(dropdown, level)
    local options = { "ALL", "OPEN", "CLAIMED", "CRAFTED", "DELIVERED", "CANCELLED" }
    for _, option in ipairs(options) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = option
      info.checked = option == frame.statusFilter
      info.func = function()
        frame.statusFilter = option
        UIDropDownMenu_SetText(statusDrop, option)
        SND:RefreshRequestList(frame)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(statusDrop, 120)
  UIDropDownMenu_SetText(statusDrop, frame.statusFilter)

  return frame
end

function SND:CreateMeTab(parent)
  local frame = self:CreateContentFrame(parent)
  self.meTabFrame = frame

  local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  label:SetPoint("TOPLEFT", 8, -18)
  label:SetText("Options")

  local leftColumn = CreateFrame("Frame", nil, frame)
  leftColumn:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
  leftColumn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 12)
  -- Use relative positioning: ~30% of parent width (min 720px * 0.30 = 216px)
  leftColumn:SetPoint("RIGHT", frame, "LEFT", 224, 0)

  local rightColumn = CreateFrame("Frame", nil, frame)
  rightColumn:SetPoint("TOPLEFT", leftColumn, "TOPRIGHT", 24, 0)
  rightColumn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 12)
  rightColumn:SetPoint("RIGHT", frame, "RIGHT", -8, 0)

  local statusHeader = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusHeader:SetPoint("TOPLEFT", 0, -4)
  statusHeader:SetText("Status")

  local scanStatus = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  scanStatus:SetPoint("TOPLEFT", statusHeader, "BOTTOMLEFT", 0, -6)
  scanStatus:SetText("Last scan: -")

  local professionsList = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  professionsList:SetPoint("TOPLEFT", scanStatus, "BOTTOMLEFT", 0, -4)
  professionsList:SetJustifyH("LEFT")
  professionsList:SetText("Professions: -")

  local publishHeader = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  publishHeader:SetPoint("TOPLEFT", professionsList, "BOTTOMLEFT", 0, -12)
  publishHeader:SetText("Publish")

  local publishButton = CreateFrame("Button", nil, leftColumn, "UIPanelButtonTemplate")
  publishButton:SetPoint("TOPLEFT", publishHeader, "BOTTOMLEFT", 0, -6)
  publishButton:SetSize(120, 24)
  publishButton:SetText("Publish")
  publishButton:SetScript("OnClick", function()
    SND:DebugPrint("Scanner: publish requested from UI.")
    SND:SendProfSummary()
    SND:SendRecipeIndex()
  end)

  local autoPublishLogin = CreateFrame("CheckButton", nil, leftColumn, "UICheckButtonTemplate")
  autoPublishLogin:SetPoint("TOPLEFT", publishButton, "BOTTOMLEFT", 0, -6)
  autoPublishLogin.text:SetText("Auto publish on login")
  autoPublishLogin:SetChecked(SND.db.config.autoPublishOnLogin)
  autoPublishLogin:SetScript("OnClick", function(btn)
    SND.db.config.autoPublishOnLogin = btn:GetChecked() and true or false
  end)

  local autoPublishLearn = CreateFrame("CheckButton", nil, leftColumn, "UICheckButtonTemplate")
  autoPublishLearn:SetPoint("TOPLEFT", autoPublishLogin, "BOTTOMLEFT", 0, -2)
  autoPublishLearn.text:SetText("Auto publish on learn")
  autoPublishLearn:SetChecked(SND.db.config.autoPublishOnLearn)
  autoPublishLearn:SetScript("OnClick", function(btn)
    SND.db.config.autoPublishOnLearn = btn:GetChecked() and true or false
  end)

  local minimapToggle = CreateFrame("CheckButton", nil, leftColumn, "UICheckButtonTemplate")
  minimapToggle:SetPoint("TOPLEFT", autoPublishLearn, "BOTTOMLEFT", 0, -2)
  minimapToggle.text:SetText("Show minimap button")
  minimapToggle:SetChecked(SND.db.config.showMinimapButton)
  minimapToggle:SetScript("OnClick", function(btn)
    SND.db.config.showMinimapButton = btn:GetChecked() and true or false
    SND:UpdateMinimapButtonVisibility()
  end)

  local scanLogCopyModal = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  scanLogCopyModal:SetSize(540, 280)
  scanLogCopyModal:SetPoint("CENTER", frame, "CENTER", 0, 0)
  scanLogCopyModal:SetFrameStrata(SND_MODAL_STRATA)
  scanLogCopyModal:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  scanLogCopyModal:SetBackdropColor(0.08, 0.08, 0.1, 1)
  scanLogCopyModal:EnableMouse(true)
  scanLogCopyModal:SetScript("OnShow", function(modalFrame)
    SND:BringAddonFrameToFront(modalFrame, SND_MODAL_STRATA)
  end)
  scanLogCopyModal:SetScript("OnMouseDown", function(modalFrame)
    SND:BringAddonFrameToFront(modalFrame, SND_MODAL_STRATA)
  end)
  scanLogCopyModal:Hide()

  local scanLogCopyTitle = scanLogCopyModal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  scanLogCopyTitle:SetPoint("TOPLEFT", 10, -10)
  scanLogCopyTitle:SetText("Copy Scan Logs")

  local scanLogCopyHint = scanLogCopyModal:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  scanLogCopyHint:SetPoint("TOPLEFT", scanLogCopyTitle, "BOTTOMLEFT", 0, -4)
  scanLogCopyHint:SetText("Press Ctrl+C after auto-select.")

  local closeCopyModal = CreateFrame("Button", nil, scanLogCopyModal, "UIPanelCloseButton")
  closeCopyModal:SetPoint("TOPRIGHT", -2, -2)
  closeCopyModal:SetScript("OnClick", function()
    SND:CloseScanLogCopyBox()
  end)

  local scanLogCopyScroll = CreateFrame("ScrollFrame", nil, scanLogCopyModal, "UIPanelScrollFrameTemplate")
  scanLogCopyScroll:SetPoint("TOPLEFT", 10, -42)
  scanLogCopyScroll:SetPoint("BOTTOMRIGHT", -30, 10)

  local scanLogCopyEditBox = CreateFrame("EditBox", nil, scanLogCopyScroll)
  scanLogCopyEditBox:SetMultiLine(true)
  scanLogCopyEditBox:SetAutoFocus(false)
  scanLogCopyEditBox:SetFontObject(ChatFontNormal)
  scanLogCopyEditBox:SetWidth(486)
  scanLogCopyEditBox:SetHeight(220)
  scanLogCopyEditBox:SetTextInsets(4, 4, 4, 4)
  scanLogCopyEditBox:SetScript("OnEscapePressed", function(edit)
    edit:ClearFocus()
    SND:CloseScanLogCopyBox()
  end)
  scanLogCopyEditBox:SetScript("OnTextChanged", function(edit)
    local height = math.max(220, math.floor((edit:GetStringHeight() or 0) + 24))
    edit:SetHeight(height)
  end)
  scanLogCopyScroll:SetScrollChild(scanLogCopyEditBox)

  local scanAlertLabel = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  scanAlertLabel:SetPoint("TOPLEFT", scanStatus, "BOTTOMLEFT", 0, -6)
  scanAlertLabel:SetTextColor(1, 0.3, 0.3)
  scanAlertLabel:SetText("")
  scanAlertLabel:Hide()

  professionsList:SetPoint("TOPLEFT", scanAlertLabel, "BOTTOMLEFT", 0, -4)

  local sharingHeader = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sharingHeader:SetPoint("TOPLEFT", 0, -4)
  sharingHeader:SetText("Sharing")

  local shareMatsToggle = CreateFrame("CheckButton", nil, rightColumn, "UICheckButtonTemplate")
  shareMatsToggle:SetPoint("TOPLEFT", sharingHeader, "BOTTOMLEFT", 0, -6)
  shareMatsToggle.text:SetText("Share mats (opt-in)")
  shareMatsToggle:SetChecked(SND.db.config.shareMatsOptIn)
  shareMatsToggle:SetScript("OnClick", function(btn)
    SND.db.config.shareMatsOptIn = btn:GetChecked() and true or false
    SND:PublishSharedMats()
    SND:RefreshMeTab(frame)
  end)

  local autoShareToggle = CreateFrame("CheckButton", nil, rightColumn, "UICheckButtonTemplate")
  autoShareToggle:SetPoint("TOPLEFT", shareMatsToggle, "BOTTOMLEFT", 0, -2)
  autoShareToggle.text:SetText("Auto publish mats")
  autoShareToggle:SetChecked(SND.db.config.autoPublishMats)
  autoShareToggle:SetScript("OnClick", function(btn)
    SND.db.config.autoPublishMats = btn:GetChecked() and true or false
  end)

  local matsPublishButton = CreateFrame("Button", nil, rightColumn, "UIPanelButtonTemplate")
  matsPublishButton:SetPoint("TOPLEFT", autoShareToggle, "BOTTOMLEFT", 0, -6)
  matsPublishButton:SetSize(160, 24)
  matsPublishButton:SetText("Publish Mats")
  matsPublishButton:SetScript("OnClick", function()
    SND:PublishSharedMats()
    SND:RefreshMeTab(frame)
  end)

  local matsStatus = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  matsStatus:SetPoint("TOPLEFT", matsPublishButton, "BOTTOMLEFT", 0, -6)
  matsStatus:SetText("Mats publish: -")

  local matsSummary = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  matsSummary:SetPoint("TOPLEFT", matsStatus, "BOTTOMLEFT", 0, -4)
  matsSummary:SetJustifyH("LEFT")
  matsSummary:SetText(T("Shared mats contributors: -"))

  local matsListHeader = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  matsListHeader:SetPoint("TOPLEFT", matsSummary, "BOTTOMLEFT", 0, -12)
  matsListHeader:SetText("Shared mats")

  local matsSearchBox = CreateFrame("EditBox", nil, rightColumn, "InputBoxTemplate")
  matsSearchBox:SetSize(200, 22)
  matsSearchBox:SetPoint("TOPLEFT", matsListHeader, "BOTTOMLEFT", 0, -6)
  matsSearchBox:SetAutoFocus(false)
  matsSearchBox:SetScript("OnEnterPressed", function(edit)
    edit:ClearFocus()
    SND:RefreshSharedMatsList(frame)
  end)
  matsSearchBox:SetScript("OnTextChanged", function(edit)
    SND:Debounce("me_mats_search", 0.2, function()
      if frame.sharedMatsSearchBox == edit then
        SND:RefreshSharedMatsList(frame)
      end
    end)
  end)
  matsSearchBox:SetScript("OnEscapePressed", function(edit)
    edit:ClearFocus()
  end)

  local listContainer = CreateFrame("Frame", nil, rightColumn, "BackdropTemplate")
  listContainer:SetPoint("TOPLEFT", matsSearchBox, "BOTTOMLEFT", 0, -6)
  listContainer:SetSize(300, 220)
  listContainer:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  listContainer:SetBackdropColor(0.05, 0.05, 0.08, 1)

  local shareColumnX = 8
  local itemColumnX = 36
  local qtyColumnRightX = -12

  local listHeaderShare = listContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  listHeaderShare:SetPoint("TOPLEFT", shareColumnX, -8)
  listHeaderShare:SetText("?")

  local listHeaderName = listContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  listHeaderName:SetPoint("TOPLEFT", itemColumnX, -8)
  listHeaderName:SetPoint("TOPRIGHT", listContainer, "TOPRIGHT", qtyColumnRightX - 54, -8)
  listHeaderName:SetJustifyH("LEFT")
  listHeaderName:SetText("Item")

  local listHeaderCount = listContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  listHeaderCount:SetPoint("TOPRIGHT", qtyColumnRightX, -8)
  listHeaderCount:SetJustifyH("Left")
  listHeaderCount:SetText("Qty")

  local scrollFrame = CreateFrame("ScrollFrame", nil, listContainer, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", 6, -22)
  scrollFrame:SetPoint("BOTTOMRIGHT", -28, 6)

  local scrollChild = CreateFrame("Frame", nil, scrollFrame)
  scrollChild:SetSize(250, 200)
  scrollFrame:SetScrollChild(scrollChild)

  local rows = {}
  local rowHeight = 22
  local checkboxSize = 16
  local checkboxPadding = 6
  local rowWidth = 240
  for i = 1, 10 do
    local row = CreateFrame("CheckButton", nil, scrollChild, "UICheckButtonTemplate")
    row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
    row:SetSize(rowWidth, rowHeight)
    row.text:SetText("")
    row.text:Hide()
    local normalTexture = row:GetNormalTexture()
    local pushedTexture = row:GetPushedTexture()
    local highlightTexture = row:GetHighlightTexture()
    local checkedTexture = row:GetCheckedTexture()
    local disabledCheckedTexture = row:GetDisabledCheckedTexture()
    if normalTexture then
      normalTexture:SetSize(checkboxSize, checkboxSize)
      normalTexture:ClearAllPoints()
      normalTexture:SetPoint("LEFT", row, "LEFT", shareColumnX, 0)
    end
    if pushedTexture then
      pushedTexture:SetSize(checkboxSize, checkboxSize)
      pushedTexture:ClearAllPoints()
      pushedTexture:SetPoint("LEFT", row, "LEFT", shareColumnX, 0)
    end
    if highlightTexture then
      highlightTexture:SetSize(checkboxSize, checkboxSize)
      highlightTexture:ClearAllPoints()
      highlightTexture:SetPoint("LEFT", row, "LEFT", shareColumnX, 0)
    end
    if checkedTexture then
      checkedTexture:SetSize(checkboxSize, checkboxSize)
      checkedTexture:ClearAllPoints()
      checkedTexture:SetPoint("LEFT", row, "LEFT", shareColumnX, 0)
    end
    if disabledCheckedTexture then
      disabledCheckedTexture:SetSize(checkboxSize, checkboxSize)
      disabledCheckedTexture:ClearAllPoints()
      disabledCheckedTexture:SetPoint("LEFT", row, "LEFT", shareColumnX, 0)
    end

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameText:SetPoint("LEFT", row, "LEFT", itemColumnX, 0)
    nameText:SetPoint("RIGHT", row, "RIGHT", qtyColumnRightX - 54, 0)
    nameText:SetJustifyH("LEFT")

    local countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    countText:SetPoint("RIGHT", row, "RIGHT", qtyColumnRightX, 0)
    countText:SetJustifyH("RIGHT")
    countText:SetWidth(50)

    row.nameText = nameText
    row.countText = countText
    row:SetScript("OnClick", function(btn)
      if not btn.itemID then
        return
      end
      SND.db.config.shareMatsExclusions = SND.db.config.shareMatsExclusions or {}
      if btn:GetChecked() then
        SND.db.config.shareMatsExclusions[btn.itemID] = nil
      else
        SND.db.config.shareMatsExclusions[btn.itemID] = true
      end
      SND:PublishSharedMats()
    end)
    row:SetScript("OnEnter", function(btn)
      if btn.itemID then
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. tostring(btn.itemID))
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    row:Hide()
    rows[i] = row
  end

  local emptyLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  emptyLabel:SetPoint("TOPLEFT", 4, -4)
  emptyLabel:SetText("No shared mats match.")
  emptyLabel:Hide()

  frame.scanStatus = scanStatus
  frame.scanAlertLabel = scanAlertLabel
  frame.professionsList = professionsList
  frame.matsStatus = matsStatus
  frame.matsSummary = matsSummary
  frame.sharedMatsSearchBox = matsSearchBox
  frame.sharedMatsRows = rows
  frame.sharedMatsScrollChild = scrollChild
  frame.sharedMatsRowHeight = rowHeight
  frame.sharedMatsEmptyLabel = emptyLabel

  self.scanLogCopyModal = scanLogCopyModal
  self.scanLogCopyScroll = scanLogCopyScroll
  self.scanLogCopyEditBox = scanLogCopyEditBox

  return frame
end

function SND:CreateRequestModal()
  if self.requestModal then
    return
  end
  local modal = CreateFrame("Frame", "SNDRequestModal", UIParent, "BackdropTemplate")
  modal:SetSize(600, 620)
  modal:SetPoint("CENTER")
  modal:SetFrameStrata(SND_MODAL_STRATA)
  modal:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  modal:SetBackdropColor(0.08, 0.08, 0.1, 1)
  modal:EnableMouse(true)
  modal:SetMovable(true)
  modal:RegisterForDrag("LeftButton")
  modal:SetScript("OnDragStart", modal.StartMoving)
  modal:SetScript("OnDragStop", modal.StopMovingOrSizing)
  modal:SetScript("OnShow", function(modalFrame)
    SND:BringAddonFrameToFront(modalFrame, SND_MODAL_STRATA)
  end)
  modal:SetScript("OnMouseDown", function(modalFrame)
    SND:BringAddonFrameToFront(modalFrame, SND_MODAL_STRATA)
  end)
  modal:Hide()

  local title = modal:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 12, -12)
  title:SetText("New Request")

  local function sanitizeInteger(text, fallback)
    local n = tonumber(text)
    if not n then
      return fallback
    end
    n = math.floor(n)
    if n < 0 then
      return fallback
    end
    return n
  end

  local function parseStrictInteger(text)
    local n = tonumber(text)
    if not n then
      return nil
    end
    if n % 1 ~= 0 then
      return nil
    end
    return n
  end

  local function normalizeRecipeSpellID(value)
    if SND.NormalizeRecipeSpellID then
      return SND:NormalizeRecipeSpellID(value)
    end
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

  local function normalizeReadableText(text)
    if type(text) ~= "string" then
      return nil
    end
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
      return nil
    end
    if trimmed:match("^table:%s*[%x]+$") then
      return nil
    end
    if trimmed:match("^userdata:%s*[%x]+$") then
      return nil
    end
    if trimmed:match("^Recipe%s+table:%s*[%x]+$") then
      return nil
    end
    return trimmed
  end

  local function captureOwnedCounts()
    modal.ownedCounts = modal.ownedCounts or {}
    if not modal.materialRows then
      return
    end
    for _, row in ipairs(modal.materialRows) do
      if row:IsShown() and row.itemID then
        local value = sanitizeInteger(row.haveBox:GetText(), 0)
        modal.ownedCounts[row.itemID] = value
      end
    end
  end

  local function resolveBaselineOwnedCount(itemID)
    if not itemID then
      return 0
    end

    if type(modal.prefillOwnedCounts) == "table" and modal.prefillOwnedCounts[itemID] ~= nil then
      local prefill = tonumber(modal.prefillOwnedCounts[itemID])
      prefill = prefill and math.floor(prefill) or 0
      if prefill >= 0 then
        return prefill
      end
    end

    local playerKey = SND:GetPlayerKey(UnitName("player"))
    local playerEntry = playerKey and SND.db and SND.db.players and SND.db.players[playerKey] or nil
    if playerEntry and type(playerEntry.sharedMats) == "table" and playerEntry.sharedMats[itemID] ~= nil then
      local shared = tonumber(playerEntry.sharedMats[itemID])
      shared = shared and math.floor(shared) or 0
      if shared >= 0 then
        return shared
      end
    end

    local localCount = GetItemCount(itemID, true)
    if localCount and localCount >= 0 then
      return localCount
    end
    return 0
  end

  local function ensureMaterialRowCapacity(required)
    modal.materialRows = modal.materialRows or {}
    if not modal.materialsScrollChild then
      return
    end
    while #modal.materialRows < required do
      local row = CreateFrame("Frame", nil, modal.materialsScrollChild)
      row:SetSize(490, 24)
      if #modal.materialRows == 0 then
        row:SetPoint("TOPLEFT", modal.materialsScrollChild, "TOPLEFT", 0, 0)
      else
        row:SetPoint("TOPLEFT", modal.materialRows[#modal.materialRows], "BOTTOMLEFT", 0, -4)
      end

      local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      nameText:SetPoint("LEFT", row, "LEFT", 2, 0)
      nameText:SetWidth(250)
      nameText:SetJustifyH("LEFT")

      local requiredText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      requiredText:SetPoint("LEFT", nameText, "RIGHT", 8, 0)
      requiredText:SetWidth(120)
      requiredText:SetJustifyH("LEFT")

      local haveBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
      haveBox:SetPoint("RIGHT", row, "RIGHT", -2, 0)
      haveBox:SetSize(70, 22)
      haveBox:SetAutoFocus(false)
      haveBox:SetScript("OnTextChanged", function()
        if row.itemID then
          modal.ownedCounts = modal.ownedCounts or {}
          local value = sanitizeInteger(haveBox:GetText(), 0)
          modal.ownedCounts[row.itemID] = value
        end
      end)

      row.nameText = nameText
      row.requiredText = requiredText
      row.haveBox = haveBox
      row:Hide()
      table.insert(modal.materialRows, row)
    end
  end

  local function refreshMaterialRows()
    if not modal then
      return
    end
    captureOwnedCounts()

    local recipeSpellID = modal.selectedRecipeSpellID
    if not recipeSpellID then
      if modal.materialsEmptyText then
        modal.materialsEmptyText:SetText(T("Select a recipe to see required materials."))
        modal.materialsEmptyText:Show()
      end
      if modal.materialRows then
        for _, row in ipairs(modal.materialRows) do
          row.itemID = nil
          row:Hide()
        end
      end
      return
    end

    local qty = sanitizeInteger(modal.qtyBox and modal.qtyBox:GetText(), 1)
    if qty < 1 then
      qty = 1
    end
    local reagents = SND:GetRecipeReagents(recipeSpellID)
    if not reagents or not next(reagents) then
      if modal.materialsEmptyText then
        modal.materialsEmptyText:SetText("No reagent data yet.")
        modal.materialsEmptyText:Show()
      end
      if modal.materialRows then
        for _, row in ipairs(modal.materialRows) do
          row.itemID = nil
          row:Hide()
        end
      end
      return
    end

    local list = {}
    for itemID, perCraftCount in pairs(reagents) do
      local itemName = GetItemInfo(itemID) or ("Item " .. tostring(itemID))
      table.insert(list, {
        itemID = itemID,
        name = itemName,
        required = (perCraftCount or 0) * qty,
      })
    end
    table.sort(list, function(a, b)
      return a.name < b.name
    end)

    ensureMaterialRowCapacity(#list)
    modal.ownedCounts = modal.ownedCounts or {}

    for i, entry in ipairs(list) do
      local row = modal.materialRows[i]
      row.itemID = entry.itemID
      row.nameText:SetText(entry.name)
      row.requiredText:SetText(string.format("Need: %d", entry.required))

      local owned = modal.ownedCounts[entry.itemID]
      if owned == nil then
        owned = resolveBaselineOwnedCount(entry.itemID)
        modal.ownedCounts[entry.itemID] = owned
      end
      row.haveBox:SetText(tostring(owned))
      row:Show()
    end

    for i = #list + 1, #(modal.materialRows or {}) do
      local row = modal.materialRows[i]
      row.itemID = nil
      row:Hide()
    end

    if modal.materialsScrollChild then
      local contentHeight = math.max(140, (#list * 28))
      modal.materialsScrollChild:SetHeight(contentHeight)
    end

    if modal.materialsEmptyText then
      modal.materialsEmptyText:Hide()
    end
  end

  local function refreshSelectionContext()
    if not modal then
      return
    end

    local resolved = nil
    if modal.selectedRecipeSpellID and SND.ResolveRecipeDisplayData then
      resolved = SND:ResolveRecipeDisplayData(modal.selectedRecipeSpellID, {
        itemID = modal.selectedRecipeItemID,
        itemLink = modal.selectedRecipeItemLink,
        itemText = modal.selectedRecipeItemText,
      })
    end

    if resolved then
      modal.selectedRecipeItemID = resolved.itemID
      modal.selectedRecipeItemLink = resolved.itemLink
      modal.selectedRecipeItemText = resolved.itemText
    end

    local displayItemID = (resolved and resolved.itemID) or modal.selectedRecipeItemID
    local displayItemLink = (resolved and resolved.itemLink) or modal.selectedRecipeItemLink
    local displayItemText = (resolved and resolved.itemText) or modal.selectedRecipeItemText

    modal.selectedRecipeOutputLink = displayItemLink or nil

    if modal.selectedItemLinkValue then
      if modal.selectedItemLabel then
        modal.selectedItemLabel:Show()
      end
      if modal.selectedItemLinkButton then
        modal.selectedItemLinkButton:Show()
      end
      modal.selectedItemLinkValue:SetText(displayItemText or "-")

      SND:DebugOnlyLog(string.format(
        "Request modal item render: recipeSpellID=%s outputLink=%s itemText=%s itemID=%s displayed=%s",
        tostring(modal.selectedRecipeSpellID),
        tostring(modal.selectedRecipeOutputLink),
        tostring(modal.selectedRecipeItemText),
        tostring(modal.selectedRecipeItemID),
        tostring(modal.selectedItemLinkValue:GetText())
      ))
    end

    if modal.selectedItemIcon then
      local iconTexture = (resolved and resolved.icon) or (displayItemID and GetItemIcon(displayItemID)) or (displayItemLink and GetItemIcon(displayItemLink)) or nil
      modal.selectedItemIcon:SetTexture(iconTexture or "Interface/Icons/INV_Misc_QuestionMark")
    end

    if modal.selectedCrafterValue then
      local crafterName = modal.selectedCrafterName
      if crafterName and crafterName ~= "" then
        local display = crafterName:match("^[^-]+") or crafterName
        local details = {}
        if modal.selectedCrafterProfession and modal.selectedCrafterProfession ~= "" then
          table.insert(details, modal.selectedCrafterProfession)
        end
        if modal.selectedCrafterOnline ~= nil then
          table.insert(details, modal.selectedCrafterOnline and T("Online") or T("Offline"))
        end
        if modal.selectedCrafterHasSharedMats ~= nil then
          table.insert(details, modal.selectedCrafterHasSharedMats and "Shared mats: Yes" or "Shared mats: No")
        end
        if #details > 0 then
          modal.selectedCrafterValue:SetText(string.format("%s (%s)", display, table.concat(details, ", ")))
        else
          modal.selectedCrafterValue:SetText(display)
        end
      else
        modal.selectedCrafterValue:SetText("Any crafter")
      end
    end
  end

  local function setSelectedRecipe(recipeSpellID, recipeName, prefill)
    recipeSpellID = normalizeRecipeSpellID(recipeSpellID)
    modal.ownedCounts = {}
    modal.selectedRecipeSpellID = recipeSpellID
    modal.selectedRecipePrefill = type(prefill) == "table" and prefill or nil
    modal.selectedRecipeItemID = modal.selectedRecipePrefill and modal.selectedRecipePrefill.itemID or nil
    modal.selectedRecipeItemLink = modal.selectedRecipePrefill and modal.selectedRecipePrefill.itemLink or nil
    modal.selectedRecipeItemText = modal.selectedRecipePrefill and modal.selectedRecipePrefill.itemText or "FUCK THIS 1"
    modal.selectedRecipeProfessionName = modal.selectedRecipePrefill and modal.selectedRecipePrefill.professionName or nil
    modal.selectedRecipeProfessionSkillLineID = modal.selectedRecipePrefill and modal.selectedRecipePrefill.professionSkillLineID or nil
    modal.selectedCrafterName = modal.selectedRecipePrefill and modal.selectedRecipePrefill.crafterName or nil
    modal.selectedCrafterOnline = modal.selectedRecipePrefill and modal.selectedRecipePrefill.crafterOnline or nil
    modal.selectedCrafterHasSharedMats = modal.selectedRecipePrefill and modal.selectedRecipePrefill.crafterHasSharedMats or nil
    modal.selectedCrafterProfession = modal.selectedRecipePrefill and modal.selectedRecipePrefill.crafterProfession or nil
    modal.prefillOwnedCounts = modal.selectedRecipePrefill and modal.selectedRecipePrefill.ownedCounts or nil
    if recipeSpellID then
      local recipe = SND.db.recipeIndex[recipeSpellID]
      local normalizedRecipeName = normalizeReadableText(recipeName)
        or normalizeReadableText(recipe and recipe.name)
        or ("Recipe #" .. tostring(recipeSpellID))
      modal.selectedRecipeLabel:SetText(normalizedRecipeName)

      if SND.ResolveRecipeDisplayData then
        local resolved = SND:ResolveRecipeDisplayData(recipeSpellID, {
          itemID = modal.selectedRecipeItemID,
          itemLink = modal.selectedRecipeItemLink,
          itemText = modal.selectedRecipeItemText,
        })
        modal.selectedRecipeItemID = resolved and resolved.itemID or modal.selectedRecipeItemID
        modal.selectedRecipeItemLink = resolved and resolved.itemLink or modal.selectedRecipeItemLink
        modal.selectedRecipeItemText = resolved and resolved.itemText or modal.selectedRecipeItemText
      end

      if not modal.selectedRecipeProfessionSkillLineID then
        modal.selectedRecipeProfessionSkillLineID = recipe and recipe.professionSkillLineID or nil
      end

      SND:DebugLog(string.format(
        "Request modal prefill: recipeSpellID=%s recipeName=%s itemID=%s professionSkillLineID=%s professionName=%s",
        tostring(recipeSpellID),
        tostring(recipeName or (recipe and recipe.name)),
        tostring(modal.selectedRecipeItemID),
        tostring(modal.selectedRecipeProfessionSkillLineID),
        tostring(modal.selectedRecipeProfessionName)
      ))
    else
      modal.selectedRecipeLabel:SetText("-")
      modal.selectedRecipeItemID = nil
      modal.selectedRecipeItemLink = nil
      modal.selectedRecipeItemText = recipeSpellID
      modal.selectedRecipeProfessionName = nil
      modal.selectedRecipeProfessionSkillLineID = nil
      modal.selectedCrafterName = nil
      modal.selectedCrafterOnline = nil
      modal.selectedCrafterHasSharedMats = nil
      modal.selectedCrafterProfession = nil
      modal.prefillOwnedCounts = nil
    end
    refreshSelectionContext()
    refreshMaterialRows()
  end

  local function applyRecipeSelectionMode()
    local locked = modal.lockRecipeSelection and true or false

    if modal.searchLabel then
      modal.searchLabel:SetShown(not locked)
    end
    if modal.searchBox then
      modal.searchBox:SetShown(not locked)
    end
    if modal.resultsFrame then
      modal.resultsFrame:SetShown(not locked)
    end
    if modal.prevPageButton then
      modal.prevPageButton:SetShown(not locked)
    end
    if modal.nextPageButton then
      modal.nextPageButton:SetShown(not locked)
    end
    if modal.pageLabel then
      modal.pageLabel:SetShown(not locked)
    end

    if modal.searchSection then
      modal.searchSection:SetShown(not locked)
    end

    if modal.targetHeader then
      modal.targetHeader:ClearAllPoints()
      if locked then
        modal.targetHeader:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
      else
        modal.targetHeader:SetPoint("TOPLEFT", modal.searchSection, "BOTTOMLEFT", 0, -8)
      end
    end

    if locked and modal.resultButtons then
      for _, button in ipairs(modal.resultButtons) do
        button.recipeSpellID = nil
        button.recipeName = nil
        button:Hide()
      end
    end

    if modal.selectedItemLabel then
      modal.selectedItemLabel:Show()
    end
    if modal.selectedItemLinkButton then
      modal.selectedItemLinkButton:Show()
    end
  end

  local close = CreateFrame("Button", nil, modal, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  local searchSection = CreateFrame("Frame", nil, modal)
  searchSection:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  searchSection:SetPoint("TOPRIGHT", modal, "TOPRIGHT", -16, -40)
  searchSection:SetHeight(160)

  local searchLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  searchLabel:SetPoint("TOPLEFT", searchSection, "TOPLEFT", 0, 0)
  searchLabel:SetText("Recipe Search")

  local searchBox = CreateFrame("EditBox", nil, modal, "InputBoxTemplate")
  searchBox:SetSize(260, 24)
  searchBox:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -4)
  searchBox:SetAutoFocus(false)
  searchBox:SetScript("OnEnterPressed", function(edit)
    edit:ClearFocus()
    SND:UpdateRequestSearchResults(edit:GetText())
  end)
  searchBox:SetScript("OnTextChanged", function(edit)
    SND:Debounce("request_modal_search", 0.2, function()
      SND:UpdateRequestSearchResults(edit:GetText())
    end)
  end)

  local results = CreateFrame("Frame", nil, modal)
  results:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -8)
  results:SetSize(260, 110)

  local resultButtons = {}
  for i = 1, 6 do
    local button = CreateFrame("Button", nil, results, "UIPanelButtonTemplate")
    button:SetSize(240, 22)
    if i == 1 then
      button:SetPoint("TOPLEFT", 0, 0)
    else
      button:SetPoint("TOPLEFT", resultButtons[i - 1], "BOTTOMLEFT", 0, -4)
    end
    button:SetScript("OnClick", function(btn)
      setSelectedRecipe(btn.recipeSpellID, btn.recipeName)
    end)
    button:SetScript("OnEnter", function(btn)
      if btn.recipeSpellID then
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        local outputLink = SND:GetRecipeOutputItemLink(btn.recipeSpellID)
        if outputLink then
          GameTooltip:SetHyperlink(outputLink)
        else
          GameTooltip:SetText(btn:GetText())
        end
        GameTooltip:Show()
      end
    end)
    button:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    button:Hide()
    resultButtons[i] = button
  end

  local prevPage = CreateFrame("Button", nil, modal, "UIPanelButtonTemplate")
  prevPage:SetPoint("TOPLEFT", results, "BOTTOMLEFT", 0, -6)
  prevPage:SetSize(60, 20)
  prevPage:SetText("Prev")
  prevPage:SetScript("OnClick", function()
    modal.searchPage = math.max(1, (modal.searchPage or 1) - 1)
    SND:UpdateRequestSearchResults(searchBox:GetText())
  end)

  local nextPage = CreateFrame("Button", nil, modal, "UIPanelButtonTemplate")
  nextPage:SetPoint("LEFT", prevPage, "RIGHT", 6, 0)
  nextPage:SetSize(60, 20)
  nextPage:SetText("Next")
  nextPage:SetScript("OnClick", function()
    modal.searchPage = (modal.searchPage or 1) + 1
    SND:UpdateRequestSearchResults(searchBox:GetText())
  end)

  local pageLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  pageLabel:SetPoint("LEFT", nextPage, "RIGHT", 6, 0)
  pageLabel:SetText("Page 1/1")

  local targetHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  targetHeader:SetPoint("TOPLEFT", searchSection, "BOTTOMLEFT", 0, -8)
  targetHeader:SetText("1) Target Summary")

  local targetSection = CreateFrame("Frame", nil, modal, "BackdropTemplate")
  targetSection:SetPoint("TOPLEFT", targetHeader, "BOTTOMLEFT", -4, -4)
  targetSection:SetPoint("TOPRIGHT", modal, "TOPRIGHT", -16, 0)
  targetSection:SetHeight(96)
  targetSection:SetBackdrop({
    bgFile = "Interface/ChatFrame/ChatFrameBackground",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 8,
    edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  targetSection:SetBackdropColor(0.04, 0.04, 0.05, 1)

  local selectedLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  selectedLabel:SetPoint("TOPLEFT", targetSection, "TOPLEFT", 8, -10)
  selectedLabel:SetText("Recipe")

  local selectedValue = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  selectedValue:SetPoint("LEFT", selectedLabel, "RIGHT", 8, 0)
  selectedValue:SetPoint("RIGHT", targetSection, "RIGHT", -8, 0)
  selectedValue:SetJustifyH("LEFT")
  selectedValue:SetText("-")

  local selectedItemLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  selectedItemLabel:SetPoint("TOPLEFT", selectedLabel, "BOTTOMLEFT", 0, -8)
  selectedItemLabel:SetText("Item")

  local selectedItemValue = CreateFrame("Button", nil, modal)
  selectedItemValue:SetPoint("LEFT", selectedItemLabel, "RIGHT", 8, 0)
  selectedItemValue:SetPoint("RIGHT", targetSection, "RIGHT", -8, 0)
  selectedItemValue:SetHeight(40)
  selectedItemValue:SetScript("OnClick", function()
    if modal.selectedRecipeOutputLink and HandleModifiedItemClick then
      HandleModifiedItemClick(modal.selectedRecipeOutputLink)
    end
  end)
  selectedItemValue:SetScript("OnEnter", function(btn)
    if not modal.selectedRecipeOutputLink then
      return
    end
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(modal.selectedRecipeOutputLink)
    GameTooltip:Show()
  end)
  selectedItemValue:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  local selectedItemIcon = selectedItemValue:CreateTexture(nil, "ARTWORK")
  selectedItemIcon:SetSize(32, 32)
  selectedItemIcon:SetPoint("LEFT", selectedItemValue, "LEFT", 0, 0)
  selectedItemIcon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
  local selectedItemValueText = selectedItemValue:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  selectedItemValueText:SetPoint("LEFT", selectedItemIcon, "RIGHT", 6, 0)
  selectedItemValueText:SetPoint("RIGHT", selectedItemValue, "RIGHT", 0, 0)
  selectedItemValueText:SetJustifyH("LEFT")
  selectedItemValueText:SetText("-")

  local selectedCrafterLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  selectedCrafterLabel:SetPoint("TOPLEFT", selectedItemValue, "BOTTOMLEFT", 0, -8)
  selectedCrafterLabel:SetText("Crafter")

  local selectedCrafterValue = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  selectedCrafterValue:SetPoint("LEFT", selectedCrafterLabel, "RIGHT", 8, 0)
  selectedCrafterValue:SetPoint("RIGHT", targetSection, "RIGHT", -8, 0)
  selectedCrafterValue:SetJustifyH("LEFT")
  selectedCrafterValue:SetText("Any crafter")

  local inputHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  inputHeader:SetPoint("TOPLEFT", targetSection, "BOTTOMLEFT", 4, -10)
  inputHeader:SetText("2) Request Inputs")

  local qtyLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  qtyLabel:SetPoint("TOPLEFT", inputHeader, "BOTTOMLEFT", 0, -8)
  qtyLabel:SetText("Quantity")

  local qtyBox = CreateFrame("EditBox", nil, modal, "InputBoxTemplate")
  qtyBox:SetSize(60, 24)
  qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
  qtyBox:SetAutoFocus(false)
  qtyBox:SetText("1")
  qtyBox:SetScript("OnTextChanged", function()
    refreshMaterialRows()
  end)

  local matsStatusCheck = CreateFrame("CheckButton", nil, modal, "UICheckButtonTemplate")
  matsStatusCheck:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -10)
  matsStatusCheck.text:SetText("Need mats from crafter")
  matsStatusCheck:SetChecked(false)

  local notesLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  notesLabel:SetPoint("TOPLEFT", matsStatusCheck, "BOTTOMLEFT", 4, -8)
  notesLabel:SetText("Notes")

  local notesBox = CreateFrame("EditBox", nil, modal, "InputBoxTemplate")
  notesBox:SetPoint("TOPLEFT", notesLabel, "BOTTOMLEFT", 0, -4)
  notesBox:SetPoint("RIGHT", modal, "RIGHT", -24, 0)
  notesBox:SetHeight(24)
  notesBox:SetAutoFocus(false)

  local matsHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  matsHeader:SetPoint("TOPLEFT", notesBox, "BOTTOMLEFT", 0, -10)
  matsHeader:SetText("3) Materials (Required + Owned)")

  local matsLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  matsLabel:SetPoint("TOPLEFT", matsHeader, "BOTTOMLEFT", 0, -4)
  matsLabel:SetText("Edit owned values in the right column")

  local matsScroll = CreateFrame("ScrollFrame", nil, modal, "UIPanelScrollFrameTemplate")
  matsScroll:SetPoint("TOPLEFT", matsLabel, "BOTTOMLEFT", 0, -4)
  matsScroll:SetPoint("RIGHT", modal, "RIGHT", -24, 0)

  local matsScrollChild = CreateFrame("Frame", nil, matsScroll)
  matsScrollChild:SetPoint("TOPLEFT", 0, 0)
  matsScrollChild:SetSize(500, 140)
  matsScroll:SetScrollChild(matsScrollChild)

  local matsEmptyText = matsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  matsEmptyText:SetPoint("TOPLEFT", 2, -2)
  matsEmptyText:SetText(T("Select a recipe to see required materials."))

  local actionHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  actionHeader:SetPoint("BOTTOMLEFT", modal, "BOTTOMLEFT", 14, 38)
  actionHeader:SetText("4) Actions")

  matsScroll:SetPoint("BOTTOMRIGHT", actionHeader, "TOPRIGHT", -18, 10)

  local submit = CreateFrame("Button", nil, modal, "UIPanelButtonTemplate")
  submit:SetPoint("BOTTOMRIGHT", modal, "BOTTOMRIGHT", -14, 10)
  submit:SetSize(100, 24)
  submit:SetText("Create")
  submit:SetScript("OnClick", function()
    if not modal.selectedRecipeSpellID then
      SND:DebugPrint("Request: select a recipe before creating.")
      return
    end

    local qty = parseStrictInteger(qtyBox:GetText())
    if not qty or qty < 1 then
      SND:DebugPrint("Request: quantity must be an integer >= 1.")
      return
    end

    captureOwnedCounts()
    local ownedCounts = {}
    if modal.materialRows then
      for _, row in ipairs(modal.materialRows) do
        if row:IsShown() and row.itemID then
          local value = parseStrictInteger(row.haveBox:GetText())
          if value == nil or value < 0 then
            SND:DebugPrint("Request: material owned counts must be integers >= 0.")
            return
          end
          ownedCounts[row.itemID] = value
        end
      end
    end

    local notes = notesBox:GetText() or ""
    local needsMats = matsStatusCheck:GetChecked() and true or false
    SND:CreateRequest(modal.selectedRecipeSpellID, qty, notes, {
      needsMats = needsMats,
      ownedCounts = ownedCounts,
    })
    modal:Hide()
  end)

  local cancel = CreateFrame("Button", nil, modal, "UIPanelButtonTemplate")
  cancel:SetPoint("RIGHT", submit, "LEFT", -8, 0)
  cancel:SetSize(100, 24)
  cancel:SetText("Cancel")
  cancel:SetScript("OnClick", function()
    modal:Hide()
  end)

  modal.titleText = title
  modal.searchSection = searchSection
  modal.targetHeader = targetHeader
  modal.searchBox = searchBox
  modal.searchLabel = searchLabel
  modal.resultsFrame = results
  modal.prevPageButton = prevPage
  modal.nextPageButton = nextPage
  modal.resultButtons = resultButtons
  modal.selectedLabelWidget = selectedLabel
  modal.selectedRecipeLabel = selectedValue
  modal.selectedItemLabel = selectedItemLabel
  modal.selectedItemLinkButton = selectedItemValue
  modal.selectedItemIcon = selectedItemIcon
  modal.selectedItemLinkValue = selectedItemValueText
  modal.selectedCrafterValue = selectedCrafterValue
  modal.qtyBox = qtyBox
  modal.matsStatusCheck = matsStatusCheck
  modal.notesBox = notesBox
  modal.materialsScroll = matsScroll
  modal.materialsScrollChild = matsScrollChild
  modal.materialsEmptyText = matsEmptyText
  modal.materialRows = {}
  modal.ownedCounts = {}
  modal.RefreshMaterials = refreshMaterialRows
  modal.SetSelectedRecipe = setSelectedRecipe
  modal.ApplyRecipeSelectionMode = applyRecipeSelectionMode
  modal.pageLabel = pageLabel
  modal.searchPage = 1
  modal.pageSize = #resultButtons

  self.requestModal = modal
end

function SND:ShowRequestModal()
  if not self.requestModal then
    self:CreateRequestModal()
  end
  if not self.requestModal then
    return
  end
  self.requestModal.selectedRecipeSpellID = nil
  self.requestModal.selectedRecipePrefill = nil
  self.requestModal.selectedRecipeItemID = nil
  self.requestModal.selectedRecipeItemLink = nil
  self.requestModal.selectedRecipeItemText = "FUCK THIS 3"
  self.requestModal.selectedRecipeProfessionName = nil
  self.requestModal.selectedRecipeProfessionSkillLineID = nil
  self.requestModal.selectedRecipeOutputLink = nil
  self.requestModal.selectedCrafterName = nil
  self.requestModal.selectedCrafterOnline = nil
  self.requestModal.selectedCrafterHasSharedMats = nil
  self.requestModal.selectedCrafterProfession = nil
  self.requestModal.prefillOwnedCounts = nil
  self.requestModal.lockRecipeSelection = false
  self.requestModal.selectedRecipeLabel:SetText("-")
  if self.requestModal.selectedItemLinkValue then
    self.requestModal.selectedItemLinkValue:SetText("-")
  end
  if self.requestModal.selectedItemIcon then
    self.requestModal.selectedItemIcon:SetTexture("Interface/Icons/INV_Misc_QuestionMark")
  end
  if self.requestModal.selectedCrafterValue then
    self.requestModal.selectedCrafterValue:SetText("Any crafter")
  end
  self.requestModal.searchBox:SetText("")
  self.requestModal.qtyBox:SetText("1")
  if self.requestModal.matsStatusCheck then
    self.requestModal.matsStatusCheck:SetChecked(false)
  end
  self.requestModal.notesBox:SetText("")
  self.requestModal.ownedCounts = {}
  self.requestModal.searchPage = 1
  for _, button in ipairs(self.requestModal.resultButtons) do
    button:Hide()
  end
  if self.requestModal.ApplyRecipeSelectionMode then
    self.requestModal:ApplyRecipeSelectionMode()
  end
  if self.requestModal.RefreshMaterials then
    self.requestModal:RefreshMaterials()
  end
  self:BringAddonFrameToFront(self.requestModal, SND_MODAL_STRATA)
  self.requestModal:Show()
  self:BringAddonFrameToFront(self.requestModal, SND_MODAL_STRATA)
end

function SND:ShowRequestModalForRecipe(recipeSpellID, prefill)
  if self.NormalizeRecipeSpellID then
    recipeSpellID = self:NormalizeRecipeSpellID(recipeSpellID)
  else
    if type(recipeSpellID) == "table" then
      recipeSpellID = tonumber(recipeSpellID.recipeSpellID)
        or tonumber(recipeSpellID.selectedRecipeSpellID)
        or tonumber(recipeSpellID.spellID)
    else
      recipeSpellID = tonumber(recipeSpellID)
    end
    if recipeSpellID then
      recipeSpellID = math.floor(recipeSpellID)
      if recipeSpellID <= 0 then
        recipeSpellID = nil
      end
    end
  end

  self:ShowRequestModal()
  if not recipeSpellID or not self.requestModal then
    return
  end

  self.requestModal.lockRecipeSelection = true
  if self.requestModal.ApplyRecipeSelectionMode then
    self.requestModal:ApplyRecipeSelectionMode()
  end

  local resolvedPrefill = nil
  if type(prefill) == "table" then
    resolvedPrefill = {
      recipeSpellID = recipeSpellID,
      recipeName = prefill.recipeName,
      itemID = prefill.itemID,
      itemLink = prefill.itemLink,
      itemText = prefill.itemText,
      professionName = prefill.professionName,
      professionSkillLineID = prefill.professionSkillLineID,
      crafterName = prefill.crafterName,
      crafterOnline = prefill.crafterOnline,
      crafterHasSharedMats = prefill.crafterHasSharedMats,
      crafterProfession = prefill.crafterProfession,
    }
  end

  local recipe = self.db and self.db.recipeIndex and self.db.recipeIndex[recipeSpellID] or nil
  if not resolvedPrefill then
    resolvedPrefill = {
      recipeSpellID = recipeSpellID,
      recipeName = recipe and recipe.name or nil,
      professionSkillLineID = recipe and recipe.professionSkillLineID or nil,
    }
  end

  if self.ResolveRecipeDisplayData then
    local resolvedDisplay = self:ResolveRecipeDisplayData(recipeSpellID, resolvedPrefill)
    if resolvedDisplay then
      resolvedPrefill.itemID = resolvedDisplay.itemID
      resolvedPrefill.itemLink = resolvedDisplay.itemLink
      resolvedPrefill.itemText = resolvedDisplay.itemText
    end
  end

  local prefillOwnedCounts = {}
  local reagents = self:GetRecipeReagents(recipeSpellID)
  if reagents then
    local playerKey = self:GetPlayerKey(UnitName("player"))
    local playerEntry = playerKey and self.db and self.db.players and self.db.players[playerKey] or nil
    for itemID in pairs(reagents) do
      local count = nil
      if playerEntry and type(playerEntry.sharedMats) == "table" then
        count = playerEntry.sharedMats[itemID]
      end
      if count == nil then
        count = GetItemCount(itemID, true)
      end
      count = tonumber(count)
      count = count and math.floor(count) or 0
      if count < 0 then
        count = 0
      end
      prefillOwnedCounts[itemID] = count
    end
  end
  resolvedPrefill.ownedCounts = prefillOwnedCounts

  if self.requestModal.SetSelectedRecipe then
    self.requestModal.SetSelectedRecipe(recipeSpellID, resolvedPrefill.recipeName, resolvedPrefill)
  else
    self.requestModal.selectedRecipeSpellID = recipeSpellID
    local recipe = self.db.recipeIndex[recipeSpellID]
    self.requestModal.selectedRecipeLabel:SetText((recipe and recipe.name) or ("Recipe " .. recipeSpellID))
    self.requestModal.selectedRecipePrefill = resolvedPrefill
    self.requestModal.prefillOwnedCounts = resolvedPrefill.ownedCounts
  end

  if self.requestModal.titleText then
    self.requestModal.titleText:SetText("New Request")
  end
end

function SND:ShowIncomingRequestPopup(requestId, requestData, sender)
  if type(requestData) ~= "table" then
    return
  end

  local recipeSpellID = self.NormalizeRecipeSpellID and self:NormalizeRecipeSpellID(requestData.recipeSpellID)
    or tonumber(requestData.recipeSpellID)
  if not recipeSpellID then
    return
  end

  -- Show custom popup notification
  if self.requestPopup then
    self:ShowRequestNotificationPopup(requestId, requestData, sender)
  end
end

function SND:CreateRequestPopup()
  local popup = CreateFrame("Frame", "SNDRequestPopup", UIParent, "BackdropTemplate")
  popup:SetSize(400, 180)
  popup:SetPoint("TOP", 0, -150)
  popup:SetFrameStrata("DIALOG")
  popup:SetFrameLevel(100)
  popup:SetBackdrop({
    bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
    edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  popup:Hide()

  -- Title
  local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -20)
  title:SetText("New Craft Request")
  popup.title = title

  -- Item icon
  local icon = popup:CreateTexture(nil, "ARTWORK")
  icon:SetSize(40, 40)
  icon:SetPoint("TOPLEFT", 20, -50)
  popup.icon = icon

  -- Item name
  local itemName = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  itemName:SetPoint("LEFT", icon, "RIGHT", 8, 10)
  itemName:SetPoint("RIGHT", popup, "RIGHT", -20, 0)
  itemName:SetJustifyH("LEFT")
  itemName:SetWordWrap(true)
  popup.itemName = itemName

  -- Requester name
  local requester = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  requester:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -8)
  requester:SetPoint("RIGHT", popup, "RIGHT", -20, 0)
  requester:SetJustifyH("LEFT")
  popup.requester = requester

  -- Claim & Craft button
  local claimButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  claimButton:SetSize(140, 25)
  claimButton:SetPoint("BOTTOMLEFT", 20, 20)
  claimButton:SetText("Claim & Craft")
  claimButton:SetScript("OnClick", function()
    if popup.requestId and popup.addon then
      -- Claim the request
      popup.addon:UpdateRequestStatus(popup.requestId, "CLAIMED", popup.addon:GetPlayerKey(UnitName("player")))

      -- Open main window and switch to Requests tab
      if popup.addon.mainFrame then
        popup.addon.mainFrame:Show()
        popup.addon:SelectTab(2) -- Requests tab

        -- Select the request
        if popup.addon.mainFrame.contentFrames and popup.addon.mainFrame.contentFrames[2] then
          local requestsFrame = popup.addon.mainFrame.contentFrames[2]
          popup.addon:RefreshRequestList(requestsFrame)
          popup.addon:SelectRequest(requestsFrame, popup.requestId)
        end
      end

      popup:Hide()
    end
  end)
  popup.claimButton = claimButton

  -- Dismiss button
  local dismissButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  dismissButton:SetSize(100, 25)
  dismissButton:SetPoint("LEFT", claimButton, "RIGHT", 10, 0)
  dismissButton:SetText("Dismiss")
  dismissButton:SetScript("OnClick", function()
    popup:Hide()
  end)
  popup.dismissButton = dismissButton

  -- Auto-hide timer
  popup.autoHideTime = 20
  popup:SetScript("OnUpdate", function(self, elapsed)
    if not self:IsShown() then
      return
    end

    self.autoHideTime = self.autoHideTime - elapsed
    if self.autoHideTime <= 0 then
      self:Hide()
    end
  end)

  -- Reset timer on show
  popup:SetScript("OnShow", function(self)
    self.autoHideTime = 20
  end)

  self.requestPopup = popup
end

function SND:ShowRequestNotificationPopup(requestId, requestData, sender)
  if not self.requestPopup then
    return
  end

  local popup = self.requestPopup
  popup.requestId = requestId
  popup.addon = self

  -- Get item info
  local recipeSpellID = self.NormalizeRecipeSpellID and self:NormalizeRecipeSpellID(requestData.recipeSpellID)
    or tonumber(requestData.recipeSpellID)

  local itemLink = requestData.itemLink or self:GetRecipeOutputItemLink(recipeSpellID)
  local itemIcon = requestData.itemIcon or self:GetRecipeOutputItemIcon(recipeSpellID)
  local _, itemText = self:ResolveReadableItemDisplay(recipeSpellID, {
    itemID = requestData.itemID,
    itemLink = requestData.itemLink,
    itemText = requestData.itemText,
  })

  -- Update popup content
  popup.icon:SetTexture(itemIcon or "Interface/Icons/INV_Misc_QuestionMark")
  popup.itemName:SetText(itemLink or itemText or "Unknown Item")

  local requesterName = requestData.requester and requestData.requester:match("^[^%-]+") or sender
  popup.requester:SetText(string.format("Requested by: %s", requesterName))

  -- Show popup
  popup:Show()
  popup:Raise()
end

-- ============================================================================
-- Window Size Persistence
-- ============================================================================

--[[
  SaveWindowSize - Save current window size to database

  Purpose:
    Persists the current main window dimensions to SavedVariables
    so they can be restored on next login.

  Side Effects:
    - Updates self.db.config.windowWidth
    - Updates self.db.config.windowHeight
]]--
function SND:SaveWindowSize()
  if not self.mainFrame then
    return
  end

  local width, height = self.mainFrame:GetSize()
  if not self.db or not self.db.config then
    return
  end

  self.db.config.windowWidth = width
  self.db.config.windowHeight = height
end
