# Feature Requests - Request Workflow Improvements

**Date**: 2026-02-13 to 2026-02-14
**Status**: Partially Complete (4/5 features implemented)
**Priority**: High

---

## Implementation Status

✅ **Feature 1: Delivery Notifications** - Completed 2026-02-14
✅ **Feature 2: Smart Request Popups** - Completed 2026-02-14
✅ **Feature 3: Directional Workflow** - Completed 2026-02-14
❌ **Feature 4: Guild Profession Roster** - Pending
✅ **Feature 5: Resizable Window** - Completed 2026-02-14

**Additional Improvements:**
- ✅ Fixed duplicate "All" in profession filter
- ✅ Fixed real-time request status synchronization
- ✅ Added advanced directory sorting (A-Z, Z-A, Rarity, Level)

---

## Overview

Improve the request workflow to provide clearer state transitions, better notifications, and more intuitive user interactions. Focus on making the crafter-requestor communication more seamless and preventing workflow confusion.

---

## Feature 1: Delivery Notification to Requestor ✅ COMPLETED

### Current Behavior
- Crafter marks request as "delivered"
- Requestor has no immediate notification
- Must manually check request list to see status change

### Requested Behavior
- When crafter clicks "Mark Delivered" → send notification to requestor
- Notification format: `"[Crafter] has delivered your request: [Item]"`
- Only show if requestor has notifications enabled
- Never show during combat

### Implementation Notes
```lua
-- In MarkSelectedRequestDelivered():
-- After updating request.status = "delivered"
-- Send notification message:
local message = {
  type = "REQ_DELIVERED",
  requestId = requestId,
  crafterName = currentPlayer,
  recipeName = recipeName
}
self:SendAddonMessage(serialize(message), "WHISPER", requesterName)
```

### Edge Cases
- Requestor offline: Message queued, delivered on next login
- Multiple crafters: Only the claimer can deliver
- Requestor notifications disabled: No message (respect settings)

---

## Feature 2: Smart Request Popups with Quick Claim ✅ COMPLETED

### Current Behavior
- Popup shows for ALL guild members when request created
- Says "You can craft this!" even if you can't
- No quick action - must open UI to claim

### Requested Behavior Part A: Filter by Capability
**Only show popup to players who can actually craft the item**

Algorithm:
```lua
-- In HandleRequestEnvelope() when new request received:
local canCraft = false
local localPlayer = self.db.players[localPlayerKey]

if localPlayer and localPlayer.professions then
  for _, prof in pairs(localPlayer.professions) do
    if prof.recipes and prof.recipes[request.recipeSpellID] then
      canCraft = true
      break
    end
  end
end

-- Only show popup if canCraft == true
if canCraft and showNotifications and not InCombatLockdown() then
  self:Print(notification)
end
```

### Requested Behavior Part B: Quick Claim Button
**Add "Craft" button to popup that auto-claims the request**

Implementation:
```lua
-- Option 1: Use StaticPopup with buttons
StaticPopupDialogs["SND_NEW_REQUEST_QUICK_CLAIM"] = {
  text = "New craft request from %s:\n%s\n\nClaim this request?",
  button1 = "Claim & Craft",
  button2 = "Later",
  OnAccept = function(self, data)
    -- Auto-claim the request
    SND:ClaimRequest(data.requestId)
    -- Open request UI to show details
    SND:ToggleMainWindow()
    SND:SelectRequestTab()
  end,
  timeout = 30,
  whileDead = false,
  hideOnEscape = true,
}

-- Option 2: Enhanced chat message with clickable link
-- "[New Request] |cffffd700[Item]|r from |cff00ff00Player|r - |cff00ccff[Claim]|r"
-- Click [Claim] link to auto-claim request
```

### Edge Cases
- Request already claimed by someone else: Show error, don't claim
- Multiple requests: Queue popups, show one at a time
- Combat: Queue popup, show after combat ends

---

## Feature 3: Directional Workflow & Smart Button States ✅ COMPLETED

### Current Issues
- Workflow unclear
- Buttons sometimes enabled when they shouldn't be
- Anyone can move requests to any state
- Confusing who can do what

### Requested Workflow

```
[OPEN/REQUESTED]
    ↓ (any crafter can claim)
[CLAIMED]
    ↓ (only claimer can craft)
[CRAFTED]
    ↓ (only claimer can deliver)
[DELIVERED]

Special actions:
- CANCEL: Only requestor, from any state → request deleted
- UNCLAIM: Only claimer, from CLAIMED/CRAFTED → back to OPEN
```

### State Transition Rules

| Current State | Available Actions | Who Can Act | Next State |
|---------------|-------------------|-------------|------------|
| OPEN/REQUESTED | Claim | Any crafter who knows recipe | CLAIMED |
| OPEN/REQUESTED | Cancel | Requestor only | [deleted] |
| CLAIMED | Unclaim | Claimer only | OPEN |
| CLAIMED | Mark Crafted | Claimer only | CRAFTED |
| CLAIMED | Cancel | Requestor only | [deleted] |
| CRAFTED | Unclaim | Claimer only | OPEN |
| CRAFTED | Mark Delivered | Claimer only | DELIVERED |
| CRAFTED | Cancel | Requestor only | [deleted] |
| DELIVERED | Cancel | Requestor only | [deleted] |

### Button State Logic

```lua
function SND:UpdateRequestActionButtons(requestsFrame, request)
  local currentPlayer = self:GetPlayerKey(UnitName("player"))
  local isRequester = (currentPlayer == request.requesterKey)
  local isClaimer = (currentPlayer == request.claimerKey)
  local canCraft = self:PlayerKnowsRecipe(currentPlayer, request.recipeSpellID)

  -- Claim button
  claimButton:SetEnabled(
    request.status == "open" and
    canCraft and
    not isClaimer
  )

  -- Unclaim button
  unclaimButton:SetEnabled(
    (request.status == "claimed" or request.status == "crafted") and
    isClaimer
  )

  -- Mark Crafted button
  markCraftedButton:SetEnabled(
    request.status == "claimed" and
    isClaimer
  )

  -- Mark Delivered button
  markDeliveredButton:SetEnabled(
    request.status == "crafted" and
    isClaimer
  )

  -- Cancel button
  cancelButton:SetEnabled(isRequester)

  -- Delete button (officers only)
  deleteButton:SetEnabled(self:IsOfficer())
end
```

### UI Improvements

**Visual State Indicators:**
```lua
-- Status badge colors
local statusColors = {
  open = {0.7, 0.7, 0.7},      -- Gray
  claimed = {1.0, 0.8, 0.0},   -- Gold
  crafted = {0.0, 0.8, 1.0},   -- Blue
  delivered = {0.0, 1.0, 0.0}, -- Green
}

-- Workflow visualization in request details
local workflowText = [[
Workflow:
  [OPEN] → Claim → [CLAIMED] → Craft → [CRAFTED] → Deliver → [DELIVERED]

Current: %s
Next: %s
]]
```

**Button Labels:**
- "Claim Request" (when open, you can craft)
- "Unclaim" (when claimed by you)
- "Mark as Crafted" (when claimed by you)
- "Mark as Delivered" (when crafted by you)
- "Cancel Request" (when you're the requestor)

---

## Implementation Plan

### Phase 1: Foundation (30 min)
1. Add `PlayerKnowsRecipe()` helper function
2. Add request state validation functions
3. Update `CanClaimRequest()`, `CanUnclaimRequest()`, etc. with new rules

### Phase 2: Button State Logic (45 min)
1. Refactor `UpdateRequestActionButtons()` with new state logic
2. Add visual state indicators (colors, workflow text)
3. Update button labels for clarity
4. Test all state transitions

### Phase 3: Delivery Notifications (30 min)
1. Add `REQ_DELIVERED` message type to comms
2. Implement notification sending in `MarkSelectedRequestDelivered()`
3. Add message handler in comms
4. Test with notifications enabled/disabled

### Phase 4: Smart Popups (1 hour)
1. Update `HandleRequestEnvelope()` to check `canCraft` before showing
2. Design popup UI (StaticPopup vs custom frame)
3. Implement quick claim action
4. Add combat queuing for popups
5. Test popup timing and claiming

### Phase 5: Testing & Polish (45 min)
1. Test full workflow: open → claimed → crafted → delivered
2. Test unclaim at each stage
3. Test cancel permissions
4. Test edge cases (already claimed, combat, offline players)
5. Update documentation

**Total Estimated Time:** 3-4 hours

---

## Technical Considerations

### Data Model Changes
**No database schema changes required** - existing fields support this:
- `request.status`: "open", "claimed", "crafted", "delivered"
- `request.claimerKey`: Who claimed it
- `request.requesterKey`: Who requested it

### Network Protocol
Add new message type:
```lua
REQ_DELIVERED = {
  type = "REQ_DELIVERED",
  requestId = string,
  crafterName = string,
  recipeName = string,
  timestamp = number
}
```

### Backward Compatibility
- Older clients: Ignore new message types (graceful degradation)
- State transitions: Work with current data model
- No breaking changes to existing requests

---

## Success Criteria

✅ Crafters only see popups for items they can craft
✅ Quick claim button works from popup
✅ Requestor gets notification when item delivered
✅ Workflow is clear and intuitive
✅ Buttons only enabled when action is valid
✅ Only claimer can progress their claimed request
✅ Only requestor can cancel
✅ All state transitions work correctly
✅ No regressions in existing functionality

---

## Feature 4: Guild Profession Roster View

### Current Behavior
- Can only see professions when searching for specific recipes
- No way to browse all guild members and their profession levels
- Difficult to answer questions like "Who has max Blacksmithing?"

### Requested Behavior
**New tab: "Guild Roster" showing all members with addon**

Table columns:
1. **Name** - Guild member name (click to whisper)
2. **Status** - Online/Offline indicator
3. **Professions** - List of professions with skill levels
4. **Last Seen** - When they were last online/scanned

Example display:
```
Name          Status    Professions                    Last Seen
─────────────────────────────────────────────────────────────────
Aeryn         ● Online  Blacksmithing 300/300          Now
                        Engineering 275/300
Roeyn         ○ Offline Alchemy 300/300                2h ago
                        Herbalism 300/300
PlayerName    ● Online  Tailoring 150/300              Now
```

### Features
- **Sortable columns**: Click column header to sort
- **Search/filter**: Search by name or profession
- **Profession filter**: Show only members with specific profession
- **Skill level filter**: "Max level only" checkbox
- **Export**: Copy to clipboard for sharing

### UI Design
```
┌──────────────────────────────────────────────────┐
│ Guild Roster                         [Refresh]   │
├──────────────────────────────────────────────────┤
│ Search: [____________]  Profession: [All ▼]      │
│ ☑ Show online only  ☑ Max level only            │
├──────────────────────────────────────────────────┤
│ Name ▲    Status    Professions         Last Seen│
│ ───────────────────────────────────────────────  │
│ Aeryn     ● Online  Blacksmithing 300   Now      │
│                     Engineering 275               │
│ Roeyn     ○ Offline Alchemy 300         2h ago   │
│ ...                                               │
└──────────────────────────────────────────────────┘
```

### Implementation Notes
- Add 4th tab to main window
- Reuse existing data from `self.db.players`
- Sortable table widget (similar to request list)
- Auto-refresh when guild roster updates
- Show member count: "Showing 45/120 guild members"

### Data Available
All data already exists in database:
```lua
for playerName, player in pairs(self.db.players) do
  -- player.online (boolean)
  -- player.professions (table)
  --   profession.name (string)
  --   profession.rank (number)
  --   profession.maxRank (number)
  -- player.lastSeen (timestamp)
end
```

### Priority
Medium - Nice to have, not critical

---

## Feature 5: Resizable Main Window ✅ COMPLETED

### Current Behavior
- Main window is fixed size
- Cannot resize to see more content
- Sections may be cramped on different screen resolutions
- No way to customize layout to personal preference

### Requested Behavior
**Make main window resizable while maintaining readable sections**

Requirements:
1. **Resize handles** on corners and edges
2. **Minimum size** - prevent shrinking below usable dimensions
3. **Maximum size** - reasonable upper bound for UI scaling
4. **Proportional scaling** - sections resize intelligently
5. **Persist size** - remember window size between sessions

### UI Behavior

**Resize Handles:**
- Bottom-right corner: Primary resize grip (visible)
- All edges: Drag to resize in that direction
- Corners: Drag to resize both dimensions

**Layout Rules:**
```
┌─────────────────────────────────────┐
│ [Tab1] [Tab2] [Tab3] [Tab4]   [X]  │ ← Fixed height header
├─────────────────────┬───────────────┤
│                     │               │
│  Left Pane          │  Right Pane   │ ← Proportional split
│  (Lists/Search)     │  (Details)    │    (60/40 or 50/50)
│                     │               │
│  Grows vertically   │  Grows both   │
│                     │               │
└─────────────────────┴───────────────┘
```

**Scaling Behavior by Tab:**

**Directory Tab:**
- Recipe list: Grows vertically, fixed columns
- Detail pane: Grows both directions
- Crafter list: Grows vertically
- Material list: Grows vertically with scrolling

**Requests Tab:**
- Request list: Grows vertically
- Detail pane: Grows both directions
- Notes box: Grows vertically

**Me Tab:**
- Scan log: Grows both directions (main use case)
- Status labels: Fixed size

**Guild Roster Tab (if added):**
- Member table: Grows both directions
- More columns visible at larger sizes

### Implementation

**Step 1: Make frame resizable**
```lua
local mainFrame = CreateFrame("Frame", "SNDMainFrame", UIParent, "BackdropTemplate")
mainFrame:SetResizable(true)
mainFrame:SetMinResize(600, 400)  -- Minimum usable size
mainFrame:SetMaxResize(1200, 900) -- Maximum reasonable size
```

**Step 2: Add resize grip**
```lua
local resizeButton = CreateFrame("Button", nil, mainFrame)
resizeButton:SetSize(16, 16)
resizeButton:SetPoint("BOTTOMRIGHT", -6, 6)
resizeButton:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeButton:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeButton:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

resizeButton:SetScript("OnMouseDown", function(self)
  mainFrame:StartSizing("BOTTOMRIGHT")
end)

resizeButton:SetScript("OnMouseUp", function(self)
  mainFrame:StopMovingOrSizing()
  SND:SaveWindowSize()
end)
```

**Step 3: Update child element anchors**
```lua
-- Use relative positioning instead of fixed offsets
leftPane:SetPoint("TOPLEFT", 10, -40)
leftPane:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOM", -5, 10)

rightPane:SetPoint("TOPLEFT", mainFrame, "TOP", 5, -40)
rightPane:SetPoint("BOTTOMRIGHT", -10, 10)
```

**Step 4: Persist window size**
```lua
function SND:SaveWindowSize()
  local width, height = mainFrame:GetSize()
  self.db.config.windowWidth = width
  self.db.config.windowHeight = height
end

function SND:RestoreWindowSize()
  local width = self.db.config.windowWidth or 800
  local height = self.db.config.windowHeight or 600
  mainFrame:SetSize(width, height)
end
```

### Edge Cases

**Minimum Size Constraints:**
- Directory: 600x400 (enough for lists + details)
- Requests: 650x450 (enough for request details)
- Me: 500x350 (enough for scan log)
- Guild Roster: 700x400 (enough for table columns)

**Maximum Size:**
- Cap at 1200x900 to prevent excessive screen coverage
- Still allows dual-monitor setups

**Aspect Ratio:**
- Don't enforce strict ratio
- Allow users to prefer tall/wide layouts

**Scroll Regions:**
- All scrollable areas (lists, logs) automatically benefit
- More space = more visible rows without scrolling

### Priority
Medium-High - Quality of life improvement for all features

### Benefits
- Better scan log visibility (Me tab)
- More requests visible at once
- More recipe results visible
- Accommodates different screen resolutions
- User can customize to their preference

### Estimated Time
1-2 hours
- Make frame resizable: 30 min
- Update all child anchors: 45 min
- Add resize grips: 15 min
- Persist/restore size: 15 min
- Test all tabs: 15 min

---

## Future Enhancements (Out of Scope)

- Request expiration (auto-cancel after X days)
- Request priority levels
- Multiple item requests (batch crafting)
- Material tracking (show what requestor has provided)
- Crafting queue (order multiple requests)
- Guild profession statistics (charts/graphs)
- Profession progression tracking over time

---

## User Decisions (2026-02-13)

1. ✅ **Popup style**: Custom frame with buttons
2. ✅ **Delivery notification**: Chat message only (no popup)
3. ✅ **Quick claim shortcut**: No Alt+Click (keep it simple)
4. ✅ **Unclaim confirmation**: Yes, show confirmation dialog
5. ✅ **Workflow display**: Embedded in request details

---

## Implementation Details

### Custom Request Popup Frame
```lua
-- Create custom frame for new request notifications
local popup = CreateFrame("Frame", "SNDRequestPopup", UIParent, "BackdropTemplate")
popup:SetSize(350, 140)
popup:SetPoint("TOP", 0, -200)
popup:SetFrameStrata("DIALOG")

-- Title: "New Craft Request"
-- Item icon + name (clickable item link)
-- Requester name
-- Two buttons: "Claim & Craft" and "Dismiss"
-- Auto-hide after 20 seconds
```

### Unclaim Confirmation Dialog
```lua
StaticPopupDialogs["SND_CONFIRM_UNCLAIM"] = {
  text = "Unclaim this request?\n\nIt will return to the open pool for other crafters.",
  button1 = "Unclaim",
  button2 = "Cancel",
  OnAccept = function(self, requestId)
    SND:UnclaimRequest(requestId)
  end,
  timeout = 0,
  whileDead = false,
  hideOnEscape = true,
}
```

### Workflow Display in Request Details
```lua
-- Add to request detail pane:
local workflowLabel = CreateFontString(...)
workflowLabel:SetText([[
Workflow: OPEN → CLAIMED → CRAFTED → DELIVERED
Current: CLAIMED (you)
Next: Mark as Crafted
]])
```

---

## Notes

- All changes must respect combat protection (no interruptions)
- All notifications must respect `showNotifications` option
- Maintain backward compatibility with existing requests
- Keep UI simple and intuitive
- Focus on reducing clicks for common actions
