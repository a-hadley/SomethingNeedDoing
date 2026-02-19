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
  frame:SetScale(self.db and self.db.config and self.db.config.uiScale or 1.0)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata(SND_MAIN_STRATA)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetScript("OnShow", function(shownFrame)
    SND:BringAddonFrameToFront(shownFrame, SND_MAIN_STRATA)
    SND:RefreshAllTabs()
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
  local tabNames = { T("Directory"), T("Requests"), T("Stats"), T("Options"), }
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
    self:CreateStatsTab(frame),
    self:CreateMeTab(frame),
  }
  self:BringAddonFrameToFront(frame, SND_MAIN_STRATA)
  self.mainFrame = frame
  tinsert(UISpecialFrames, "SNDMainFrame")
  self:SelectTab(1)
end

function SND:SelectTab(index)
  if not self.mainFrame then
    return
  end
  if self.TraceScanLog then
    self:TraceScanLog(string.format("Trace: SelectTab index=%s", tostring(index)))
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

  -- Cancel me-tab auto-refresh when leaving tab 4
  if index ~= 4 and self._meTabRefreshTicker then
    self:CancelSNDTimer(self._meTabRefreshTicker)
    self._meTabRefreshTicker = nil
  end

  if index == 2 then
    local requestsFrame = self.mainFrame.contentFrames[2]
    if requestsFrame then
      SND:RefreshRequestList(requestsFrame)
    end
  elseif index == 3 then
    local statsFrame = self.mainFrame.contentFrames[3]
    if statsFrame and type(self.RefreshStatsTab) == "function" then
      self:RefreshStatsTab(statsFrame)
    end
  elseif index == 4 then
    local meFrame = self.meTabFrame or self.mainFrame.contentFrames[4]
    if meFrame then
      self.meTabFrame = meFrame
      if self.TraceScanLog then
        self:TraceScanLog(string.format("Trace: SelectTab me activated dirty=%s", tostring(self._scanLogPendingDirty)))
      end
      SND:RefreshMeTab(meFrame)
      if self.PushScanLogLineToUI then
        self:PushScanLogLineToUI("Trace: ScanLog viewer ready")
      end
      if self._scanLogPendingDirty and self.TraceScanLog then
        self:TraceScanLog("Trace: SelectTab replay pending dirty")
      end

      -- Start auto-refresh timer (5s) for stats while tab 4 is visible
      if not self._meTabRefreshTicker then
        self._meTabRefreshTicker = self:ScheduleSNDRepeatingTimer(5, function()
          if self.mainFrame and self.mainFrame:IsShown() and self.mainFrame.activeTab == 4 then
            self:RefreshMeTab()
          else
            if self._meTabRefreshTicker then
              self:CancelSNDTimer(self._meTabRefreshTicker)
              self._meTabRefreshTicker = nil
            end
          end
        end)
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
  filterBar:SetClipsChildren(true)

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
  searchLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 0, 0)
  searchLabel:SetText(T("Search"))

  -- Load saved filter settings from database (must happen before checkbox creation)
  local savedDirFilters = SND.db.config.filters.directory
  frame.selectedProfession = savedDirFilters.selectedProfession or "All"
  frame.onlineOnly = savedDirFilters.onlineOnly or false
  frame.sharedMatsOnly = savedDirFilters.sharedMatsOnly or false
  frame.hideOwnRecipes = savedDirFilters.hideOwnRecipes or false
  frame.sortBy = savedDirFilters.sortBy or "name_az"

  -- Profession Filter
  local professionLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  professionLabel:SetPoint("TOPLEFT", searchLabel, "TOPRIGHT", 160, 0)
  professionLabel:SetText(T("Profession"))

  local professionDrop = CreateFrame("Frame", "SNDProfessionDropDown", filterBar, "UIDropDownMenuTemplate")
  professionDrop:SetPoint("LEFT", professionLabel, "LEFT", -18, -22)

  -- Online Only checkbox
  local onlineBox, onlineOnly = CreateBoundedCheckbox(filterBar, T("Online Only"))
  onlineBox:SetPoint("LEFT", professionDrop, "RIGHT", 0, 12)
  onlineOnly:SetChecked(frame.onlineOnly)
  onlineOnly:SetScript("OnClick", function(btn)
    frame.onlineOnly = btn:GetChecked() and true or false
    SND.db.config.filters.directory.onlineOnly = frame.onlineOnly
    SND:UpdateDirectoryResults(searchBox:GetText())
  end)

  -- Has Materials checkbox
  local matsBox, matsOnly = CreateBoundedCheckbox(filterBar, T("Has Materials"))
  matsBox:SetPoint("LEFT", onlineBox, "LEFT", 0, -28)
  matsOnly:SetChecked(frame.sharedMatsOnly)
  matsOnly:SetScript("OnClick", function(btn)
    frame.sharedMatsOnly = btn:GetChecked() and true or false
    SND.db.config.filters.directory.sharedMatsOnly = frame.sharedMatsOnly
    SND:UpdateDirectoryResults(searchBox:GetText())
  end)

  -- Hide My Recipies checkbox
  local hideOwnBox, hideOwnCheckbox = CreateBoundedCheckbox(filterBar, T("Hide My Recipes"))
  hideOwnBox:SetPoint("LEFT", matsBox, "LEFT", 0, -28)
  hideOwnCheckbox:SetChecked(frame.hideOwnRecipes)
  hideOwnCheckbox:SetScript("OnClick", function(btn)
    frame.hideOwnRecipes = btn:GetChecked() and true or false
    SND.db.config.filters.directory.hideOwnRecipes = frame.hideOwnRecipes
    SND:UpdateDirectoryResults(searchBox:GetText())
  end)

  -- Sort dropdown
  local sortLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  sortLabel:SetPoint("LEFT", searchLabel, "LEFT", 0, -40)
  sortLabel:SetText(T("Sort by"))

  local sortDrop = CreateFrame("Frame", "SNDSortDropDown", filterBar, "UIDropDownMenuTemplate")
  sortDrop:SetPoint("TOPLEFT", sortLabel, "BOTTOMLEFT", -20, 0)

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
        SND.db.config.filters.directory.sortBy = option.value
        UIDropDownMenu_SetText(sortDrop, option.text)
        SND:UpdateDirectoryResults(searchBox:GetText())
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(sortDrop, 110)
  -- Set initial text based on saved sortBy value
  local sortTextMap = {
    name_az = T("Name (A-Z)"),
    name_za = T("Name (Z-A)"),
    rarity = T("Rarity (High to Low)"),
    level = T("Level (High to Low)"),
  }
  UIDropDownMenu_SetText(sortDrop, sortTextMap[frame.sortBy] or T("Name (A-Z)"))

  local columnGap = 10

  local listContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  listContainer:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -8)
  listContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 12)
  -- Use relative positioning: ~26% of default width (330px at 1280px default)
  listContainer:SetPoint("RIGHT", frame, "LEFT", 295, 0)
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
  -- Use relative positioning: ~22% of default width (290px at 1280px default)
  detailContainer:SetPoint("RIGHT", frame, "LEFT", 660, 0)
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
  local columnNameX = 4
  local columnStatusX = columnNameX + nameColumnWidth + columnGap
  local columnMatsX = columnStatusX + statusColumnWidth + columnGap
  local ColumnActionsX = columnMatsX + matsColumnWidth + columnGap
  local whisperButtonWidth = 64
  local requestButtonWidth = 64
  -- Scroll child width will be set dynamically based on parent

  local crafterHeaderName = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderName:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", columnNameX, -6)
  crafterHeaderName:SetText(T("Crafter"))

  local crafterHeaderStatus = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderStatus:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", columnStatusX, -6)
  crafterHeaderStatus:SetText(T("Status"))

  -- local crafterHeaderMats = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  -- crafterHeaderMats:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", columnMatsX, -6)
  -- crafterHeaderMats:SetText(T("Mats"))

  local crafterHeaderActions = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeaderActions:SetPoint("TOPLEFT", craftersTitle, "BOTTOMLEFT", ColumnActionsX, -6)
  crafterHeaderActions:SetJustifyH("LEFT")
  crafterHeaderActions:SetText(T("Actions"))

  local crafterScrollFrame = CreateFrame("ScrollFrame", nil, detailContainer, "UIPanelScrollFrameTemplate")
  crafterScrollFrame:SetPoint("TOPLEFT", crafterHeaderName, "BOTTOMLEFT", -4, -4)
  crafterScrollFrame:SetPoint("BOTTOMRIGHT", detailContainer, "BOTTOMRIGHT", -26, 8)

  local crafterScrollChild = CreateFrame("Frame", nil, crafterScrollFrame)
  crafterScrollChild:SetSize(320, 120)
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
    requestButton:SetSize(requestButtonWidth, 30)
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

    local whisperButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    whisperButton:SetPoint("LEFT", requestButton, "RIGHT", 0, 0)
    whisperButton:SetSize(whisperButtonWidth, 30)
    whisperButton:SetText(T("Whisper"))
    whisperButton:SetScript("OnClick", function()
      if row.crafterName then
        SND:WhisperPlayer(row.crafterName, row.itemLink, row.itemText, row.recipeSpellID)
      end
    end)

    row.nameText = nameText
    row.statusText = statusText
    --row.matsText = matsText
    row.requestButton = requestButton
    row.whisperButton = whisperButton
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
  matsHeader:SetPoint("RIGHT", -4, 0)
  matsHeader:SetJustifyH("LEFT")
  matsHeader:SetText(T("Required Materials"))

  local matsScrollFrame = CreateFrame("ScrollFrame", nil, rightContainer, "UIPanelScrollFrameTemplate")
  matsScrollFrame:SetPoint("TOPLEFT", matsHeader, "BOTTOMLEFT", 0, -6)
  matsScrollFrame:SetPoint("BOTTOMRIGHT", rightContainer, "BOTTOMRIGHT", -26, 8)

  local matsScrollChild = CreateFrame("Frame", nil, matsScrollFrame)
  matsScrollChild:SetHeight(220)
  matsScrollFrame:SetScrollChild(matsScrollChild)
  -- Match scroll child width to scroll frame so text doesn't wrap early
  matsScrollFrame:SetScript("OnSizeChanged", function(sf)
    matsScrollChild:SetWidth(sf:GetWidth())
  end)
  matsScrollChild:SetWidth(matsScrollFrame:GetWidth() > 0 and matsScrollFrame:GetWidth() or 300)

  -- Enable item link tooltips on hover
  matsScrollChild:SetHyperlinksEnabled(true)
  matsScrollChild:SetScript("OnHyperlinkEnter", function(_, link)
    GameTooltip:SetOwner(matsScrollChild, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  matsScrollChild:SetScript("OnHyperlinkLeave", function()
    GameTooltip:Hide()
  end)

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
        elseif type(btn.recipeSpellID) == "number" then
          -- No item link (e.g. enchanting) — show spell tooltip
          GameTooltip:SetSpellByID(btn.recipeSpellID)
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

  UIDropDownMenu_Initialize(professionDrop, function(dropdown, level)
    local options = SND:GetProfessionFilterOptions()
    for _, option in ipairs(options) do
      local value = option
      local info = UIDropDownMenu_CreateInfo()
      info.text = value
      info.checked = value == frame.selectedProfession
      info.func = function()
        frame.selectedProfession = value
        SND.db.config.filters.directory.selectedProfession = value
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
  filterBar:SetHeight(110)
  filterBar:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  filterBar:SetBackdropColor(0.08, 0.06, 0.03, 1)
  filterBar:SetClipsChildren(true)

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
  searchLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 0, 0)
  searchLabel:SetText("Search")

    -- Sort dropdown
  -- local sortLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  -- sortLabel:SetPoint("LEFT", searchLabel, "LEFT", 0, -40)
  -- sortLabel:SetText(T("Sort by"))

  -- local sortDrop = CreateFrame("Frame", "SNDSortDropDown", filterBar, "UIDropDownMenuTemplate")
  -- sortDrop:SetPoint("TOPLEFT", sortLabel, "BOTTOMLEFT", -20, 0)

  -- UIDropDownMenu_Initialize(sortDrop, function(dropdown, level)
  --   local options = {
  --     { value = "namee_az", text = T("Name (A-Z)") },
  --     { value = "name_za", text = T("Name (Z-A)") },
  --     { value = "rarity", text = T("Rarity (High to Low)") },
  --     { value = "status", text = T("Status") },
  --   }
  --   for _, option in ipairs(options) do
  --     local info = UIDropDownMenu_CreateInfo()
  --     info.text = option.text
  --     info.checked = option.value == frame.sortBy
  --     info.func = function()
  --       frame.sortBy = option.value
  --       UIDropDownMenu_SetText(sortDrop, option.text)
  --       SND:UpdateDirectoryResults(searchBox:GetText())
  --     end
  --     UIDropDownMenu_AddButton(info, level)
  --   end
  -- end)
  -- UIDropDownMenu_SetWidth(sortDrop, 110)
  -- UIDropDownMenu_SetText(sortDrop, T("Name (A-Z)"))

  -- Profession filter
  -- Load saved filter settings from database (must happen before checkbox creation)
  local savedReqFilters = SND.db.config.filters.requests
  frame.professionFilter = savedReqFilters.professionFilter or "All"
  frame.statusFilter = savedReqFilters.statusFilter or "ALL"
  frame.viewMode = savedReqFilters.viewMode or "ALL"
  frame.onlyMine = savedReqFilters.onlyMine or false
  frame.onlyClaimable = savedReqFilters.onlyClaimable or false
  frame.hasMaterialsOnly = savedReqFilters.hasMaterialsOnly or false

  local professionLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  professionLabel:SetPoint("TOPLEFT", searchLabel, "TOPRIGHT", 160, 0)
  professionLabel:SetText("Profession")

  local professionDrop = CreateFrame("Frame", "SNDRequestProfessionDropDown", filterBar, "UIDropDownMenuTemplate")
  professionDrop:SetPoint("TOPLEFT", professionLabel, "BOTTOMLEFT", -18, 0)

  -- Status filter
  local statusLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusLabel:SetPoint("TOPLEFT", professionLabel, "BOTTOMLEFT", 0, -30)
  statusLabel:SetText("Status")

  local statusDrop = CreateFrame("Frame", "SNDRequestStatusDropDown", filterBar, "UIDropDownMenuTemplate")
  statusDrop:SetPoint("TOPLEFT", statusLabel, "BOTTOMLEFT", -18, 0)

  -- View mode dropdown (replaces old "My Requests" checkbox)
  local viewLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  viewLabel:SetPoint("TOPLEFT", professionLabel, "TOPRIGHT", 80, 0)
  viewLabel:SetText("View")

  local viewDrop = CreateFrame("Frame", "SNDRequestViewDropDown", filterBar, "UIDropDownMenuTemplate")
  viewDrop:SetPoint("TOPLEFT", viewLabel, "BOTTOMLEFT", -18, 0)

  local viewOptions = {
    { text = "All Requests", value = "ALL" },
    { text = "My Requests", value = "MY_REQUESTS" },
    { text = "My Claims", value = "MY_CLAIMS" },
  }

  UIDropDownMenu_Initialize(viewDrop, function(_, level, menuList)
    for _, option in ipairs(viewOptions) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = option.text
      info.checked = option.value == frame.viewMode
      info.func = function()
        frame.viewMode = option.value
        SND.db.config.filters.requests.viewMode = option.value
        UIDropDownMenu_SetText(viewDrop, option.text)
        SND:RefreshRequestList(frame)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(viewDrop, 120)
  local viewInitText = "All Requests"
  for _, opt in ipairs(viewOptions) do
    if opt.value == frame.viewMode then viewInitText = opt.text break end
  end
  UIDropDownMenu_SetText(viewDrop, viewInitText)

  -- Unclaimed only
  local onlyClaimableBox, onlyClaimable = CreateBoundedCheckbox(filterBar, "Unclaimed Only")
  onlyClaimableBox:SetPoint("LEFT", viewDrop, "RIGHT", 0, 12)
  onlyClaimable:SetChecked(frame.onlyClaimable)
  onlyClaimable:SetScript("OnClick", function(btn)
    frame.onlyClaimable = btn:GetChecked() and true or false
    SND.db.config.filters.requests.onlyClaimable = frame.onlyClaimable
    SND:RefreshRequestList(frame)
  end)

  -- Has materials
  local hasMatsBox, hasMatsCheck = CreateBoundedCheckbox(filterBar, "Has Materials")
  hasMatsBox:SetPoint("LEFT", onlyClaimableBox, "LEFT", 0, -28)
  hasMatsCheck:SetChecked(frame.hasMaterialsOnly)
  hasMatsCheck:SetScript("OnClick", function(btn)
    frame.hasMaterialsOnly = btn:GetChecked() and true or false
    SND.db.config.filters.requests.hasMaterialsOnly = frame.hasMaterialsOnly
    SND:RefreshRequestList(frame)
  end)

  local columnGap = 10
  local listContainer = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  listContainer:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -8)
  listContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 12)
  -- Use relative positioning: ~45% of default width (576px at 1280px default)
  listContainer:SetPoint("RIGHT", frame, "LEFT", 584, 0)
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
  detailTitle:SetPoint("RIGHT", -4, 0)
  detailTitle:SetJustifyH("LEFT")
  detailTitle:SetText("Unclaimed Request")

  local detailRequester = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detailRequester:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -8)
  detailRequester:SetPoint("RIGHT", -4, 0)
  detailRequester:SetJustifyH("LEFT")
  detailRequester:SetText("")

  local detailTip = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detailTip:SetPoint("TOPLEFT", detailRequester, "BOTTOMLEFT", 0, -4)
  detailTip:SetPoint("RIGHT", -4, 0)
  detailTip:SetJustifyH("LEFT")
  detailTip:Hide()

  local detailPreferredCrafter = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  detailPreferredCrafter:SetPoint("TOPLEFT", detailTip, "BOTTOMLEFT", 0, -2)
  detailPreferredCrafter:SetPoint("RIGHT", -4, 0)
  detailPreferredCrafter:SetJustifyH("LEFT")
  detailPreferredCrafter:Hide()

  local detailItemHeader = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  detailItemHeader:SetPoint("TOPLEFT", detailPreferredCrafter, "BOTTOMLEFT", 0, -8)
  detailItemHeader:SetPoint("RIGHT", -4, 0)
  detailItemHeader:SetJustifyH("LEFT")
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
  detailInfo:SetPoint("RIGHT", -4, 0)
  detailInfo:SetJustifyH("LEFT")
  detailInfo:Hide()

  local notesTitle = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  notesTitle:SetPoint("TOPLEFT", detailItemButton, "BOTTOMLEFT", 0, -6)
  notesTitle:SetPoint("RIGHT", -4, 0)
  notesTitle:SetJustifyH("LEFT")
  notesTitle:SetText("Notes")

  local notesBox = CreateFrame("EditBox", nil, detailContainer, "InputBoxTemplate")
  notesBox:SetPoint("TOPLEFT", notesTitle, "BOTTOMLEFT", 0, -4)
  notesBox:SetPoint("RIGHT", detailContainer, "RIGHT", -8, 0)
  notesBox:SetWidth(120)
  notesBox:SetHeight(54)
  notesBox:SetMultiLine(true)
  notesBox:SetAutoFocus(false)

  --save notes button
  local saveNotesButton = CreateFrame("Button", nil, detailContainer, "UIPanelButtonTemplate")
  saveNotesButton:SetPoint("TOPLEFT", notesBox, "BOTTOMLEFT",0, -6)
  saveNotesButton:SetSize(110, 24)
  saveNotesButton:SetText("Save Notes")
  saveNotesButton:SetScript("OnClick", function()
    SND:SaveInlineNotes(frame)
  end)

  local statusLine = detailContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  statusLine:SetPoint("TOPLEFT", saveNotesButton, "BOTTOMLEFT", 0, -8)
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

  -- Enable item link tooltips on hover
  materialsChild:SetHyperlinksEnabled(true)
  materialsChild:SetScript("OnHyperlinkEnter", function(_, link)
    GameTooltip:SetOwner(materialsChild, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  materialsChild:SetScript("OnHyperlinkLeave", function()
    GameTooltip:Hide()
  end)

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

  materialsScroll:SetPoint("BOTTOMRIGHT", actionBarTop, "TOPRIGHT", 0, 0)

  -- claim button
  local claimButton = CreateFrame("Button", nil, actionBarTop, "UIPanelButtonTemplate")
  claimButton:SetPoint("BOTTOMLEFT", 0, 0)
  claimButton:SetSize(80, 24)
  claimButton:SetText("Claim ->")
  claimButton:SetScript("OnClick", function()
    SND:ClaimSelectedRequest(frame)
  end)

  -- unclaim button
  local unclaimButton = CreateFrame("Button", nil, actionBarTop, "UIPanelButtonTemplate")
  unclaimButton:SetPoint("TOPLEFT", claimButton, "BOTTOMLEFT",0, -6)
  unclaimButton:SetSize(80, 24)
  unclaimButton:SetText("Unclaim")
  unclaimButton:SetScript("OnClick", function()
    SND:UnclaimSelectedRequest(frame)
  end)

  -- crafted button
  local craftedButton = CreateFrame("Button", nil, actionBarBottom, "UIPanelButtonTemplate")
  craftedButton:SetPoint("TOPLEFT", claimButton, "TOPRIGHT", 0, 0)
  craftedButton:SetSize(80, 24)
  craftedButton:SetText("Crafted ->")
  craftedButton:SetScript("OnClick", function()
    SND:MarkSelectedRequestCrafted(frame)
  end)

  -- delivered button
  local deliveredButton = CreateFrame("Button", nil, actionBarBottom, "UIPanelButtonTemplate")
  deliveredButton:SetPoint("TOPLEFT", craftedButton, "TOPRIGHT", 0, 0)
  deliveredButton:SetSize(80, 24)
  deliveredButton:SetText("Delivered")
  deliveredButton:SetScript("OnClick", function()
    SND:MarkSelectedRequestDelivered(frame)
  end)

  -- -- edit button
  -- local editButton = CreateFrame("Button", nil, actionBarMeta, "UIPanelButtonTemplate")
  -- editButton:SetPoint("TOPLEFT", unclaimButton, "BOTTOMLEFT",0, -6)
  -- editButton:SetSize(70, 24)
  -- editButton:SetText("Edit")
  -- editButton:SetScript("OnClick", function()
  --   SND:EditSelectedRequestNotes(frame)
  -- end)

  -- cancel button (requester only)
  local cancelButton = CreateFrame("Button", nil, actionBarMeta, "UIPanelButtonTemplate")
  cancelButton:SetPoint("TOPLEFT", unclaimButton, "BOTTOMLEFT",0, -6)
  cancelButton:SetSize(110, 24)
  cancelButton:SetText("Cancel Request")
  cancelButton:SetScript("OnClick", function()
    SND:CancelSelectedRequest(frame)
  end)

  -- delete button (moderator only)
  local deleteButton = CreateFrame("Button", nil, actionBarMeta, "UIPanelButtonTemplate")
  deleteButton:SetPoint("TOPLEFT", cancelButton, "TOPRIGHT", 6, 0)
  deleteButton:SetSize(70, 24)
  deleteButton:SetText("Delete")
  deleteButton:SetScript("OnClick", function()
    SND:DeleteSelectedRequest(frame)
  end)

  local listButtons = {}
  local requestRowHeight = 54
  local iconSize = 38
  local requestorColumnX = 48
  local itemColumnX = 170
  local statusColumnX = 356
  for i = 1, 50 do
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
    statusText:SetWidth(80)
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

  scrollChild:SetHeight(50 * (requestRowHeight + 2))

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
  frame.detailTip = detailTip
  frame.detailPreferredCrafter = detailPreferredCrafter
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
  frame.editButton = nil
  frame.cancelButton = cancelButton
  frame.deleteButton = deleteButton
  frame.saveNotesButton = saveNotesButton
  frame.selectedRequestId = nil
  frame.searchQuery = ""

  UIDropDownMenu_Initialize(professionDrop, function(dropdown, level)
    local options = SND:GetProfessionFilterOptions()
    for _, option in ipairs(options or {}) do
      local value = option
      local info = UIDropDownMenu_CreateInfo()
      info.text = value
      info.checked = value == frame.professionFilter
      info.func = function()
        frame.professionFilter = value
        SND.db.config.filters.requests.professionFilter = value
        UIDropDownMenu_SetText(professionDrop, value)
        SND:RefreshRequestList(frame)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(professionDrop, 110)
  UIDropDownMenu_SetText(professionDrop, frame.professionFilter)

  -- Status dropdown with Camel Case display labels
  -- Internal filter values remain uppercase (matching request.status)
  local statusOptions = {
    { label = "All",       value = "ALL" },
    { label = "Open",      value = "OPEN" },
    { label = "Claimed",   value = "CLAIMED" },
    { label = "Crafted",   value = "CRAFTED" },
    { label = "Delivered", value = "DELIVERED" },
    { label = "Cancelled", value = "CANCELLED" },
  }
  local statusLabelMap = {}
  for _, opt in ipairs(statusOptions) do
    statusLabelMap[opt.value] = opt.label
  end

  UIDropDownMenu_Initialize(statusDrop, function(dropdown, level)
    for _, opt in ipairs(statusOptions) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = opt.label
      info.checked = opt.value == frame.statusFilter
      info.func = function()
        frame.statusFilter = opt.value
        SND.db.config.filters.requests.statusFilter = opt.value
        UIDropDownMenu_SetText(statusDrop, opt.label)
        SND:RefreshRequestList(frame)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(statusDrop, 110)
  UIDropDownMenu_SetText(statusDrop, statusLabelMap[frame.statusFilter] or frame.statusFilter)

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
  -- Use relative positioning: ~35% of default width (448px at 1280px default)
  leftColumn:SetPoint("RIGHT", frame, "LEFT", 456, 0)

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

  local notificationsToggle = CreateFrame("CheckButton", nil, leftColumn, "UICheckButtonTemplate")
  notificationsToggle:SetPoint("TOPLEFT", minimapToggle, "BOTTOMLEFT", 0, -2)
  notificationsToggle.text:SetText("Show chat notifications")
  notificationsToggle:SetChecked(SND.db.config.showNotifications and true or false)
  notificationsToggle:SetScript("OnClick", function(btn)
    SND.db.config.showNotifications = btn:GetChecked() and true or false
  end)

  local popupToggle = CreateFrame("CheckButton", nil, leftColumn, "UICheckButtonTemplate")
  popupToggle:SetPoint("TOPLEFT", notificationsToggle, "BOTTOMLEFT", 0, -2)
  popupToggle.text:SetText("Show request popup")
  popupToggle:SetChecked(SND.db.config.showRequestPopup and true or false)
  popupToggle:SetScript("OnClick", function(btn)
    SND.db.config.showRequestPopup = btn:GetChecked() and true or false
  end)

  local priceSourceLabel = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  priceSourceLabel:SetPoint("TOPLEFT", popupToggle, "BOTTOMLEFT", 0, -10)
  priceSourceLabel:SetText("Price Source")

  local priceSourceValues = {
    { value = "auto", label = "Auto" },
    { value = "auctionator", label = "Auctionator" },
    { value = "tsm", label = "TradeSkillMaster" },
    { value = "none", label = "None" },
  }

  local priceSourceDropdown = CreateFrame("Frame", "SNDPriceSourceDropdown", leftColumn, "UIDropDownMenuTemplate")
  priceSourceDropdown:SetPoint("TOPLEFT", priceSourceLabel, "BOTTOMLEFT", -16, -2)
  frame.priceSourceDropdown = priceSourceDropdown

  local function getPriceSourceLabel(val)
    for _, entry in ipairs(priceSourceValues) do
      if entry.value == val then return entry.label end
    end
    return "Auto"
  end

  UIDropDownMenu_SetWidth(priceSourceDropdown, 140)
  UIDropDownMenu_SetText(priceSourceDropdown, getPriceSourceLabel(SND.db.config.priceSource or "auto"))
  UIDropDownMenu_Initialize(priceSourceDropdown, function(_, level)
    for _, entry in ipairs(priceSourceValues) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = entry.label
      info.value = entry.value
      info.checked = (SND.db.config.priceSource or "auto") == entry.value
      info.func = function(btn)
        SND.db.config.priceSource = btn.value
        UIDropDownMenu_SetText(priceSourceDropdown, getPriceSourceLabel(btn.value))
        CloseDropDownMenus()
        if type(SND.RefreshAllTabs) == "function" then
          SND:RefreshAllTabs()
        end
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)

  local scaleLabel = leftColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  scaleLabel:SetPoint("TOPLEFT", priceSourceDropdown, "BOTTOMLEFT", 16, -6)
  scaleLabel:SetText("UI Scale")

  local scaleSlider = CreateFrame("Slider", "SNDUIScaleSlider", leftColumn, "OptionsSliderTemplate")
  scaleSlider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 0, -8)
  scaleSlider:SetWidth(160)
  scaleSlider:SetMinMaxValues(0.5, 1.5)
  scaleSlider:SetValueStep(0.01)
  scaleSlider:SetValue(SND.db.config.uiScale or 1.0)
  scaleSlider.Low:SetText("50%")
  scaleSlider.High:SetText("150%")
  scaleSlider.Text:SetText(math.floor((SND.db.config.uiScale or 1.0) * 100 + 0.5) .. "%")
  scaleSlider:SetScript("OnValueChanged", function(_, value)
    scaleSlider.Text:SetText(math.floor(value * 100 + 0.5) .. "%")
    -- Defer SetScale by one frame so the drag handler isn't disrupted
    C_Timer.After(0, function()
      if SND.mainFrame then
        SND.mainFrame:SetScale(value)
      end
    end)
  end)
  scaleSlider:SetScript("OnMouseUp", function()
    local value = math.floor(scaleSlider:GetValue() * 20 + 0.5) / 20
    SND.db.config.uiScale = value
    scaleSlider:SetValue(value)
    if type(SND.RefreshOptions) == "function" then
      SND:RefreshOptions()
    end
  end)
  frame.scaleSlider = scaleSlider

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

  -- === Database Stats Section ===
  local dbStatsHeader = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  dbStatsHeader:SetPoint("TOPLEFT", matsSummary, "BOTTOMLEFT", 0, -6)
  dbStatsHeader:SetText("Database")

  local dbStatsText = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dbStatsText:SetPoint("TOPLEFT", dbStatsHeader, "BOTTOMLEFT", 0, -2)
  dbStatsText:SetJustifyH("LEFT")
  dbStatsText:SetText("Loading...")

  -- === Comms Stats Section ===
  local commsStatsHeader = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  commsStatsHeader:SetPoint("TOPLEFT", dbStatsText, "BOTTOMLEFT", 0, -6)
  commsStatsHeader:SetText("Comms")

  local commsStatsText = rightColumn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  commsStatsText:SetPoint("TOPLEFT", commsStatsHeader, "BOTTOMLEFT", 0, -2)
  commsStatsText:SetJustifyH("LEFT")
  commsStatsText:SetText("Loading...")

  frame.scanStatus = scanStatus
  frame.scanAlertLabel = scanAlertLabel
  frame.professionsList = professionsList
  frame.matsStatus = matsStatus
  frame.matsSummary = matsSummary
  frame.dbStatsText = dbStatsText
  frame.commsStatsText = commsStatsText

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
  tinsert(UISpecialFrames, "SNDRequestModal")
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
  modal:SetBackdropColor(0.1, 0.1, 0.1, 1)
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
      nameText:SetWidth(200)
      nameText:SetJustifyH("LEFT")

      local requiredText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      requiredText:SetPoint("LEFT", nameText, "RIGHT", 4, 0)
      requiredText:SetWidth(90)
      requiredText:SetJustifyH("LEFT")

      local priceText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      priceText:SetPoint("LEFT", requiredText, "RIGHT", 4, 0)
      priceText:SetWidth(110)
      priceText:SetJustifyH("RIGHT")

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
      row.priceText = priceText
      row.haveBox = haveBox

      row:EnableMouse(true)
      row:SetScript("OnEnter", function(thisRow)
        if thisRow.itemID then
          GameTooltip:SetOwner(thisRow, "ANCHOR_RIGHT")
          GameTooltip:SetItemByID(thisRow.itemID)
          GameTooltip:Show()
        end
      end)
      row:SetScript("OnLeave", function()
        GameTooltip:Hide()
      end)

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

    local hasAuctionData = SND:IsAuctionPriceAvailable()
    local costData = hasAuctionData and SND:GetRecipeMaterialCost(recipeSpellID, qty) or nil

    ensureMaterialRowCapacity(#list)
    modal.ownedCounts = modal.ownedCounts or {}

    for i, entry in ipairs(list) do
      local row = modal.materialRows[i]
      row.itemID = entry.itemID
      row.nameText:SetText(entry.name)
      row.requiredText:SetText(string.format("Need: %d", entry.required))

      -- Show per-material price if available
      if row.priceText then
        if costData and costData.itemCosts[entry.itemID] and costData.itemCosts[entry.itemID].totalPrice then
          row.priceText:SetText(SND:FormatPrice(costData.itemCosts[entry.itemID].totalPrice))
        else
          row.priceText:SetText(hasAuctionData and "—" or "")
        end
      end

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

    -- Calculate extra height for price summary
    local summaryLines = 0
    if costData then
      summaryLines = 2 -- separator + material cost
      local profitData = SND:GetRecipeProfitEstimate(recipeSpellID, qty)
      if profitData and profitData.outputValue then
        summaryLines = summaryLines + 1 -- output value
        if profitData.profit then
          summaryLines = summaryLines + 1 -- profit
        end
      end
    end

    if modal.materialsScrollChild then
      local contentHeight = math.max(140, (#list * 28) + (summaryLines * 20))
      modal.materialsScrollChild:SetHeight(contentHeight)
    end

    -- Update or create price summary text
    if not modal.priceSummaryText then
      if modal.materialsScrollChild then
        modal.priceSummaryText = modal.materialsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        modal.priceSummaryText:SetJustifyH("LEFT")
        modal.priceSummaryText:SetWidth(480)
      end
    end

    if modal.priceSummaryText then
      if costData then
        -- Position below the last visible material row
        local lastRow = modal.materialRows[#list]
        if lastRow then
          modal.priceSummaryText:SetPoint("TOPLEFT", lastRow, "BOTTOMLEFT", 0, -8)
        end

        local summaryParts = {}
        table.insert(summaryParts, "|cff888888-------------|r")
        local costLabel = "Material Cost: " .. SND:FormatPrice(costData.totalCost)
        if costData.incomplete then
          costLabel = costLabel .. " |cffFF8800(cost data incomplete)|r"
        end
        table.insert(summaryParts, costLabel)

        local profitData = SND:GetRecipeProfitEstimate(recipeSpellID, qty)
        if profitData and profitData.outputValue then
          table.insert(summaryParts, "Output Value: " .. SND:FormatPrice(profitData.outputValue))
          if profitData.profit then
            local profitColor = profitData.profit >= 0 and "|cff00FF00" or "|cffFF0000"
            local sign = profitData.profit >= 0 and "+" or ""
            table.insert(summaryParts, "Est. Profit: " .. profitColor .. sign .. SND:FormatPrice(profitData.profit) .. "|r")
          end
        end

        modal.priceSummaryText:SetText(table.concat(summaryParts, "\n"))
        modal.priceSummaryText:Show()
      else
        modal.priceSummaryText:SetText("")
        modal.priceSummaryText:Hide()
      end
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
        modal.selectedPreferredCrafter = crafterName
        UIDropDownMenu_SetText(modal.selectedCrafterValue, display)
      else
        modal.selectedPreferredCrafter = nil
        UIDropDownMenu_SetText(modal.selectedCrafterValue, "Any crafter")
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
  searchSection:SetHeight(48)

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

  local targetHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  targetHeader:SetPoint("TOPLEFT", searchSection, "BOTTOMLEFT", 0, -8)
  targetHeader:SetText("Requested Item")

  local targetSection = CreateFrame("Frame", nil, modal, "BackdropTemplate")
  targetSection:SetPoint("TOPLEFT", targetHeader, "BOTTOMLEFT", -4, -4)
  targetSection:SetPoint("TOPRIGHT", modal, "TOPRIGHT", -16, 0)
  targetSection:SetHeight(72)
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
  local selectedItemValueText = selectedItemValue:CreateFontString(nil, "OVERLAY", "GameFontNormalLargeOutline")
  selectedItemValueText:SetPoint("LEFT", selectedItemIcon, "RIGHT", 6, 0)
  selectedItemValueText:SetPoint("RIGHT", selectedItemValue, "RIGHT", 0, 0)
  selectedItemValueText:SetJustifyH("LEFT")
  selectedItemValueText:SetText("-")

  local inputHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  inputHeader:SetPoint("TOPLEFT", targetSection, "BOTTOMLEFT", 0, -8)
  inputHeader:SetText("Request Details")

  local selectedCrafterLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  selectedCrafterLabel:SetPoint("TOPLEFT", inputHeader, "BOTTOMLEFT", 4, -12)
  selectedCrafterLabel:SetText("Crafter")

  local selectedCrafterDrop = CreateFrame("Frame", "SNDRequestCrafterDropDown", modal, "UIDropDownMenuTemplate")
  selectedCrafterDrop:SetPoint("LEFT", selectedCrafterLabel, "RIGHT", 4, 0)
  modal.selectedPreferredCrafter = nil

  UIDropDownMenu_Initialize(selectedCrafterDrop, function(_, level, menuList)
    -- "Any crafter" option
    local anyInfo = UIDropDownMenu_CreateInfo()
    anyInfo.text = "Any crafter"
    anyInfo.checked = (modal.selectedPreferredCrafter == nil)
    anyInfo.func = function()
      modal.selectedPreferredCrafter = nil
      UIDropDownMenu_SetText(selectedCrafterDrop, "Any crafter")
    end
    UIDropDownMenu_AddButton(anyInfo, level)

    -- Populate crafters for the selected recipe
    if modal.selectedRecipeSpellID then
      local crafters = SND:GetCraftersForRecipe(modal.selectedRecipeSpellID)
      if crafters then
        for _, crafter in ipairs(crafters) do
          local info = UIDropDownMenu_CreateInfo()
          local shortName = crafter.name and crafter.name:match("^[^%-]+") or crafter.name
          local statusTag = crafter.online and "|cff00ff00Online|r" or "|cff888888Offline|r"
          info.text = string.format("%s (%s)", shortName, statusTag)
          info.checked = (modal.selectedPreferredCrafter == crafter.name)
          info.func = function()
            modal.selectedPreferredCrafter = crafter.name
            UIDropDownMenu_SetText(selectedCrafterDrop, shortName)
          end
          UIDropDownMenu_AddButton(info, level)
        end
      end
    end
  end)
  UIDropDownMenu_SetWidth(selectedCrafterDrop, 180)
  UIDropDownMenu_SetText(selectedCrafterDrop, "Any crafter")

  -- Keep a reference for compatibility (used by refreshSelectionContext)
  local selectedCrafterValue = selectedCrafterDrop

  local qtyBox = CreateFrame("EditBox", nil, modal, "InputBoxTemplate")
  qtyBox:SetSize(24, 24)
  qtyBox:SetPoint("TOPLEFT", selectedCrafterLabel, "BOTTOMLEFT", 8, -8)
  qtyBox:SetAutoFocus(false)
  qtyBox:SetText("1")
  qtyBox:SetScript("OnTextChanged", function()
    refreshMaterialRows()
  end)

  local qtyLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  qtyLabel:SetPoint("LEFT", qtyBox, "RIGHT", 4, 0)
  qtyLabel:SetText("Quantity")

  local matsStatusCheck = CreateFrame("CheckButton", nil, modal, "UICheckButtonTemplate")
  matsStatusCheck:SetPoint("TOPLEFT", qtyBox, "BOTTOMLEFT", -8, -4)
  matsStatusCheck.text:SetText("Need mats from crafter")
  matsStatusCheck:SetChecked(false)

  local tipLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  tipLabel:SetPoint("TOPLEFT", matsStatusCheck, "BOTTOMLEFT", 4, -8)
  tipLabel:SetText("Offered Tip (gold)")

  local tipBox = CreateFrame("EditBox", nil, modal, "InputBoxTemplate")
  tipBox:SetSize(80, 24)
  tipBox:SetPoint("LEFT", tipLabel, "RIGHT", 8, 0)
  tipBox:SetAutoFocus(false)
  tipBox:SetNumeric(true)

  local tipHint = modal:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  tipHint:SetPoint("LEFT", tipBox, "RIGHT", 6, 0)
  tipHint:SetText("(optional)")

  local notesLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  notesLabel:SetPoint("TOPLEFT", tipLabel, "BOTTOMLEFT", 0, -8)
  notesLabel:SetText("Notes")

  local notesBox = CreateFrame("EditBox", nil, modal, "InputBoxTemplate")
  notesBox:SetPoint("TOPLEFT", notesLabel, "BOTTOMLEFT", 0, -4)
  notesBox:SetPoint("RIGHT", modal, "RIGHT", -24, 0)
  notesBox:SetHeight(24)
  notesBox:SetAutoFocus(false)

  local matsHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  matsHeader:SetPoint("TOPLEFT", notesBox, "BOTTOMLEFT", 0, -10)
  matsHeader:SetText("Materials (Required + Owned)")

  local matsLabel = modal:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  matsLabel:SetPoint("TOPLEFT", matsHeader, "BOTTOMLEFT", 0, -4)
  matsLabel:SetText("Input how many you will send to the crafter right boxes")

  local matsScroll = CreateFrame("ScrollFrame", nil, modal, "UIPanelScrollFrameTemplate")
  matsScroll:SetPoint("TOPLEFT", matsLabel, "BOTTOMLEFT", 0, -4)
  matsScroll:SetPoint("RIGHT", modal, "RIGHT", -36, 0)

  local matsScrollChild = CreateFrame("Frame", nil, matsScroll)
  matsScrollChild:SetPoint("TOPLEFT", 0, 0)
  matsScrollChild:SetSize(500, 140)
  matsScroll:SetScrollChild(matsScrollChild)

  local matsEmptyText = matsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  matsEmptyText:SetPoint("TOPLEFT", 2, -2)
  matsEmptyText:SetText(T("Select a recipe to see required materials."))

  local actionHeader = modal:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  actionHeader:SetPoint("BOTTOMLEFT", modal, "BOTTOMLEFT", 14, 38)
  actionHeader:SetText("Actions")

  matsScroll:SetPoint("BOTTOMRIGHT", actionHeader, "TOPRIGHT", -18, 10)

  local submit = CreateFrame("Button", nil, modal, "UIPanelButtonTemplate")
  submit:SetPoint("BOTTOM", modal, "BOTTOM", -48, 10)
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
    local offeredTip = tonumber(tipBox:GetText())
    if offeredTip and offeredTip <= 0 then offeredTip = nil end
    SND:CreateRequest(modal.selectedRecipeSpellID, qty, notes, {
      needsMats = needsMats,
      ownedCounts = ownedCounts,
      offeredTip = offeredTip and (offeredTip * 10000) or nil,
      preferredCrafter = modal.selectedPreferredCrafter,
    })
    modal:Hide()
  end)

  local cancel = CreateFrame("Button", nil, modal, "UIPanelButtonTemplate")
  cancel:SetPoint("LEFT", submit, "RIGHT", 12, 0)
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
  modal.tipBox = tipBox
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
  self.requestModal.selectedRecipeItemText = nil
  self.requestModal.selectedRecipeProfessionName = nil
  self.requestModal.selectedRecipeProfessionSkillLineID = nil
  self.requestModal.selectedRecipeOutputLink = nil
  self.requestModal.selectedCrafterName = nil
  self.requestModal.selectedCrafterOnline = nil
  self.requestModal.selectedCrafterHasSharedMats = nil
  self.requestModal.selectedCrafterProfession = nil
  self.requestModal.selectedPreferredCrafter = nil
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
    UIDropDownMenu_SetText(self.requestModal.selectedCrafterValue, "Any crafter")
  end
  self.requestModal.searchBox:SetText("")
  self.requestModal.qtyBox:SetText("1")
  if self.requestModal.tipBox then
    self.requestModal.tipBox:SetText("")
  end
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
    local recipeEntry = self.db.recipeIndex[recipeSpellID]
    self.requestModal.selectedRecipeLabel:SetText((recipeEntry and recipeEntry.name) or ("Recipe " .. recipeSpellID))
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
  if self.requestPopup and self.db.config.showRequestPopup then
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

  -- Tip text
  local tipText = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  tipText:SetPoint("TOPLEFT", requester, "BOTTOMLEFT", 0, -4)
  tipText:SetPoint("RIGHT", popup, "RIGHT", -20, 0)
  tipText:SetJustifyH("LEFT")
  tipText:SetTextColor(1, 0.84, 0)
  tipText:Hide()
  popup.tipText = tipText

  -- Preferred crafter text
  local preferredText = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  preferredText:SetPoint("TOPLEFT", tipText, "BOTTOMLEFT", 0, -2)
  preferredText:SetPoint("RIGHT", popup, "RIGHT", -20, 0)
  preferredText:SetJustifyH("LEFT")
  preferredText:Hide()
  popup.preferredText = preferredText

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
  popup:SetScript("OnUpdate", function(frame, elapsed)
    if not frame:IsShown() then
      return
    end

    frame.autoHideTime = frame.autoHideTime - elapsed
    if frame.autoHideTime <= 0 then
      frame:Hide()
    end
  end)

  -- Reset timer on show
  popup:SetScript("OnShow", function(frame)
    frame.autoHideTime = 20
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

  -- Show tip if offered
  if popup.tipText then
    if requestData.offeredTip and requestData.offeredTip > 0 then
      popup.tipText:SetText(string.format("Tip: %s", self:FormatPrice(requestData.offeredTip)))
      popup.tipText:Show()
    else
      popup.tipText:Hide()
    end
  end

  -- Show preferred crafter highlight
  if popup.preferredText then
    if requestData.preferredCrafter and requestData.preferredCrafter ~= "" then
      local localPlayerKey = self:GetPlayerKey(UnitName("player"))
      if requestData.preferredCrafter == localPlayerKey then
        popup.preferredText:SetText("|cff00ff00You are the preferred crafter!|r")
        popup.preferredText:Show()
      else
        popup.preferredText:Hide()
      end
    else
      popup.preferredText:Hide()
    end
  end

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
