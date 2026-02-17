std = "lua51"
max_line_length = false

exclude_files = {
  "libs/",
  "dist/",
}

-- Allow writing to _G (addon pattern: _G[addonName] = SND, then SND:Method())
globals = {
  "_G",
  "SomethingNeedDoing",
  "SomethingNeedDoingDB",
  "StaticPopupDialogs",
}

read_globals = {
  -- Lua globals added by WoW
  "wipe",
  "date",
  "time",
  "strsplit",
  "strtrim",
  "tinsert",
  "tremove",
  "format",

  -- WoW API: General
  "CreateFrame",
  "GetAddOnMetadata",
  "GetRealmName",
  "GetServerTime",
  "GetSpellLink",
  "GetSpellInfo",
  "GetItemInfo",
  "GetItemIcon",
  "GetItemCount",
  "InCombatLockdown",
  "UnitFactionGroup",
  "UnitIsGuildLeader",
  "UnitName",
  "UnitGUID",
  "ChatFrame_OpenChat",
  "ChatFrame_SendTell",
  "HandleModifiedItemClick",

  -- WoW API: Guild
  "IsInGuild",
  "GetGuildInfo",
  "GetGuildRosterInfo",
  "GetNumGuildMembers",
  "GuildRoster",

  -- WoW API: Professions
  "GetProfessions",
  "GetProfessionInfo",

  -- WoW API: Classic TradeSkill
  "GetTradeSkillLine",
  "GetNumTradeSkills",
  "GetTradeSkillInfo",
  "GetTradeSkillRecipeLink",
  "GetTradeSkillItemLink",
  "GetTradeSkillNumReagents",
  "GetTradeSkillReagentInfo",
  "GetTradeSkillReagentItemLink",
  "GetTradeSkillTools",
  "ExpandTradeSkillSubClass",
  "CloseTradeSkill",

  -- WoW API: Classic Craft (enchanting, etc.)
  "GetNumCrafts",
  "GetCraftInfo",
  "GetCraftItemLink",
  "GetCraftReagentInfo",
  "GetCraftReagentItemLink",
  "GetCraftDisplaySkillLine",
  "GetCraftSpellFocus",

  -- C_ namespaces
  "C_AddOns",
  "C_GuildInfo",
  "C_Timer",
  "C_TradeSkillUI",

  -- UI framework
  "UIParent",
  "GameTooltip",
  "DEFAULT_CHAT_FRAME",
  "BackdropTemplateMixin",
  "BackdropTemplate",
  "ITEM_QUALITY_COLORS",
  "ChatFontNormal",
  "UISpecialFrames",
  "StaticPopup_Show",

  -- UIDropDownMenu
  "UIDropDownMenu_Initialize",
  "UIDropDownMenu_CreateInfo",
  "UIDropDownMenu_SetText",
  "UIDropDownMenu_SetWidth",
  "UIDropDownMenu_AddButton",
  "CloseDropDownMenus",

  -- Panel templates
  "PanelTemplates_SetNumTabs",
  "PanelTemplates_SetTab",

  -- Libraries
  "LibStub",

  -- Optional addon APIs (checked at runtime before use)
  "Auctionator",
  "Atr_GetAuctionBuyout",
  "TSM_API",
}

-- Ignore unused self in methods (common in Ace3 callbacks)
self = false

-- Ignore unused arguments prefixed with _ or common callback args
ignore = {
  "21./_.*",       -- unused arguments starting with _
  "212",           -- unused argument (applies to known callback patterns)
}
