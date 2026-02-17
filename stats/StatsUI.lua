local addonName = ...
local SND = _G[addonName]

-- ============================================================================
-- Stats Tab Creation
-- ============================================================================

function SND:CreateStatsTab(parent)
  local frame = self:CreateContentFrame(parent)
  self.statsTabFrame = frame

  -- ========================================================================
  -- Left Panel: Leaderboard
  -- ========================================================================

  local leftPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  leftPanel:SetPoint("TOPLEFT", 8, -12)
  leftPanel:SetPoint("BOTTOMLEFT", 8, 12)
  leftPanel:SetPoint("RIGHT", frame, "LEFT", 540, 0)
  leftPanel:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  leftPanel:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local leaderboardTitle = leftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  leaderboardTitle:SetPoint("TOPLEFT", 12, -12)
  leaderboardTitle:SetText("Leaderboard")

  -- Period selector buttons
  local periodBar = CreateFrame("Frame", nil, leftPanel)
  periodBar:SetPoint("TOPLEFT", leaderboardTitle, "BOTTOMLEFT", 0, -8)
  periodBar:SetSize(400, 24)

  local periods = {
    { label = "All-time", value = "total" },
    { label = "Monthly",  value = "monthly" },
    { label = "Weekly",   value = "weekly" },
  }

  frame.selectedPeriod = "total"
  local periodButtons = {}

  for i, p in ipairs(periods) do
    local btn = CreateFrame("Button", nil, periodBar, "UIPanelButtonTemplate")
    btn:SetSize(90, 22)
    if i == 1 then
      btn:SetPoint("LEFT", 0, 0)
    else
      btn:SetPoint("LEFT", periodButtons[i - 1], "RIGHT", 4, 0)
    end
    btn:SetText(p.label)
    btn.periodValue = p.value
    btn:SetScript("OnClick", function()
      frame.selectedPeriod = p.value
      for _, other in ipairs(periodButtons) do
        if other.periodValue == p.value then
          other:LockHighlight()
        else
          other:UnlockHighlight()
        end
      end
      SND:RefreshStatsTab(frame)
    end)
    if p.value == "total" then
      btn:LockHighlight()
    end
    periodButtons[i] = btn
  end
  frame.periodButtons = periodButtons

  -- Profession filter dropdown
  local profLabel = leftPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  profLabel:SetPoint("TOPLEFT", periodBar, "BOTTOMLEFT", 0, -8)
  profLabel:SetText("Profession:")

  local profDrop = CreateFrame("Frame", "SNDStatsProfessionDropDown", leftPanel, "UIDropDownMenuTemplate")
  profDrop:SetPoint("LEFT", profLabel, "RIGHT", -8, -2)

  frame.professionFilter = "All"

  UIDropDownMenu_Initialize(profDrop, function(dropdown, level)
    local options = SND:GetProfessionFilterOptions()
    for _, option in ipairs(options) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = option
      info.checked = option == frame.professionFilter
      info.func = function()
        frame.professionFilter = option
        UIDropDownMenu_SetText(profDrop, option)
        SND:RefreshStatsTab(frame)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  UIDropDownMenu_SetWidth(profDrop, 130)
  UIDropDownMenu_SetText(profDrop, "All")

  -- Leaderboard scroll area
  local leaderScrollFrame = CreateFrame("ScrollFrame", "SNDStatsLeaderScrollFrame", leftPanel, "UIPanelScrollFrameTemplate")
  leaderScrollFrame:SetPoint("TOPLEFT", profLabel, "BOTTOMLEFT", 0, -8)
  leaderScrollFrame:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -26, 100)

  local leaderScrollChild = CreateFrame("Frame", nil, leaderScrollFrame)
  leaderScrollChild:SetSize(480, 400)
  leaderScrollFrame:SetScrollChild(leaderScrollChild)

  -- Column headers
  local rankHeader = leaderScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  rankHeader:SetPoint("TOPLEFT", 4, 0)
  rankHeader:SetWidth(30)
  rankHeader:SetJustifyH("LEFT")
  rankHeader:SetText("#")

  local nameHeader = leaderScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  nameHeader:SetPoint("LEFT", rankHeader, "RIGHT", 4, 0)
  nameHeader:SetWidth(200)
  nameHeader:SetJustifyH("LEFT")
  nameHeader:SetText("Crafter")

  local countHeader = leaderScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  countHeader:SetPoint("LEFT", nameHeader, "RIGHT", 4, 0)
  countHeader:SetWidth(80)
  countHeader:SetJustifyH("RIGHT")
  countHeader:SetText("Crafts")

  -- Leaderboard rows
  local leaderRows = {}
  local leaderRowHeight = 22
  for i = 1, 50 do
    local row = CreateFrame("Frame", nil, leaderScrollChild)
    row:SetHeight(leaderRowHeight)
    row:SetPoint("TOPLEFT", 0, -(i * leaderRowHeight))
    row:SetPoint("RIGHT", leaderScrollChild, "RIGHT", -4, 0)

    local rankText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rankText:SetPoint("LEFT", 4, 0)
    rankText:SetWidth(30)
    rankText:SetJustifyH("LEFT")

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameText:SetPoint("LEFT", rankText, "RIGHT", 4, 0)
    nameText:SetWidth(200)
    nameText:SetJustifyH("LEFT")

    local countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    countText:SetPoint("LEFT", nameText, "RIGHT", 4, 0)
    countText:SetWidth(80)
    countText:SetJustifyH("RIGHT")

    row.rankText = rankText
    row.nameText = nameText
    row.countText = countText
    row:Hide()
    leaderRows[i] = row
  end
  frame.leaderRows = leaderRows
  frame.leaderScrollChild = leaderScrollChild
  frame.leaderRowHeight = leaderRowHeight

  -- Personal summary at bottom of left panel
  local summaryBg = CreateFrame("Frame", nil, leftPanel, "BackdropTemplate")
  summaryBg:SetPoint("BOTTOMLEFT", 4, 4)
  summaryBg:SetPoint("BOTTOMRIGHT", -4, 4)
  summaryBg:SetHeight(90)
  summaryBg:SetBackdrop({
    bgFile = "Interface/Buttons/WHITE8x8",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 8,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  summaryBg:SetBackdropColor(0.12, 0.1, 0.06, 1)

  local summaryTitle = summaryBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  summaryTitle:SetPoint("TOPLEFT", 8, -8)
  summaryTitle:SetText("Your Stats")

  local summaryText = summaryBg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  summaryText:SetPoint("TOPLEFT", summaryTitle, "BOTTOMLEFT", 0, -4)
  summaryText:SetPoint("RIGHT", summaryBg, "RIGHT", -8, 0)
  summaryText:SetJustifyH("LEFT")
  summaryText:SetJustifyV("TOP")
  summaryText:SetWordWrap(true)
  summaryText:SetText("")

  frame.summaryText = summaryText

  -- ========================================================================
  -- Right Panel: History
  -- ========================================================================

  local rightPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 8, 0)
  rightPanel:SetPoint("BOTTOMRIGHT", -8, 12)
  rightPanel:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  rightPanel:SetBackdropColor(0.08, 0.06, 0.03, 1)

  local historyTitle = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  historyTitle:SetPoint("TOPLEFT", 12, -12)
  historyTitle:SetText("Craft History")

  -- Search box
  local searchBox = CreateFrame("EditBox", "SNDStatsSearchBox", rightPanel, "InputBoxTemplate")
  searchBox:SetPoint("TOPLEFT", historyTitle, "BOTTOMLEFT", 4, -8)
  searchBox:SetSize(200, 22)
  searchBox:SetAutoFocus(false)
  searchBox:SetScript("OnTextChanged", function()
    SND:Debounce("statsSearch", 0.3, function()
      SND:RefreshStatsHistory(frame)
    end)
  end)
  searchBox:SetScript("OnEscapePressed", function(box)
    box:ClearFocus()
  end)

  local searchLabel = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  searchLabel:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
  searchLabel:SetText("Search by name or item")
  searchLabel:SetTextColor(0.5, 0.5, 0.5)

  frame.historySearchBox = searchBox

  -- History column headers
  local historyHeaderBar = CreateFrame("Frame", nil, rightPanel)
  historyHeaderBar:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -4, -8)
  historyHeaderBar:SetPoint("RIGHT", rightPanel, "RIGHT", -28, 0)
  historyHeaderBar:SetHeight(18)

  local dateColWidth = 70
  local crafterColWidth = 100
  local itemColWidth = 220
  local forColWidth = 100

  local dateHeader = historyHeaderBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  dateHeader:SetPoint("LEFT", 4, 0)
  dateHeader:SetWidth(dateColWidth)
  dateHeader:SetJustifyH("LEFT")
  dateHeader:SetText("Date")

  local crafterHeader = historyHeaderBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  crafterHeader:SetPoint("LEFT", dateHeader, "RIGHT", 4, 0)
  crafterHeader:SetWidth(crafterColWidth)
  crafterHeader:SetJustifyH("LEFT")
  crafterHeader:SetText("Crafter")

  local itemHeader = historyHeaderBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  itemHeader:SetPoint("LEFT", crafterHeader, "RIGHT", 4, 0)
  itemHeader:SetWidth(itemColWidth)
  itemHeader:SetJustifyH("LEFT")
  itemHeader:SetText("Item")

  local forHeader = historyHeaderBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  forHeader:SetPoint("LEFT", itemHeader, "RIGHT", 4, 0)
  forHeader:SetWidth(forColWidth)
  forHeader:SetJustifyH("LEFT")
  forHeader:SetText("For")

  -- History scroll area
  local historyScrollFrame = CreateFrame("ScrollFrame", "SNDStatsHistoryScrollFrame", rightPanel, "UIPanelScrollFrameTemplate")
  historyScrollFrame:SetPoint("TOPLEFT", historyHeaderBar, "BOTTOMLEFT", 0, -4)
  historyScrollFrame:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", -26, 8)

  local historyScrollChild = CreateFrame("Frame", nil, historyScrollFrame)
  historyScrollChild:SetSize(600, 400)
  historyScrollFrame:SetScrollChild(historyScrollChild)

  -- History rows
  local historyRows = {}
  local historyRowHeight = 24
  for i = 1, 100 do
    local row = CreateFrame("Button", nil, historyScrollChild)
    row:SetHeight(historyRowHeight)
    if i == 1 then
      row:SetPoint("TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", historyRows[i - 1], "BOTTOMLEFT", 0, 0)
    end
    row:SetPoint("RIGHT", historyScrollChild, "RIGHT", -4, 0)

    local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dateText:SetPoint("LEFT", 4, 0)
    dateText:SetWidth(dateColWidth)
    dateText:SetJustifyH("LEFT")

    local crafterText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    crafterText:SetPoint("LEFT", dateText, "RIGHT", 4, 0)
    crafterText:SetWidth(crafterColWidth)
    crafterText:SetJustifyH("LEFT")

    local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemText:SetPoint("LEFT", crafterText, "RIGHT", 4, 0)
    itemText:SetWidth(itemColWidth)
    itemText:SetJustifyH("LEFT")

    local forText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    forText:SetPoint("LEFT", itemText, "RIGHT", 4, 0)
    forText:SetWidth(forColWidth)
    forText:SetJustifyH("LEFT")

    row.dateText = dateText
    row.crafterText = crafterText
    row.itemText = itemText
    row.forText = forText

    -- Item tooltip on hover
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
    historyRows[i] = row
  end
  frame.historyRows = historyRows
  frame.historyScrollChild = historyScrollChild
  frame.historyRowHeight = historyRowHeight

  return frame
end

-- ============================================================================
-- Stats Tab Refresh
-- ============================================================================

function SND:RefreshStatsTab(statsFrame)
  if not statsFrame then
    return
  end

  self:InvalidateStatsCache()
  self:RefreshStatsLeaderboard(statsFrame)
  self:RefreshStatsHistory(statsFrame)
  self:RefreshStatsSummary(statsFrame)
end

function SND:RefreshStatsLeaderboard(statsFrame)
  if not statsFrame or not statsFrame.leaderRows then
    return
  end

  local period = statsFrame.selectedPeriod or "total"
  local profFilter = statsFrame.professionFilter or "All"
  local leaderboard = self:GetLeaderboard(period, profFilter)
  local playerKey = self:GetPlayerKey(UnitName("player"))

  for i, row in ipairs(statsFrame.leaderRows) do
    local entry = leaderboard[i]
    if entry then
      row.rankText:SetText(tostring(entry.rank))
      row.nameText:SetText(entry.name)
      row.countText:SetText(tostring(entry.count))

      -- Highlight current player
      if entry.playerKey == playerKey then
        row.nameText:SetTextColor(0.2, 1.0, 0.2)
        row.rankText:SetTextColor(0.2, 1.0, 0.2)
        row.countText:SetTextColor(0.2, 1.0, 0.2)
      else
        row.nameText:SetTextColor(1, 1, 1)
        row.rankText:SetTextColor(1, 1, 1)
        row.countText:SetTextColor(1, 1, 1)
      end
      row:Show()
    else
      row.rankText:SetText("")
      row.nameText:SetText("")
      row.countText:SetText("")
      row:Hide()
    end
  end

  -- Update scroll child height
  local visibleCount = math.min(#leaderboard, #statsFrame.leaderRows)
  if statsFrame.leaderScrollChild and statsFrame.leaderRowHeight then
    statsFrame.leaderScrollChild:SetHeight(math.max(visibleCount + 1, 1) * statsFrame.leaderRowHeight)
  end
end

function SND:RefreshStatsHistory(statsFrame)
  if not statsFrame or not statsFrame.historyRows then
    return
  end

  local query = statsFrame.historySearchBox and statsFrame.historySearchBox:GetText() or ""
  local history = self:GetCraftHistory({ query = query })

  for i, row in ipairs(statsFrame.historyRows) do
    local entry = history[i]
    if entry then
      local dateStr = entry.deliveredAt and date("%m/%d %H:%M", entry.deliveredAt) or "-"
      local crafterShort = (entry.crafter or ""):match("^([^%-]+)") or "-"
      local requesterShort = (entry.requester or ""):match("^([^%-]+)") or "-"
      local itemName = self:GetRecipeOutputItemName(entry.recipeSpellID) or "Unknown"
      local qty = tonumber(entry.qty) or 1
      local itemDisplay = qty > 1 and string.format("%s x%d", itemName, qty) or itemName

      row.dateText:SetText(dateStr)
      row.crafterText:SetText(crafterShort)
      row.itemText:SetText(itemDisplay)
      row.forText:SetText(requesterShort)
      row.itemID = entry.itemID
      row:Show()
    else
      row.dateText:SetText("")
      row.crafterText:SetText("")
      row.itemText:SetText("")
      row.forText:SetText("")
      row.itemID = nil
      row:Hide()
    end
  end

  -- Update scroll child height
  local visibleCount = math.min(#history, #statsFrame.historyRows)
  if statsFrame.historyScrollChild and statsFrame.historyRowHeight then
    statsFrame.historyScrollChild:SetHeight(math.max(visibleCount, 1) * statsFrame.historyRowHeight)
  end
end

function SND:RefreshStatsSummary(statsFrame)
  if not statsFrame or not statsFrame.summaryText then
    return
  end

  local playerKey = self:GetPlayerKey(UnitName("player"))
  local stats = self:GetPlayerStats(playerKey)

  if not stats then
    statsFrame.summaryText:SetText("No crafting activity recorded yet.\nDeliver requests to start tracking!")
    return
  end

  local lines = {}
  table.insert(lines, string.format("Total: |cffffd700%d|r crafts  |  This Week: |cffffd700%d|r  |  This Month: |cffffd700%d|r",
    stats.total, stats.weekly, stats.monthly))

  -- Find top profession
  local topProf, topCount = nil, 0
  for profName, profStats in pairs(stats.byProfession) do
    if profStats.total > topCount then
      topProf = profName
      topCount = profStats.total
    end
  end

  if topProf then
    table.insert(lines, string.format("Top Profession: |cffffd700%s|r (%d crafts)", topProf, topCount))
  end

  statsFrame.summaryText:SetText(table.concat(lines, "\n"))
end
