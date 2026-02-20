local addonName = ...
local SND = _G[addonName]

local AceConfig = LibStub("AceConfig-3.0", true)
local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
local AceDBOptions = LibStub("AceDBOptions-3.0", true)

local function T(key, ...)
  if SND and SND.Tr then
    return SND:Tr(key, ...)
  end
  if select("#", ...) > 0 then
    return string.format(key, ...)
  end
  return key
end

local OPTIONS_APP_NAME = addonName

local function getConfig(self)
  self.db = self.db or {}
  self.db.config = self.db.config or {}
  return self.db.config
end

local function getScanLogText(self)
  if type(self.GetScanLogText) == "function" then
    return self:GetScanLogText() or ""
  end
  return ""
end

function SND:GetOptionsTable()
  local dbOptions = nil
  if AceDBOptions and self.dbRoot then
    dbOptions = AceDBOptions:GetOptionsTable(self.dbRoot)
    dbOptions.order = 99
  end

  return {
    type = "group",
    name = T("Something Need Doing?"),
    args = {
      general = {
        type = "group",
        name = T("General"),
        order = 1,
        args = {
          publishNote = {
            type = "description",
            name = T("To share your recipes with guild members, open each profession window at least once. Recipes are scanned and published when you view the profession UI."),
            order = 0,
            fontSize = "medium",
          },
          debugMode = {
            type = "toggle",
            name = T("Debug mode (logging/diagnostics only)"),
            order = 1,
            get = function()
              return getConfig(self).debugMode and true or false
            end,
            set = function(_, value)
              getConfig(self).debugMode = value and true or false
              if self.mainFrame and self.mainFrame.contentFrames then
                local requestsFrame = self.mainFrame.contentFrames[2]
                if requestsFrame and requestsFrame.selectedRequestId then
                  local request = self.db and self.db.requests and self.db.requests[requestsFrame.selectedRequestId]
                  if request and type(self.UpdateRequestActionButtons) == "function" then
                    self:UpdateRequestActionButtons(requestsFrame, request)
                  end
                end
              end
            end,
          },
          autoPublishOnLogin = {
            type = "toggle",
            name = T("Auto publish on login"),
            order = 10,
            get = function()
              return getConfig(self).autoPublishOnLogin and true or false
            end,
            set = function(_, value)
              getConfig(self).autoPublishOnLogin = value and true or false
            end,
          },
          autoPublishOnLearn = {
            type = "toggle",
            name = T("Auto publish on profession changes"),
            order = 11,
            get = function()
              return getConfig(self).autoPublishOnLearn and true or false
            end,
            set = function(_, value)
              getConfig(self).autoPublishOnLearn = value and true or false
            end,
          },
          showRequestPopup = {
            type = "toggle",
            name = T("Show request popup"),
            order = 12,
            get = function()
              return getConfig(self).showRequestPopup and true or false
            end,
            set = function(_, value)
              getConfig(self).showRequestPopup = value and true or false
            end,
          },
          uiScale = {
            type = "range",
            name = T("UI Scale"),
            order = 13,
            min = 0.5,
            max = 1.5,
            step = 0.05,
            isPercent = true,
            get = function()
              return tonumber(getConfig(self).uiScale) or 1.0
            end,
            set = function(_, value)
              value = math.floor(value * 20 + 0.5) / 20
              getConfig(self).uiScale = value
              if self.mainFrame then
                self.mainFrame:SetScale(value)
              end
              -- Sync the in-addon input box if it exists
              if self.mainFrame and self.mainFrame.contentFrames then
                local optionsFrame = self.mainFrame.contentFrames[4]
                if optionsFrame and optionsFrame.scaleInput then
                  optionsFrame.scaleInput:SetText(tostring(math.floor(value * 100 + 0.5)))
                end
              end
            end,
          },
          shareMatsOptIn = {
            type = "toggle",
            name = T("Share available crafting materials"),
            order = 20,
            get = function()
              return getConfig(self).shareMatsOptIn and true or false
            end,
            set = function(_, value)
              getConfig(self).shareMatsOptIn = value and true or false
            end,
          },
          autoPublishMats = {
            type = "toggle",
            name = T("Auto publish materials"),
            order = 21,
            get = function()
              return getConfig(self).autoPublishMats and true or false
            end,
            set = function(_, value)
              getConfig(self).autoPublishMats = value and true or false
            end,
          },
          officerRankIndex = {
            type = "range",
            name = T("Officer rank index threshold"),
            order = 30,
            min = 0,
            max = 10,
            step = 1,
            get = function()
              return tonumber(getConfig(self).officerRankIndex) or 1
            end,
            set = function(_, value)
              getConfig(self).officerRankIndex = math.floor(tonumber(value) or 1)
            end,
          },
          openMain = {
            type = "execute",
            name = T("Open main window"),
            order = 90,
            func = function()
              self:ToggleMainWindow()
            end,
          },
          resetDb = {
            type = "execute",
            name = T("Reset Database"),
            order = 91,
            confirm = true,
            confirmText = T("This clears local SND data. Continue?"),
            func = function()
              self:ResetDB()
              if self.scanner then
                self.scanner.lastScan = 0
                self.scanner.lastMatsPublish = 0
              end
              if type(self.RefreshAllTabs) == "function" then
                self:RefreshAllTabs()
              end
            end,
          },
          scanLogsHeader = {
            type = "header",
            name = T("Scan Logs"),
            order = 92,
          },
          scanLogsCopy = {
            type = "execute",
            name = T("Copy Logs"),
            order = 93,
            func = function()
              if type(self.OpenScanLogCopyBox) == "function" then
                self:OpenScanLogCopyBox()
              end
            end,
          },
          scanLogsClear = {
            type = "execute",
            name = T("Clear Logs"),
            order = 94,
            func = function()
              if type(self.ClearScanLogBuffer) == "function" then
                self:ClearScanLogBuffer()
              end
              if self.scanLogCopyEditBox then
                self.scanLogCopyEditBox:SetText("")
              end
            end,
          },
          scanLogsView = {
            type = "input",
            name = T("Log Window"),
            order = 95,
            multiline = 18,
            width = "full",
            get = function()
              return getScanLogText(self)
            end,
            set = function()
            end,
          },
        },
      },
      profiles = dbOptions,
    },
  }
end

function SND:InitOptions()
  if self._optionsInitialized then
    return
  end
  self._optionsInitialized = true
  if not (AceConfig and AceConfigDialog) then
    return
  end

  AceConfig:RegisterOptionsTable(OPTIONS_APP_NAME, function()
    return self:GetOptionsTable()
  end)
  self.optionsCategoryId = AceConfigDialog:AddToBlizOptions(OPTIONS_APP_NAME, T("Something Need Doing?"))
end

function SND:OpenOptions()
  if AceConfigDialog then
    AceConfigDialog:Open(OPTIONS_APP_NAME)
  end
end

function SND:RefreshOptions()
  if AceConfigRegistry then
    AceConfigRegistry:NotifyChange(OPTIONS_APP_NAME)
  end
end
