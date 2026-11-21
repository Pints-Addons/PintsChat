-- Pint's Chat: a clean, dark chat box. The button column on the left is gone; its buttons live in one menu
-- (the small button at the right of the tabs). Flat text tabs: Main, Raid, Guild, Whisper, Party, Log.
-- Works on the game's own chat windows, so every chat setting, channel and filter keeps working.  /pchat
local ADDON = ...
-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local MouseIsOver = MouseIsOver or function(f, top, bottom, left, right)
	if not (f and f.IsMouseOver) then return false end
	-- (the modern client refuses to measure some frames, and may answer "secret": both count as "no")
	local ok, r = pcall(f.IsMouseOver, f, top or 0, bottom or 0, left or 0, right or 0)
	if not ok or (type(issecretvalue) == "function" and issecretvalue(r)) then return false end
	return r and true or false
end

local PC = {}
_G.PintsChat = PC
local db

local BG = { 0.02, 0.02, 0.04, 0.72 }            -- chat background
local EDGE = { 0.35, 0.30, 0.45, 0.9 }           -- thin border
local TAB_ON = { 1, 1, 1 }                       -- selected tab
local TAB_OFF = { 1, 1, 1 }                      -- other tabs (white too: the open one shows by its band)
local TAB_ALERT = { 1, 0.82, 0.2 }               -- a tab with new messages

local function Print(m) print("|cffd4a017Pint's Chat:|r " .. m) end

-- things we hide are moved under a frame that is never shown, so the game can't show them again
local hider = CreateFrame("Frame"); hider:Hide()
local menuBtnReady
local function Bury(f) if f and f.SetParent then f:SetParent(hider) end end

local function Backdrop(f, bg, edge)
	f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4]); f:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4])
end

---------------------------------------------------------------- moving, resizing and locking the boxes
-- Box 1 is the main chat (ChatFrame1 and every tab docked to it). Box 2 is our own frame; tabs moved there sit inside it.
local box2, ColorBox2, SaveBox2
local moving
local grips = {}
local function BoxOf(cf) if cf and cf.pintsBox2 and box2 then return box2 end return ChatFrame1 end
-- where a box is: its bottom-left corner and size (saved by us, so it survives reloads whatever the game does)
local function Where(f) return { f:GetLeft(), f:GetBottom(), f:GetWidth(), f:GetHeight() } end
local function PutAt(f, w)
	if not (f and w and w[1]) then return end
	f:ClearAllPoints(); f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", w[1], w[2]); f:SetSize(w[3], w[4])
end
local function SaveBox(f)
	if f == ChatFrame1 then
		if db then db.mainBox = Where(ChatFrame1) end
		if FCF_SavePositionAndDimensions then pcall(FCF_SavePositionAndDimensions, ChatFrame1) end
	elseif f == box2 and SaveBox2 then SaveBox2() end
end
function PC.RestoreMain()
	if not (db and db.mainBox) or moving == ChatFrame1 or InCombatLockdown() then return end
	PutAt(ChatFrame1, db.mainBox)
	if ChatFrame1.SetUserPlaced then pcall(ChatFrame1.SetUserPlaced, ChatFrame1, true) end
	if FCF_SavePositionAndDimensions then pcall(FCF_SavePositionAndDimensions, ChatFrame1) end
end
local function DragStart(f)
	if (db and db.locked) or not f then return end
	f:SetMovable(true); moving = f; f:StartMoving()
end
local function DragStop()
	if not moving then return end
	moving:StopMovingOrSizing(); SaveBox(moving); moving = nil
end
local function Grip(parent, getTarget)
	local g = CreateFrame("Button", nil, parent); g:SetSize(14, 14); g:SetPoint("BOTTOMRIGHT", -1, 1)
	g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	g:SetScript("OnMouseDown", function()
		if db and db.locked then return end
		local f = getTarget(); f:SetResizable(true); moving = f; f:StartSizing("BOTTOMRIGHT")
	end)
	g:SetScript("OnMouseUp", DragStop)
	g:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Drag to resize"); GameTooltip:Show() end)
	g:SetScript("OnLeave", function() GameTooltip:Hide() end)
	g:SetShown(not (db and db.locked))
	grips[#grips + 1] = g
	return g
end
local function ApplyLock() for _, g in ipairs(grips) do g:SetShown(not db.locked) end end

---------------------------------------------------------------- styling one chat window
local styled = {}
local function HideTextures(f, keep)
	for _, r in ipairs({ f:GetRegions() }) do
		if r.GetObjectType and r:GetObjectType() == "Texture" and r ~= keep then r:SetAlpha(0) end
	end
end

local function StyleTab(tab, cf)
	if not tab or tab.pintsStyled then return end
	tab.pintsStyled = true
	HideTextures(tab)
	-- dragging any tab moves its whole box (instead of pulling the tab out of the dock); locked = stays put
	tab:RegisterForDrag("LeftButton")
	tab:SetScript("OnDragStart", function() DragStart(BoxOf(cf)) end)
	tab:SetScript("OnDragStop", DragStop)
	-- right-click: our menu (move between boxes, rename, close...), with the game's own menu one click further
	local orig = tab:GetScript("OnClick")
	tab:SetScript("OnClick", function(self, button, ...)
		if button == "RightButton" and PC.ShowTabMenu and db then
			PC.ShowTabMenu(cf:GetID(), self, orig and function() orig(self, "RightButton") end)
		elseif orig then orig(self, button, ...) end
	end)
	tab.pintsOrigClick = orig
	-- the game's tab itself is kept invisible and out of the way: Pint's Chat draws the main box's tabs itself (see the
	-- tab bar below) - the game greyed out, faded and resized its own tabs, which made the names hard to read
	tab:SetAlpha(0)
	hooksecurefunc(tab, "SetAlpha", function(self, a) if a and a > 0 and not self.pintsBusy then self.pintsBusy = true; self:SetAlpha(0); self.pintsBusy = nil end end)
	tab:EnableMouse(false)
	if tab.glow then tab.glow:SetAlpha(0) end
end

local function StyleEditBox(cf)
	local eb = cf.editBox or _G[cf:GetName() .. "EditBox"]
	if not eb or eb.pintsStyled then return end
	eb.pintsStyled = true
	HideTextures(eb)
	for _, n in ipairs({ "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }) do
		local t = eb[n] or _G[eb:GetName() .. n]; if t then t:SetAlpha(0) end
	end
	local bd = CreateFrame("Frame", nil, eb, "BackdropTemplate")
	bd:SetPoint("TOPLEFT", 2, -3); bd:SetPoint("BOTTOMRIGHT", -2, 3)
	bd:SetFrameLevel(math.max(0, eb:GetFrameLevel() - 1))
	Backdrop(bd, BG, EDGE)
end

local function StyleFrame(cf)
	if not cf or styled[cf] then return end
	styled[cf] = true
	local name = cf:GetName()
	-- the button column (scroll up / down / bottom, minimise) and its frame
	Bury(cf.buttonFrame or _G[name .. "ButtonFrame"])
	-- the game's own background: fully clear, ours goes behind instead
	if FCF_SetWindowAlpha then pcall(FCF_SetWindowAlpha, cf, 0, true) end
	local bd = CreateFrame("Frame", nil, cf, "BackdropTemplate")
	bd:SetPoint("TOPLEFT", cf, "TOPLEFT", -6, 26)      -- reaches up behind the tabs
	-- the modern game's scroll bar runs down the right side: it gets its own strip inside the box (it used to sit half
	-- in, half out of the border)
	local sb = cf.ScrollBar
	local right = sb and 18 or 6
	bd:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", right, -6)
	if sb then
		local function Place()
			sb:ClearAllPoints()
			sb:SetPoint("TOPLEFT", cf, "TOPRIGHT", 5, -2)
			sb:SetPoint("BOTTOMLEFT", cf, "BOTTOMRIGHT", 5, 2)
		end
		Place()
		-- (the game lays its scroll bar out again now and then: put it back)
		if FCF_UpdateScrollbarAnchors then hooksecurefunc("FCF_UpdateScrollbarAnchors", function(f) if f == cf then Place() end end) end
		if cf.ScrollToBottomButton then Bury(cf.ScrollToBottomButton) end   -- (ours does that job: the arrow at the bottom)
	end
	cf.pintsRight = right
	bd:SetFrameLevel(math.max(0, cf:GetFrameLevel() - 1))
	Backdrop(bd, BG, EDGE)
	-- a thin line under the tabs
	local line = bd:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], 0.6); line:SetHeight(1)
	line:SetPoint("TOPLEFT", 1, -24); line:SetPoint("TOPRIGHT", -1, -24)
	cf.pintsBackdrop = bd
	-- the game puts back its own screen-edge gap (room for the old button column) whenever it re-lays the chat out:
	-- put ours straight back, so the box can sit flush against the left edge
	local clamping
	hooksecurefunc(cf, "SetClampRectInsets", function(self)
		if clamping then return end
		clamping = true; self:SetClampRectInsets(-6, self.pintsRight or 6, 26, -6); clamping = false
	end)
	-- "jump to the newest line" arrow, only while you're scrolled up
	local jump = CreateFrame("Button", nil, cf)
	jump:SetSize(20, 20); jump:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", -12, -2)
	jump:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollEnd-Up")
	jump:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollEnd-Down")
	jump:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	jump:SetScript("OnClick", function() cf:ScrollToBottom() end)
	jump:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Jump to newest"); GameTooltip:Show() end)
	jump:SetScript("OnLeave", function() GameTooltip:Hide() end)
	jump:Hide()
	cf.pintsJump = jump
	-- lines never fade away: what was said stays readable until it scrolls off (the game turns fading back on now and then)
	if cf.SetFading then
		cf:SetFading(false)
		hooksecurefunc(cf, "SetFading", function(self, on) if on then self:SetFading(false) end end)
	end
	-- a message arriving in a tab you're not looking at lights that tab up (not Log: the combat log never stops)
	if cf ~= ChatFrame2 then
		hooksecurefunc(cf, "AddMessage", function(self)
			if self.pintsBox2 or self.pintsNew or not PC.UpdateBar then return end
			if PC.SelectedTab and PC.SelectedTab() == self then return end
			self.pintsNew = true
			PC.UpdateBar()
		end)
	end
	Grip(bd, function() return BoxOf(cf) end)
	StyleTab(_G[name .. "Tab"], cf)
	StyleEditBox(cf)
	-- mouse wheel: Shift jumps to the top or bottom
	cf:EnableMouseWheel(true)
	cf:HookScript("OnMouseWheel", function(self, d)
		if IsShiftKeyDown() then if d > 0 then self:ScrollToTop() else self:ScrollToBottom() end end
	end)
	-- left-clicking a player's name opens their menu (Whisper, Invite, Who...) instead of starting a whisper
	local onLink = cf:GetScript("OnHyperlinkClick")
	if onLink then
		cf:SetScript("OnHyperlinkClick", function(self, link, text, button, ...)
			if button == "LeftButton" and db and not db.clickWhispers and not IsModifierKeyDown() and type(link) == "string"
				and (link:find("^player:") or link:find("^BNplayer:")) then
				return onLink(self, link, text, "RightButton", ...)
			end
			return onLink(self, link, text, button, ...)
		end)
	end
end

---------------------------------------------------------------- tab colours (kept up to date)
-- the main box's tabs, as the game keeps them (the list moved on newer game clients; nil if it can't be found)
local function DockFrames()
	local d = GENERAL_CHAT_DOCK
	if not d then return nil end
	if type(d.DOCKED_FRAMES) == "table" then return d.DOCKED_FRAMES end
	if FCFDock_GetChatFrames then local ok, t = pcall(FCFDock_GetChatFrames, d); if ok and type(t) == "table" then return t end end
	if d.GetChatFrames then local ok, t = pcall(d.GetChatFrames, d); if ok and type(t) == "table" then return t end end
	return nil
end
local function DockCount() local t = DockFrames(); return t and #t or 1 end
local function ColorTabs()
	if PC.UpdateBar then PC.UpdateBar() end
end
PC.ColorTabs = ColorTabs

---------------------------------------------------------------- the main box's tab bar
-- Every tab the same width, white names on dark (the open one purple, one with new messages gold). When there are
-- more tabs than fit, arrows at the ends (or the mouse wheel over the tabs) scroll to the rest.
local TAB_W, TAB_GAP, ARROW_W = 66, 3, 14
local bar, barBtns, barFirst = nil, {}, 1
-- tabs the game has saved as part of the main box, but that it didn't actually put back in it this session (seen on
-- WoW Forever: Raid, Guild, Whisper, Party and Log all saved as docked, yet only Main in the box): dock them again
local redocking
local function Redock()
	if redocking or InCombatLockdown() or not (DockFrames() and FCF_DockFrame) then return end
	local inDock = {}
	for _, cf in ipairs(DockFrames()) do inDock[cf] = true end
	local want = {}
	for id = 2, (NUM_CHAT_WINDOWS or 10) do
		local n, _, _, _, _, _, _, _, docked = GetChatWindowInfo(id)
		local cf = _G["ChatFrame" .. id]
		if cf and not inDock[cf] and not cf.pintsBox2 and not cf.isTemporary and n and n ~= "" and docked and docked ~= 0 then
			want[#want + 1] = { cf, tonumber(docked) or 99 }
		end
	end
	if #want == 0 then return end
	table.sort(want, function(x, y) return x[2] < y[2] end)
	redocking = true
	for _, w in ipairs(want) do
		local cf = w[1]
		if SetChatWindowShown then pcall(SetChatWindowShown, cf:GetID(), true) end
		pcall(FCF_DockFrame, cf, DockCount() + 1, false)
	end
	redocking = false
	if FCF_SelectDockFrame and ChatFrame1 then pcall(FCF_SelectDockFrame, ChatFrame1) end
end
PC.Redock = Redock
-- the tabs the game saved as in the main box (by their saved order), for when its own list is missing or short
local function SavedDocked()
	local want = { { ChatFrame1, 0 } }
	for id = 2, (NUM_CHAT_WINDOWS or 10) do
		local n, _, _, _, _, _, _, _, docked = GetChatWindowInfo(id)
		local cf = _G["ChatFrame" .. id]
		if cf and not cf.pintsBox2 and n and n ~= "" and docked and docked ~= 0 then want[#want + 1] = { cf, tonumber(docked) or 99 } end
	end
	table.sort(want, function(x, y) return x[2] < y[2] end)
	local out = {}
	for _, w in ipairs(want) do out[#out + 1] = w[1] end
	return out
end
local manualSel                    -- the open tab, when Pint's Chat is showing the tabs itself
-- your own order for the main box's tabs (Move left / Move right on a tab's menu), kept per character
local function TabOrder(make)
	if not db then return nil end
	local me = UnitGUID("player") or "?"
	db.tabOrder = db.tabOrder or {}
	if make and not db.tabOrder[me] then db.tabOrder[me] = {} end
	return db.tabOrder[me]
end
local function Ordered(list)
	local ord = TabOrder()
	if not ord or #ord == 0 then return list end
	local pos = {}
	for i, id in ipairs(ord) do pos[id] = i end
	local idx = {}
	for i, cf in ipairs(list) do idx[cf] = i end
	table.sort(list, function(x, y)
		local px, py = pos[x:GetID()] or (1000 + idx[x]), pos[y:GetID()] or (1000 + idx[y])
		return px < py
	end)
	return list
end
local function Docked()
	local out = {}
	local list = DockFrames()
	if list then for _, cf in ipairs(list) do if cf and not cf.pintsBox2 then out[#out + 1] = cf end end end
	local saved = SavedDocked()
	if #out < #saved then PC.manualTabs = true; return Ordered(saved) end
	PC.manualTabs = false
	return Ordered(out)
end
PC.Docked = Docked
-- move a main-box tab one place left (-1) or right (+1)
function PC.MoveTab(id, dir)
	local list = Docked()
	local k
	for i, cf in ipairs(list) do if cf:GetID() == id then k = i end end
	if not k or not list[k + dir] then return end
	list[k], list[k + dir] = list[k + dir], list[k]
	local ord = TabOrder(true)
	wipe(ord)
	for _, cf in ipairs(list) do ord[#ord + 1] = cf:GetID() end
	if PC.UpdateBar then PC.UpdateBar() end
end
local Selected
PC.SelectedTab = function() return Selected and Selected() end
function Selected()
	if PC.manualTabs then return manualSel or ChatFrame1 end
	if FCFDock_GetSelectedWindow and GENERAL_CHAT_DOCK then local ok, f = pcall(FCFDock_GetSelectedWindow, GENERAL_CHAT_DOCK); if ok and f then return f end end
	return SELECTED_DOCK_FRAME or ChatFrame1
end
-- the combat log as the game shows it: its own add-on (loaded only when its tab is first opened the game's way, so
-- load it here), with the filter bar on top - "My actions" / "What happened to me?" - and what's happened so far
function PC.ShowCombatLog()
	local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_CombatLog")) or (IsAddOnLoaded and IsAddOnLoaded("Blizzard_CombatLog"))
	if not loaded then
		local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
		if load then pcall(load, "Blizzard_CombatLog") end
	end
	local qb = _G.CombatLogQuickButtonFrame_Custom
	if qb then
		qb:SetParent(ChatFrame2)
		qb:ClearAllPoints()
		qb:SetPoint("BOTTOMLEFT", ChatFrame2, "TOPLEFT", 0, 3)
		qb:SetPoint("BOTTOMRIGHT", ChatFrame2, "TOPRIGHT", 0, 3)
		qb:SetFrameLevel(ChatFrame2:GetFrameLevel() + 5)
		qb:Show()
	end
	if Blizzard_CombatLog_Refilter then pcall(Blizzard_CombatLog_Refilter) end
	if Blizzard_CombatLog_Update_QuickButtons then pcall(Blizzard_CombatLog_Update_QuickButtons) end
end
-- open one tab ourselves: it takes Main's place in the box, the others are hidden
local function ManualSelect(cf, list)
	manualSel = cf
	for _, o in ipairs(list) do
		if o ~= cf then if o ~= ChatFrame1 then o:Hide() end end
	end
	if cf ~= ChatFrame2 and _G.CombatLogQuickButtonFrame_Custom then _G.CombatLogQuickButtonFrame_Custom:Hide() end
	if cf ~= ChatFrame1 then
		cf:ClearAllPoints()
		-- the combat log has its filter bar along its top: leave room for it inside the box
		local top = (cf == ChatFrame2) and -24 or 0
		cf:SetPoint("TOPLEFT", ChatFrame1, "TOPLEFT", 0, top); cf:SetPoint("BOTTOMRIGHT", ChatFrame1, "BOTTOMRIGHT", 0, 0)
		cf:SetFrameStrata(ChatFrame1:GetFrameStrata()); cf:SetFrameLevel(ChatFrame1:GetFrameLevel() + 2)
		StyleFrame(cf)
		-- Main's box is the box: this tab's own would draw a second one inside it
		if cf.pintsBackdrop then cf.pintsBackdrop:Hide() end
		cf:Show()
		if cf == ChatFrame2 then PC.ShowCombatLog() end
	end
	-- Main's own lines hide while another tab is open (only its text: the typing box belongs to Main too)
	local fsc = ChatFrame1.FontStringContainer
	if fsc then fsc:SetAlpha(cf == ChatFrame1 and 1 or 0) end
	SELECTED_CHAT_FRAME = cf
end
local function BarButton(i)
	local b = barBtns[i]
	if b then return b end
	b = CreateFrame("Button", nil, bar)
	b:SetSize(TAB_W, 20)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp"); b:RegisterForDrag("LeftButton")
	b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
	b.t = b:CreateFontString(nil, "OVERLAY")
	b.t:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE"); b.t:SetShadowOffset(1, -1); b.t:SetShadowColor(0, 0, 0, 1)
	b.t:SetPoint("LEFT", 3, 0); b.t:SetPoint("RIGHT", -3, 0); b.t:SetJustifyH("CENTER"); b.t:SetWordWrap(false)
	local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.12)
	b:SetScript("OnClick", function(self, button)
		local cf = self.cf
		if not cf then return end
		if button == "RightButton" then
			local tab = _G[cf:GetName() .. "Tab"]
			PC.ShowTabMenu(cf:GetID(), self, tab and tab.pintsOrigClick and function() tab.pintsOrigClick(tab, "RightButton") end)
			return
		end
		if PC.manualTabs then ManualSelect(cf, Docked())
		elseif FCF_SelectDockFrame then FCF_SelectDockFrame(cf) end
		-- open on the latest lines
		if cf.ScrollToBottom then cf:ScrollToBottom() end
		local tab = _G[cf:GetName() .. "Tab"]
		if tab and FCF_StopAlertFlash then pcall(FCF_StopAlertFlash, cf) end
		if PC.activeBox ~= 1 and PC.SetActiveBox then PC.SetActiveBox(1) end
		PC.UpdateBar()
	end)
	b:SetScript("OnDragStart", function() DragStart(ChatFrame1) end)
	b:SetScript("OnDragStop", DragStop)
	barBtns[i] = b
	return b
end
local function Arrow(dir)
	local a = CreateFrame("Button", nil, bar)
	a:SetSize(ARROW_W, 20)
	a.bg = a:CreateTexture(nil, "BACKGROUND"); a.bg:SetAllPoints(); a.bg:SetColorTexture(0, 0, 0, 0.7)
	a.t = a:CreateFontString(nil, "OVERLAY"); a.t:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE"); a.t:SetPoint("CENTER"); a.t:SetText(dir < 0 and "<" or ">")
	local hl = a:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.15)
	a:SetScript("OnClick", function() barFirst = barFirst + dir; PC.UpdateBar() end)
	return a
end
function PC.UpdateBar()
	if not bar then
		if not (ChatFrame1 and menuBtnReady) then return end
		bar = CreateFrame("Frame", "PintsChatTabBar", UIParent)
		-- (the same layer as the menu button: the chat's own layer has the game's darkened dock strip over it)
		bar:SetFrameStrata("MEDIUM"); bar:SetFrameLevel(50)
		bar:SetPoint("BOTTOMLEFT", ChatFrame1, "TOPLEFT", -4, 3)
		bar:SetPoint("RIGHT", _G.PintsChatMenuButton or ChatFrame1, "LEFT", -4, 0)
		bar:SetHeight(20)
		bar:EnableMouseWheel(true)
		bar:SetScript("OnMouseWheel", function(_, d) barFirst = barFirst - d; PC.UpdateBar() end)
		bar:SetScript("OnSizeChanged", function() PC.UpdateBar() end)
		bar.left, bar.right = Arrow(-1), Arrow(1)
	end
	local list = Docked()
	local w = bar:GetWidth() or 0
	local fit = math.max(1, math.floor((w + TAB_GAP) / (TAB_W + TAB_GAP)))
	local over = #list > fit
	if over then fit = math.max(1, math.floor((w - 2 * (ARROW_W + TAB_GAP) + TAB_GAP) / (TAB_W + TAB_GAP))) end
	barFirst = math.max(1, math.min(barFirst, #list - fit + 1))
	-- bring the open tab into view when you switch to it (only then: the arrows and the mouse wheel may scroll it out)
	local sel = Selected()
	if sel ~= bar.lastSel then
		bar.lastSel = sel
		for k, cf in ipairs(list) do
			if cf == sel then
				if k < barFirst then barFirst = k elseif k > barFirst + fit - 1 then barFirst = k - fit + 1 end
			end
		end
	end
	-- the open tab has been seen
	if sel then sel.pintsNew = nil end
	local x = 0
	bar.left:SetShown(over); bar.right:SetShown(over)
	if over then
		bar.left:ClearAllPoints(); bar.left:SetPoint("LEFT", 0, 0); x = ARROW_W + TAB_GAP
		bar.left:SetEnabled(barFirst > 1); bar.left:SetAlpha(barFirst > 1 and 1 or 0.35)
		local last = barFirst + fit - 1
		bar.right:ClearAllPoints(); bar.right:SetPoint("LEFT", x + fit * (TAB_W + TAB_GAP), 0)
		bar.right:SetEnabled(last < #list); bar.right:SetAlpha(last < #list and 1 or 0.35)
		-- an arrow turns gold when a tab with new messages is hidden past it
		local newL, newR = false, false
		for k, cf in ipairs(list) do
			if cf.pintsNew then if k < barFirst then newL = true elseif k > last then newR = true end end
		end
		bar.left.t:SetTextColor(unpack(newL and TAB_ALERT or TAB_OFF))
		bar.right.t:SetTextColor(unpack(newR and TAB_ALERT or TAB_OFF))
		bar.left.bg:SetColorTexture(newL and 0.4 or 0, newL and 0.3 or 0, 0, newL and 0.85 or 0.7)
		bar.right.bg:SetColorTexture(newR and 0.4 or 0, newR and 0.3 or 0, 0, newR and 0.85 or 0.7)
	end
	local n = 0
	for k = barFirst, math.min(#list, barFirst + fit - 1) do
		local cf = list[k]
		n = n + 1
		local b = BarButton(n)
		b.cf = cf
		b:ClearAllPoints(); b:SetPoint("LEFT", x + (n - 1) * (TAB_W + TAB_GAP), 0)
		local tab = _G[cf:GetName() .. "Tab"]
		local nm = GetChatWindowInfo(cf:GetID())
		b.t:SetText((nm and nm ~= "") and nm or (tab and tab.GetText and tab:GetText()) or "?")
		if cf == sel then b.bg:SetColorTexture(0.42, 0.22, 0.55, 0.92); b.t:SetTextColor(TAB_ON[1], TAB_ON[2], TAB_ON[3])
		elseif cf.pintsNew or (tab and tab.alerting) then
			-- new messages since you last looked: a gold band and gold name
			b.bg:SetColorTexture(0.4, 0.3, 0.02, 0.85); b.t:SetTextColor(TAB_ALERT[1], TAB_ALERT[2], TAB_ALERT[3])
		else b.bg:SetColorTexture(0, 0, 0, 0.75); b.t:SetTextColor(TAB_OFF[1], TAB_OFF[2], TAB_OFF[3]) end
		b:Show()
	end
	for k = n + 1, #barBtns do barBtns[k]:Hide() end
end

---------------------------------------------------------------- the menu (replaces the buttons)
local menu, sub, tabMenu
local function MenuFrame(nameSuffix)
	local f = CreateFrame("Frame", "PintsChatMenu" .. nameSuffix, UIParent, "BackdropTemplate")
	f:SetFrameStrata("FULLSCREEN_DIALOG"); f:SetClampedToScreen(true); f:EnableMouse(true); f:Hide()
	Backdrop(f, { 0.03, 0.03, 0.05, 0.96 }, EDGE)
	f.rows = {}
	tinsert(UISpecialFrames, f:GetName())
	return f
end
local function Fill(f, items, anchor, point, rel, x, y)
	for i, it in ipairs(items) do
		local b = f.rows[i]
		if not b then
			b = CreateFrame("Button", nil, f); b:SetSize(190, 18)
			b.t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.t:SetPoint("LEFT", 8, 0)
			b.arrow = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); b.arrow:SetPoint("RIGHT", -6, 0)
			local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(TAB_OFF[1], TAB_OFF[2], TAB_OFF[3], 0.2)
			f.rows[i] = b
		end
		b:ClearAllPoints(); b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 18)
		b.t:SetText(it.head and ("|cffd4a017" .. it.text .. "|r") or it.text)
		b.arrow:SetText(it.sub and ">" or "")
		b:EnableMouse(true)   -- the heading closes the menu when clicked
		b:SetScript("OnEnter", function(self)
			if it.sub then sub = sub or MenuFrame("Sub"); Fill(sub, it.sub(), self, "TOPLEFT", "TOPRIGHT", 4, 4)
			elseif sub and f ~= sub then sub:Hide() end
		end)
		b:SetScript("OnClick", function()
			if it.sub and not it.head then return end
			f:Hide(); if menu then menu:Hide() end; if sub then sub:Hide() end; if tabMenu then tabMenu:Hide() end
			if it.fn then it.fn() end
		end)
		b:Show()
	end
	for i = #items + 1, #f.rows do f.rows[i]:Hide() end
	f:SetSize(198, #items * 18 + 8)
	f:ClearAllPoints(); f:SetPoint(point, anchor, rel, x, y); f:Show()
end

local EMOTES = { "wave", "hello", "bye", "thank", "cheer", "dance", "laugh", "bow", "applaud", "flex", "lol", "ready",
	"oom", "followme", "charge", "train" }
local function Emotes()
	local t = {}
	for _, e in ipairs(EMOTES) do t[#t + 1] = { text = "/" .. e, fn = function() DoEmote(e:upper()) end } end
	return t
end
local function Current() return SELECTED_DOCK_FRAME or SELECTED_CHAT_FRAME or ChatFrame1 end
local function FontSizes()
	local t = {}
	for _, n in ipairs({ 10, 11, 12, 13, 14, 16, 18 }) do
		t[#t + 1] = { text = n .. " pt", fn = function()
			local cf = Current()
			if FCF_SetChatWindowFontSize then pcall(FCF_SetChatWindowFontSize, nil, cf, n) end
		end }
	end
	return t
end

local copyBox
local function CopyChat()
	local cf = Current()
	if not copyBox then
		copyBox = CreateFrame("Frame", "PintsChatCopy", UIParent, "BackdropTemplate")
		copyBox:SetSize(560, 360); copyBox:SetPoint("CENTER"); copyBox:SetFrameStrata("DIALOG"); copyBox:EnableMouse(true)
		copyBox:SetMovable(true); copyBox:RegisterForDrag("LeftButton")
		copyBox:SetScript("OnDragStart", copyBox.StartMoving); copyBox:SetScript("OnDragStop", copyBox.StopMovingOrSizing)
		Backdrop(copyBox, { 0.03, 0.03, 0.05, 0.96 }, EDGE)
		tinsert(UISpecialFrames, "PintsChatCopy")
		local t = copyBox:CreateFontString(nil, "OVERLAY", "GameFontNormal"); t:SetPoint("TOPLEFT", 10, -8); t:SetText("Copy chat - Ctrl+A, then Ctrl+C")
		local x = CreateFrame("Button", nil, copyBox, "UIPanelCloseButton"); x:SetPoint("TOPRIGHT", 2, 2)
		local sf = CreateFrame("ScrollFrame", "PintsChatCopyScroll", copyBox, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 10, -28); sf:SetPoint("BOTTOMRIGHT", -30, 10)
		local eb = CreateFrame("EditBox", nil, sf); eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(510); eb:SetScript("OnEscapePressed", function() copyBox:Hide() end)
		sf:SetScrollChild(eb); copyBox.eb = eb
	end
	local lines = {}
	local n = cf.GetNumMessages and cf:GetNumMessages() or 0
	for i = math.max(1, n - 300), n do
		local msg = cf.GetMessageInfo and cf:GetMessageInfo(i)
		if msg then
			msg = msg:gsub("|T.-|t", ""):gsub("|A.-|a", "")
			lines[#lines + 1] = msg
		end
	end
	copyBox.eb:SetText(table.concat(lines, "\n"))
	copyBox:Show(); copyBox.eb:SetFocus(); copyBox.eb:HighlightText()
end

---------------------------------------------------------------- the second box
-- Box 2 remembers its tabs by chat window number, so renaming a tab doesn't lose it.
local function B2()
	db.box2 = db.box2 or { tabs = {} }
	local b = db.box2
	-- older saves listed tabs by name: change them to window numbers
	for i, v in ipairs(b.tabs) do
		if type(v) == "string" then
			for id = 2, (NUM_CHAT_WINDOWS or 10) do if GetChatWindowInfo(id) == v then b.tabs[i] = id end end
		end
	end
	for i = #b.tabs, 1, -1 do if type(b.tabs[i]) ~= "number" then tremove(b.tabs, i) end end
	if type(b.sel) ~= "number" then b.sel = nil end
	return b
end
local function TabName(id) local n = GetChatWindowInfo(id); return (n and n ~= "") and n or ("Tab " .. id) end
local function FrameById(id)
	local cf = id and id >= 2 and _G["ChatFrame" .. id]
	local name = cf and GetChatWindowInfo(id)
	if cf and name and name ~= "" then return cf end
end
local function InBox2(id) for i, x in ipairs(B2().tabs) do if x == id then return i end end end
local function IsOpen(id)
	local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(id)
	return name and name ~= "" and (shown or docked or InBox2(id)) and true or false
end

function ColorBox2()
	if not box2 then return end
	for _, t in ipairs(box2.tabs) do
		if t:IsShown() then
			local c = (t.id == B2().sel) and TAB_ON or (t.cf and t.cf.pintsUnread and TAB_ALERT) or TAB_OFF
			t.fs:SetTextColor(c[1], c[2], c[3])
		end
	end
end
function SaveBox2()
	local b = B2(); b.where = Where(box2); b.w, b.h = box2:GetSize()
end

-- name prompts: a new tab (in either box) and renaming a tab in box 2
local function NamePopup(key, text, onName)
	StaticPopupDialogs[key] = {
		text = text, button1 = ACCEPT or "Accept", button2 = CANCEL or "Cancel",
		hasEditBox = true, maxLetters = 24, whileDead = true, hideOnEscape = true, timeout = 0, preferredIndex = 3,
		OnAccept = function(self, data) local eb = self.editBox or self.EditBox; onName(eb and eb:GetText() or "", data) end,
		EditBoxOnEnterPressed = function(self, data) onName(self:GetText(), data); self:GetParent():Hide() end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	}
end
local function Trim(s) s = (s or ""):gsub("^%s+", ""):gsub("%s+$", ""); return s end

function PC.NewTab(name, toBox2)
	name = Trim(name); if name == "" then name = "Chat" end
	if not FCF_OpenNewWindow then return end
	local ok, cf = pcall(FCF_OpenNewWindow, name)
	if not (ok and cf) then
		for id = (NUM_CHAT_WINDOWS or 10), 2, -1 do if GetChatWindowInfo(id) == name then cf = _G["ChatFrame" .. id]; break end end
	end
	if not cf then Print("the game has no room for another tab (10 is the most).") return end
	StyleFrame(cf)
	if toBox2 then PC.ToBox2(cf:GetID()) end
	Print("made the \"" .. name .. "\" tab. Pick what it shows with right-click > Settings on the tab, or Chat settings in the menu.")
end
NamePopup("PINTSCHAT_NEWTAB", "Name for the new tab:", function(name, toBox2) PC.NewTab(name, toBox2) end)
NamePopup("PINTSCHAT_RENAME", "New name for this tab:", function(name, id)
	name = Trim(name); local cf = id and _G["ChatFrame" .. id]
	if name ~= "" and cf and FCF_SetWindowName then FCF_SetWindowName(cf, name); PC.LayoutBox2(); ColorTabs() end
end)
local function AskNewTab(toBox2) StaticPopup_Show("PINTSCHAT_NEWTAB", nil, nil, toBox2) end

-- right-click menu for any tab, in either box
function PC.ShowTabMenu(id, anchor, gameMenu)
	local cf = _G["ChatFrame" .. id]; if not cf then return end
	local inBox2 = InBox2(id) and true or false
	local items = { { text = TabName(id), head = true } }
	if id >= 2 then
		if inBox2 then items[#items + 1] = { text = "Move to the main box  |cff909090<|r", fn = function() PC.ToMain(id) end }
		else items[#items + 1] = { text = "Move to box 2  |cff909090>|r", fn = function() PC.ToBox2(id) end } end
	end
	if not inBox2 and PC.Docked then
		local list, k = PC.Docked(), nil
		for i, f in ipairs(list) do if f:GetID() == id then k = i end end
		if k and k > 1 then items[#items + 1] = { text = "Move left  |cff909090<|r", fn = function() PC.MoveTab(id, -1) end } end
		if k and k < #list then items[#items + 1] = { text = "Move right  |cff909090>|r", fn = function() PC.MoveTab(id, 1) end } end
	end
	items[#items + 1] = { text = "Rename", fn = function() StaticPopup_Show("PINTSCHAT_RENAME", nil, nil, id) end }
	items[#items + 1] = { text = "New tab in this box", fn = function() AskNewTab(inBox2) end }
	items[#items + 1] = { text = "Chat settings for this tab", fn = function()
		if ChatConfigFrame then CURRENT_CHAT_FRAME_ID = id; ShowUIPanel(ChatConfigFrame) end
	end }
	if id >= 3 then
		items[#items + 1] = { text = "Close this tab", fn = function()
			if inBox2 then local i = InBox2(id); if i then tremove(B2().tabs, i) end; cf.pintsBox2 = nil end
			if FCF_Close then pcall(FCF_Close, cf) end
			PC.LayoutBox2(); ColorTabs()
		end }
	end
	if gameMenu then items[#items + 1] = { text = "|cff909090More options (game menu)|r", fn = gameMenu } end
	items[#items + 1] = { text = db.locked and "Unlock boxes" or "Lock boxes in place", fn = function() db.locked = not db.locked; ApplyLock() end }
	tabMenu = tabMenu or MenuFrame("Tab")
	Fill(tabMenu, items, anchor, "BOTTOMLEFT", "TOPLEFT", 0, 2)
end

local function NewBox2Tab(i)
	local t = CreateFrame("Button", nil, box2); t:SetHeight(20)
	t.fs = t:CreateFontString(nil, "OVERLAY")
	local src = ChatFrame1Tab and (ChatFrame1Tab.Text or ChatFrame1Tab:GetFontString())
	t.fs:SetFont((src and src:GetFont()) or STANDARD_TEXT_FONT, 12, ""); t.fs:SetShadowOffset(1, -1); t.fs:SetShadowColor(0, 0, 0, 1)
	t.fs:SetPoint("CENTER")
	t:SetFrameLevel(box2:GetFrameLevel() + 5)   -- above the drag strip, so clicks reach the tab
	t:RegisterForClicks("LeftButtonUp", "RightButtonUp"); t:RegisterForDrag("LeftButton")
	t:SetScript("OnDragStart", function() DragStart(box2) end)
	t:SetScript("OnDragStop", DragStop)
	t:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			PC.ShowTabMenu(self.id, self)
			return
		end
		B2().sel = self.id; if self.cf then self.cf.pintsUnread = nil end
		PC.SetActiveBox(2)
		PC.LayoutBox2()
	end)
	box2.tabs[i] = t
	return t
end

local function MakeBox2()
	if box2 then return end
	box2 = CreateFrame("Frame", "PintsChatBox2", UIParent, "BackdropTemplate")
	box2:SetFrameStrata(ChatFrame1:GetFrameStrata()); box2:SetFrameLevel(math.max(0, ChatFrame1:GetFrameLevel() - 1))
	box2:SetMovable(true); box2:SetResizable(true); box2:SetClampedToScreen(true)
	if box2.SetResizeBounds then box2:SetResizeBounds(220, 100) elseif box2.SetMinResize then box2:SetMinResize(220, 100) end
	Backdrop(box2, BG, EDGE)
	local line = box2:CreateTexture(nil, "ARTWORK"); line:SetColorTexture(EDGE[1], EDGE[2], EDGE[3], 0.6); line:SetHeight(1)
	line:SetPoint("TOPLEFT", 1, -24); line:SetPoint("TOPRIGHT", -1, -24)
	-- the empty part of the tab strip is a handle too
	local strip = CreateFrame("Frame", nil, box2); strip:SetPoint("TOPLEFT"); strip:SetPoint("TOPRIGHT"); strip:SetHeight(24)
	strip:EnableMouse(true); strip:RegisterForDrag("LeftButton")
	strip:SetScript("OnDragStart", function() DragStart(box2) end); strip:SetScript("OnDragStop", DragStop)
	box2.tabs = {}
	-- X: close box 2 (every tab in it goes back to the main box)
	local x = CreateFrame("Button", nil, box2); x:SetSize(18, 18); x:SetPoint("TOPRIGHT", -4, -3)
	x:SetFrameLevel(box2:GetFrameLevel() + 5)
	x.t = x:CreateFontString(nil, "OVERLAY", "GameFontNormal"); x.t:SetPoint("CENTER"); x.t:SetText("x")
	x.t:SetTextColor(TAB_OFF[1], TAB_OFF[2], TAB_OFF[3])
	local xh = x:CreateTexture(nil, "HIGHLIGHT"); xh:SetAllPoints(); xh:SetColorTexture(1, 1, 1, 0.12)
	x:SetScript("OnClick", function() PC.CloseBox2() end)
	x:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Close this box"); GameTooltip:AddLine("Its tabs go back to the main box.", 1, 1, 1); GameTooltip:Show() end)
	x:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- +: a new tab in this box
	local plus = CreateFrame("Button", nil, box2); plus:SetSize(18, 18); plus:SetPoint("RIGHT", x, "LEFT", -2, 0)
	plus:SetFrameLevel(box2:GetFrameLevel() + 5)
	plus.t = plus:CreateFontString(nil, "OVERLAY", "GameFontNormal"); plus.t:SetPoint("CENTER"); plus.t:SetText("+")
	plus.t:SetTextColor(TAB_OFF[1], TAB_OFF[2], TAB_OFF[3])
	local ph = plus:CreateTexture(nil, "HIGHLIGHT"); ph:SetAllPoints(); ph:SetColorTexture(1, 1, 1, 0.12)
	plus:SetScript("OnClick", function() AskNewTab(true) end)
	plus:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("New tab in this box"); GameTooltip:Show() end)
	plus:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Grip(box2, function() return box2 end):SetFrameLevel(box2:GetFrameLevel() + 10)
	local b = B2()
	if b.where then PutAt(box2, b.where)
	elseif b.pos then box2:SetPoint(b.pos[1], UIParent, b.pos[2], b.pos[3], b.pos[4]); box2:SetSize(b.w or 380, b.h or 180)
	else box2:SetPoint("BOTTOMLEFT", ChatFrame1, "BOTTOMRIGHT", 40, -6); box2:SetSize(380, 180) end
end

-- a window floating on its own (not in the main box, not in box 2) goes back into the main box
local function DockStrays()
	for id = 2, (NUM_CHAT_WINDOWS or 10) do
		local cf = _G["ChatFrame" .. id]
		local name, _, _, _, _, _, _, _, docked = GetChatWindowInfo(id)
		if cf and name and name ~= "" and not docked and not cf.isDocked and cf:IsShown() and not InBox2(id) and not cf.isTemporary then
			cf.pintsBox2, cf.pintsUnread = nil, nil
			local tab = _G[cf:GetName() .. "Tab"]
			if tab and tab.pintsHome then tab:SetParent(tab.pintsHome) end
			if cf.pintsBackdrop then cf.pintsBackdrop:Show() end
			local n = DockCount() + 1
			if FCF_DockFrame then pcall(FCF_DockFrame, cf, n, false) end
			Print("put the loose \"" .. name .. "\" window back in the main box.")
		end
	end
end

function PC.LayoutBox2()
	if not db then return end
	DockStrays()
	local b, members = B2(), {}
	for _, id in ipairs(b.tabs) do local cf = FrameById(id); if cf then members[#members + 1] = { id = id, cf = cf } end end
	if #members == 0 then if box2 then box2:Hide() end; if PC.activeBox == 2 then PC.SetActiveBox(1) end; return end
	MakeBox2(); box2:Show()
	local found
	for _, m in ipairs(members) do if m.id == b.sel then found = true end end
	if not found then b.sel = members[1].id end
	for i, m in ipairs(members) do
		local cf = m.cf
		StyleFrame(cf)
		cf.pintsBox2 = true
		if cf.isDocked and FCF_UnDockFrame then pcall(FCF_UnDockFrame, cf) end
		cf:ClearAllPoints()
		cf:SetPoint("TOPLEFT", box2, "TOPLEFT", 8, cf == ChatFrame2 and -52 or -30)   -- the combat log has its filter bar on top
		cf:SetPoint("BOTTOMRIGHT", box2, "BOTTOMRIGHT", -8, 8)
		if cf.pintsBackdrop then cf.pintsBackdrop:Hide() end
		-- the game gives a window that isn't docked its own minimise button; box 2 has the X instead
		local mb = (cf.buttonFrame and cf.buttonFrame.minimizeButton) or _G[cf:GetName() .. "ButtonFrameMinimizeButton"]
		Bury(mb)
		local tab = _G[cf:GetName() .. "Tab"]
		if tab and tab:GetParent() ~= hider then tab.pintsHome = tab:GetParent(); tab:SetParent(hider) end
		cf:SetShown(m.id == b.sel)
		if not cf.pintsHooked then
			cf.pintsHooked = true
			hooksecurefunc(cf, "AddMessage", function(self)
				if self.pintsBox2 and not self:IsShown() and not self.pintsUnread then self.pintsUnread = true; ColorBox2() end
			end)
		end
		local t = box2.tabs[i] or NewBox2Tab(i)
		t.cf, t.id = cf, m.id
		t.fs:SetText(TabName(m.id)); t:SetWidth(t.fs:GetStringWidth() + 18)
		t:ClearAllPoints()
		if i == 1 then t:SetPoint("TOPLEFT", 6, -2) else t:SetPoint("LEFT", box2.tabs[i - 1], "RIGHT", 2, 0) end
		t:Show()
	end
	for i = #members + 1, #box2.tabs do box2.tabs[i]:Hide() end
	ColorBox2()
	C_Timer.After(0.2, PC.HideStrays)
end

-- any "minimise" button the game puts on a window in box 2, wherever it is parented
-- the game's "minimise" button (yellow dash) on chat windows: we don't use it, so it's hidden wherever it turns up
local refTex = UIParent:CreateTexture(nil, "BACKGROUND"); refTex:Hide()
local MIN_IDS = {}
for _, path in ipairs({ "Interface\\ChatFrame\\UI-ChatIcon-Minimize-Up", "Interface\\ChatFrame\\UI-ChatIcon-Minimize-Down",
	"Interface\\Buttons\\UI-Panel-SmallerButton-Up" }) do
	refTex:SetTexture(path)
	local id = refTex.GetTextureFileID and refTex:GetTextureFileID()
	if id then MIN_IDS[id] = true end
end
local function IsMinimize(f)
	local n = f:GetName() or (f.GetDebugName and f:GetDebugName()) or ""
	if type(n) ~= "string" then n = "" end
	if n:lower():find("minimi") then return true end
	local tex = f.GetNormalTexture and f:GetNormalTexture()
	if not tex then return false end
	local id = tex.GetTextureFileID and tex:GetTextureFileID()
	if id and MIN_IDS[id] then return true end
	local p = tex:GetTexture()
	return type(p) == "string" and p:lower():find("minimi") ~= nil
end
do local raw = IsMinimize; IsMinimize = function(f) local ok, r = pcall(raw, f); return ok and r end end
local function Inside(x, y, f)
	local l, r, b, t = f:GetLeft(), f:GetRight(), f:GetBottom(), f:GetTop()
	return l and x >= l - 4 and x <= r + 4 and y >= b - 4 and y <= t + 30
end
function PC.HideStrays()
	local f = EnumerateFrames()
	while f do
		if f:IsVisible() and f:IsObjectType("Button") and f:GetParent() ~= hider and IsMinimize(f) then
			local x, y = f:GetCenter()
			if x and (Inside(x, y, ChatFrame1) or (box2 and box2:IsShown() and Inside(x, y, box2))) then Bury(f) end
		end
		f = EnumerateFrames(f)
	end
end

function PC.ToBox2(id)
	if not id or InBox2(id) or not FrameById(id) then return end
	tinsert(B2().tabs, id); B2().sel = id
	PC.LayoutBox2()
	if FCF_SelectDockFrame then pcall(FCF_SelectDockFrame, ChatFrame1) end
	ColorTabs()
end

function PC.CloseBox2()
	local list = {}
	for _, id in ipairs(B2().tabs) do list[#list + 1] = id end
	for _, id in ipairs(list) do PC.ToMain(id) end
	if box2 then box2:Hide() end
end

function PC.ToMain(id)
	local i = InBox2(id); if not i then return end
	tremove(B2().tabs, i)
	local cf = FrameById(id)
	if cf then
		cf.pintsBox2, cf.pintsUnread = nil, nil
		local tab = _G[cf:GetName() .. "Tab"]
		if tab and tab.pintsHome then tab:SetParent(tab.pintsHome) end
		if cf.pintsBackdrop then cf.pintsBackdrop:Show() end
		cf:ClearAllPoints(); cf:Show()
		local n = DockCount() + 1
		if FCF_DockFrame then pcall(FCF_DockFrame, cf, n, true) end
	end
	PC.LayoutBox2(); ColorTabs()
	if FCF_DockUpdate then pcall(FCF_DockUpdate) end
	C_Timer.After(0.2, PC.HideStrays)
end

local function Box2Menu()
	local t = {}
	for id = 2, (NUM_CHAT_WINDOWS or 10) do
		if _G["ChatFrame" .. id] and IsOpen(id) then
			local name = TabName(id)
			if InBox2(id) then t[#t + 1] = { text = name .. "  |cff909090- to main box|r", fn = function() PC.ToMain(id) end }
			else t[#t + 1] = { text = name .. "  |cff909090- to box 2|r", fn = function() PC.ToBox2(id) end } end
		end
	end
	t[#t + 1] = { text = "Whisper, Party, Guild, Raid to box 2", fn = function()
		for _, n in ipairs({ "Whisper", "Party", "Guild", "Raid" }) do
			for id = 2, (NUM_CHAT_WINDOWS or 10) do if GetChatWindowInfo(id) == n and IsOpen(id) then PC.ToBox2(id) end end
		end
	end }
	return t
end
local function NewTabMenu()
	return {
		{ text = "In the main box", fn = function() AskNewTab(false) end },
		{ text = "In box 2", fn = function() AskNewTab(true) end },
	}
end

local function MenuItems()
	local items = {
		{ text = "Pint's Chat", head = true },
		{ text = "Friends and social", fn = function() if ToggleFriendsFrame then ToggleFriendsFrame(1) end end },
		{ text = "Guild", fn = function() if ToggleGuildFrame then ToggleGuildFrame() elseif ToggleFriendsFrame then ToggleFriendsFrame(3) end end },
		{ text = "Chat channels", fn = function() if ToggleChannelFrame then ToggleChannelFrame() end end },
		{ text = "Emotes", sub = Emotes },
		{ text = "Copy chat", fn = CopyChat },
		{ text = "Jump to newest", fn = function() Current():ScrollToBottom() end },
		{ text = "Font size", sub = FontSizes },
		{ text = "New chat tab", sub = NewTabMenu },
		{ text = "Move tabs between boxes", sub = Box2Menu },
		{ text = "Rebuild default tabs", fn = function() StaticPopup_Show("PINTSCHAT_REBUILD") end },
		{ text = db.locked and "Unlock boxes" or "Lock boxes in place", fn = function()
			db.locked = not db.locked; ApplyLock()
			Print(db.locked and "boxes locked in place." or "boxes unlocked - drag a tab to move a box, drag the corner to resize.")
		end },
		{ text = "Chat settings", fn = function()
			if ShowUIPanel and ChatConfigFrame then ShowUIPanel(ChatConfigFrame) end
		end },
	}
	return items
end

local menuBtn
local function MakeMenuButton()
	if menuBtn then return end
	menuBtn = CreateFrame("Button", "PintsChatMenuButton", UIParent)
	menuBtnReady = true; C_Timer.After(0, function() if PC.UpdateBar then PC.UpdateBar() end end)
	menuBtn:SetSize(20, 18); menuBtn:SetFrameStrata("MEDIUM")
	menuBtn:SetPoint("BOTTOMRIGHT", ChatFrame1, "TOPRIGHT", 2, 3)
	for i = 1, 3 do        -- three bars: a "menu" sign
		local t = menuBtn:CreateTexture(nil, "ARTWORK"); t:SetColorTexture(TAB_OFF[1], TAB_OFF[2], TAB_OFF[3], 0.95); t:SetSize(12, 2)
		t:SetPoint("CENTER", 0, 5 - (i - 1) * 5)
	end
	local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.12)
	menuBtn:SetScript("OnClick", function(self)
		if menu and menu:IsShown() then menu:Hide(); if sub then sub:Hide() end; return end
		menu = menu or MenuFrame("Main")
		menu:SetScript("OnHide", function() if sub then sub:Hide() end end)
		Fill(menu, MenuItems(), self, "BOTTOMRIGHT", "TOPRIGHT", 0, 2)
	end)
	menuBtn:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Chat menu"); GameTooltip:Show() end)
	menuBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------- the default tabs: Main, Raid, Guild, Whisper, Party (Log stays at the end)
-- what each tab shows. Unknown groups (things a client doesn't have) are skipped.
local MAIN_GROUPS = {
	"SAY", "YELL", "EMOTE", "TEXT_EMOTE", "SYSTEM", "ERRORS", "IGNORED", "CHANNEL", "AFK", "DND",
	"MONSTER_SAY", "MONSTER_YELL", "MONSTER_EMOTE", "MONSTER_WHISPER", "MONSTER_BOSS_EMOTE", "MONSTER_BOSS_WHISPER",
	"LOOT", "MONEY", "CURRENCY", "SKILL", "TRADESKILLS", "OPENING", "PET_INFO", "COMBAT_MISC_INFO",
	"COMBAT_XP_GAIN", "COMBAT_HONOR_GAIN", "COMBAT_FACTION_CHANGE", "BG_HORDE", "BG_ALLIANCE", "BG_NEUTRAL",
	"WHISPER", "BN_WHISPER", "BN_INLINE_TOAST_ALERT", "PARTY", "PARTY_LEADER", "RAID", "RAID_LEADER", "RAID_WARNING",
	"INSTANCE_CHAT", "INSTANCE_CHAT_LEADER", "GUILD", "OFFICER", "GUILD_ACHIEVEMENT", "ACHIEVEMENT",
}
local TABS = {
	{ "Raid",    { "RAID", "RAID_LEADER", "RAID_WARNING", "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER", "MONSTER_BOSS_EMOTE", "MONSTER_BOSS_WHISPER" } },
	{ "Guild",   { "GUILD", "OFFICER", "GUILD_ACHIEVEMENT" } },
	{ "Whisper", { "WHISPER", "BN_WHISPER", "BN_CONVERSATION", "AFK", "DND" } },
	{ "Party",   { "PARTY", "PARTY_LEADER" } },
}
local function AddGroups(cf, groups)
	for _, g in ipairs(groups) do if ChatTypeGroup == nil or ChatTypeGroup[g] then pcall(ChatFrame_AddMessageGroup, cf, g) end end
end
local function FindTab(name)
	for id = 2, (NUM_CHAT_WINDOWS or 10) do
		local n, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(id)
		local cf = _G["ChatFrame" .. id]
		if cf and n == name and (shown or docked or cf.pintsBox2) then return cf end
	end
end
local function SetTab(cf, groups)
	if ChatFrame_RemoveAllMessageGroups then ChatFrame_RemoveAllMessageGroups(cf) end
	if ChatFrame_RemoveAllChannels then pcall(ChatFrame_RemoveAllChannels, cf) end   -- General, Trade etc. stay in Main only
	AddGroups(cf, groups)
end

-- loot, rolls and money: the modern game client's own default puts them in no tab at all, so if no tab you can see
-- shows loot, Main gets it (once per character, so taking it out yourself afterwards sticks)
local LOOT_GROUPS = { "LOOT", "MONEY", "CURRENCY" }
function PC.EnsureLoot(force)
	if not db or InCombatLockdown() or not GetChatWindowMessages then return end
	db.lootFixed = db.lootFixed or {}
	local me = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
	if db.lootFixed[me] and not force then return end
	for id = 1, (NUM_CHAT_WINDOWS or 10) do
		local _, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(id)
		if shown or docked or id == 1 then
			for _, g in ipairs({ GetChatWindowMessages(id) }) do if g == "LOOT" then db.lootFixed[me] = true; return end end
		end
	end
	if ChatFrame1 then AddGroups(ChatFrame1, LOOT_GROUPS) end
	db.lootFixed[me] = true
	Print("loot, rolls and money now show in Main.")
end

-- rebuild = true: close every other tab first so the tabs come out clean and in order
function PC.MakeTabs(rebuild)
	if InCombatLockdown() then Print("can't change tabs during combat - try again after.") return end
	if rebuild then
		if PC.CloseBox2 and db.box2 and #db.box2.tabs > 0 then PC.CloseBox2() end
		-- start from the game's own defaults: Main gets exactly what a fresh character's chat shows
		local reset = FCF_ResetChatWindows and pcall(FCF_ResetChatWindows)
		if reset and PC.RestoreMain then C_Timer.After(0.5, PC.RestoreMain) end
		for id = 3, (NUM_CHAT_WINDOWS or 10) do
			local n, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(id)
			local cf = _G["ChatFrame" .. id]
			if cf and n and n ~= "" and (shown or docked) and FCF_Close then pcall(FCF_Close, cf) end
		end
	end
	if FCF_SetWindowName then
		if ChatFrame1 then pcall(FCF_SetWindowName, ChatFrame1, "Main") end
		if ChatFrame2 and GetChatWindowInfo(2) == (COMBAT_LOG or "Combat Log") then pcall(FCF_SetWindowName, ChatFrame2, "Log") end
	end
	-- the combat log (Log): back in the main box if this character had closed it
	if ChatFrame2 and not ChatFrame2.isDocked and not ChatFrame2.pintsBox2 and FCF_DockFrame then
		if SetChatWindowShown then pcall(SetChatWindowShown, 2, true) end
		pcall(FCF_DockFrame, ChatFrame2, DockCount() + 1, false)
		if FCF_SetWindowName then pcall(FCF_SetWindowName, ChatFrame2, "Log") end
	end
	-- (Main is left as the game set it up - its usual messages and channels)
	for _, t in ipairs(TABS) do
		local cf = FindTab(t[1])
		if not cf and FCF_OpenNewWindow then
			local ok, made = pcall(FCF_OpenNewWindow, t[1], true)
			cf = ok and made or FindTab(t[1])
		end
		if cf then SetTab(cf, t[2]); StyleFrame(cf) end
	end
	-- Log goes after the others
	if rebuild and ChatFrame2 and ChatFrame2.isDocked and FCF_UnDockFrame and FCF_DockFrame then
		pcall(FCF_UnDockFrame, ChatFrame2)
		pcall(FCF_DockFrame, ChatFrame2, DockCount() + 1, false)
	end
	C_Timer.After(1, function() PC.EnsureLoot(true) end)
	Redock()
	if FCF_SelectDockFrame and ChatFrame1 then pcall(FCF_SelectDockFrame, ChatFrame1) end
	if FCF_DockUpdate then pcall(FCF_DockUpdate) end
	C_Timer.After(0.3, function() if PC.StyleAll then PC.StyleAll() end; ColorTabs() end)
end

StaticPopupDialogs.PINTSCHAT_REBUILD = {
	text = "Rebuild the chat tabs as Main, Raid, Guild, Whisper and Party?\n\nMain goes back to the game's own default settings, your other tabs are closed, and box 2 is emptied.",
	button1 = ACCEPT or "Accept", button2 = CANCEL or "Cancel", whileDead = true, hideOnEscape = true, timeout = 0, preferredIndex = 3,
	OnAccept = function() PC.MakeTabs(true); Print("rebuilt your tabs: Main, Raid, Guild, Whisper, Party (and Log).") end,
}

---------------------------------------------------------------- set-up
-- the game keeps a gap at the screen edge for the old button column; ours only needs room for the border and tabs
local function Clamp()
	for cf in pairs(styled) do cf:SetClampRectInsets(-6, cf.pintsRight or 6, 26, -6) end
end

local function StyleAll()
	for i = 1, (NUM_CHAT_WINDOWS or 10) do StyleFrame(_G["ChatFrame" .. i]) end
	Clamp()
	C_Timer.After(0.3, PC.HideStrays)
	-- the shared buttons next to chat
	for _, n in ipairs({ "ChatFrameMenuButton", "ChatFrameChannelButton", "ChatFrameToggleVoiceDeafenButton",
		"ChatFrameToggleVoiceMuteButton", "QuickJoinToastButton", "TextToSpeechButton", "ChatAlertFrame" }) do
		if n ~= "ChatAlertFrame" then Bury(_G[n]) end
	end
	-- tabs stay fully visible instead of fading out
	CHAT_FRAME_TAB_NORMAL_NOMOUSE_ALPHA = 1
	CHAT_FRAME_TAB_SELECTED_NOMOUSE_ALPHA = 1
	CHAT_FRAME_TAB_ALERTING_NOMOUSE_ALPHA = 1
	MakeMenuButton()
	ColorTabs()
end
PC.StyleAll = StyleAll

-- a click anywhere outside the menus closes them
local closer = CreateFrame("Frame")
pcall(closer.RegisterEvent, closer, "GLOBAL_MOUSE_DOWN")
---------------------------------------------------------------- typing: the input line sits under whichever box you last clicked
PC.activeBox = 1
local homePoints = {}
local placing = false
local Watch
local function PlaceEditBox(eb)
	if not eb or placing then return end
	Watch(eb)
	if not homePoints[eb] then
		local pts = {}
		for i = 1, eb:GetNumPoints() do pts[i] = { eb:GetPoint(i) } end
		homePoints[eb] = pts
	end
	placing = true
	if PC.activeBox == 2 and box2 and box2:IsShown() then
		eb:ClearAllPoints()
		eb:SetPoint("TOPLEFT", box2, "BOTTOMLEFT", 0, -2); eb:SetPoint("TOPRIGHT", box2, "BOTTOMRIGHT", 0, -2)
		eb.pintsMoved = true
	elseif eb.pintsMoved then
		eb:ClearAllPoints()
		for _, pt in ipairs(homePoints[eb]) do eb:SetPoint(unpack(pt)) end
		eb.pintsMoved = nil
	end
	placing = false
end
-- the game puts the input line back under the main box when it opens; put it where it belongs right after
function Watch(eb)
	if eb.pintsWatched then return end
	eb.pintsWatched = true
	eb:HookScript("OnShow", function(self)
		PlaceEditBox(self); C_Timer.After(0, function() PlaceEditBox(self) end)
	end)
	hooksecurefunc(eb, "SetPoint", function(self)
		if placing or PC.activeBox ~= 2 then return end
		if not homePoints[self] or not self.pintsMoved then return end
		C_Timer.After(0, function() PlaceEditBox(self) end)
	end)
end
function PC.SetActiveBox(n)
	PC.activeBox = n
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local eb = _G["ChatFrame" .. i .. "EditBox"]
		if eb then Watch(eb); if eb:IsShown() or eb.pintsMoved then PlaceEditBox(eb) end end
	end
end
for _, f in ipairs({ "ChatEdit_ActivateChat", "ChatFrame_OpenChat", "ChatEdit_SetLastActiveWindow" }) do
	if _G[f] then hooksecurefunc(f, function(a)
		local eb = (type(a) == "table" and a.GetObjectType and a:GetObjectType() == "EditBox" and a) or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
		if eb then PlaceEditBox(eb); C_Timer.After(0, function() PlaceEditBox(eb) end) end
	end) end
end

closer:SetScript("OnEvent", function()
	-- which box was clicked (the input line follows it)
	local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
	if not (eb and MouseIsOver(eb)) then
		local main = SELECTED_DOCK_FRAME or ChatFrame1
		if box2 and box2:IsShown() and MouseIsOver(box2) then if PC.activeBox ~= 2 then PC.SetActiveBox(2) end
		elseif main and main:IsVisible() and MouseIsOver(main, 28, -8, -8, 8) then if PC.activeBox ~= 1 then PC.SetActiveBox(1) end end
	end
	local over = (menu and menu:IsShown() and MouseIsOver(menu)) or (sub and sub:IsShown() and MouseIsOver(sub))
		or (tabMenu and tabMenu:IsShown() and MouseIsOver(tabMenu)) or (menuBtn and MouseIsOver(menuBtn))
	if over then return end
	if menu then menu:Hide() end; if sub then sub:Hide() end; if tabMenu then tabMenu:Hide() end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED"); ev:RegisterEvent("PLAYER_ENTERING_WORLD"); ev:RegisterEvent("UPDATE_CHAT_WINDOWS")
ev:SetScript("OnEvent", function(_, e, a1)
	if e == "ADDON_LOADED" and a1 == ADDON then
		PintsChatDB = PintsChatDB or {}
		db = PintsChatDB
	elseif e == "PLAYER_ENTERING_WORLD" or e == "UPDATE_CHAT_WINDOWS" then
		StyleAll()
		C_Timer.After(0.5, PC.LayoutBox2)   -- after the game has put its windows back where it saved them
		C_Timer.After(0.5, PC.RestoreMain)
		if e == "PLAYER_ENTERING_WORLD" then C_Timer.After(2, PC.RestoreMain); C_Timer.After(3, function() PC.EnsureLoot() end) end
		C_Timer.After(1, function() Redock(); ColorTabs() end)
		if e == "PLAYER_ENTERING_WORLD" then C_Timer.After(4, function() Redock(); ColorTabs() end) end
		-- the standard tabs, on every character (the game keeps each character's chat windows apart): added once per
		-- character, only the ones missing - your own tabs and settings are left alone
		if e == "PLAYER_ENTERING_WORLD" and db then
			db.tabsFor = db.tabsFor or {}
			-- (by the character's unique id: on WoW Forever several characters can share a first name - "Pint ..." -
			-- and keyed by name only the first of them ever got the tabs)
			local me = UnitGUID("player") or ((UnitName("player") or "?") .. "-" .. (GetRealmName() or "?"))
			-- and if none of the standard tabs is there any more (the game reset this character's chat), put them back
			local function NoneLeft()
				for _, t in ipairs(TABS) do if FindTab(t[1]) then return false end end
				return true
			end
			if not db.tabsFor[me] or NoneLeft() then
				C_Timer.After(2, function()
					if InCombatLockdown() or (db.tabsFor[me] and not NoneLeft()) then return end
					PC.MakeTabs(); db.tabsFor[me] = true
					Print("set up your tabs: Main, Log, Raid, Guild, Whisper and Party. The menu is the small button at the right of the tabs.")
				end)
			end
		end
	end
end)
-- whisper windows and new tabs made later get the same look
if FCF_OpenTemporaryWindow then hooksecurefunc("FCF_OpenTemporaryWindow", function() C_Timer.After(0, StyleAll) end) end
if FCF_OpenNewWindow then hooksecurefunc("FCF_OpenNewWindow", function() C_Timer.After(0, StyleAll) end) end
if FCF_Tab_OnClick then hooksecurefunc("FCF_Tab_OnClick", function() if PC.activeBox ~= 1 then PC.SetActiveBox(1) end end) end
for _, f in ipairs({ "FCF_Tab_OnClick", "FCF_SelectDockFrame", "FCF_StartAlertFlash", "FCF_StopAlertFlash", "FCFTab_UpdateColors", "FCF_DockFrame",
		"FCF_UnDockFrame", "FCF_Close", "FCF_SetWindowName", "FCF_DockUpdate", "FCF_OpenNewWindow", "FCF_OpenTemporaryWindow" }) do
	if _G[f] then hooksecurefunc(f, function() C_Timer.After(0, ColorTabs) end) end
end
for _, f in ipairs({ "FCF_UpdateButtonSide", "FCF_SetButtonSide", "FCF_RestorePositionAndDimensions", "FCF_DockUpdate" }) do
	if _G[f] then hooksecurefunc(f, function() C_Timer.After(0, Clamp) end) end
end
-- the "jump to newest" arrows: shown only while a window is scrolled up
local acc = 0
ev:SetScript("OnUpdate", function(_, el)
	acc = acc + el; if acc < 0.25 then return end; acc = 0
	for cf in pairs(styled) do
		if cf.pintsJump then cf.pintsJump:SetShown(cf:IsShown() and cf.AtBottom and not cf:AtBottom()) end
	end
end)

SLASH_PINTSCHAT1 = "/pchat"
SlashCmdList.PINTSCHAT = function(msg)
	msg = (msg or ""):lower()
	if msg == "tabs" then PC.MakeTabs(); Print("checked the tabs - any missing ones are back, with their settings.")
	elseif msg == "list" then   -- what the game says about each chat window (for bug reports)
		local inDock = {}
		local dl = DockFrames()
		Print("game's tab list: " .. (dl and (#dl .. " tabs") or "not found"))
		for k, cf in ipairs(dl or {}) do inDock[cf] = k end
		for id = 1, (NUM_CHAT_WINDOWS or 10) do
			local n, _, _, _, _, _, shown, locked, docked = GetChatWindowInfo(id)
			local cf = _G["ChatFrame" .. id]
			if n and n ~= "" then
				Print(("%d %s  shown=%s docked=%s inBox=%s visible=%s box2=%s"):format(id, n, tostring(shown), tostring(docked),
					tostring(cf and inDock[cf]), tostring(cf and cf:IsShown()), tostring(cf and cf.pintsBox2)))
			end
		end
	elseif msg == "reset" then StaticPopup_Show("PINTSCHAT_REBUILD")
	elseif msg == "copy" then CopyChat()
	elseif msg == "what" then   -- names everything under the mouse (hover something, then type /pchat what)
		local names, f = {}, EnumerateFrames()
		while f do
			if f:IsVisible() and MouseIsOver(f) and f ~= UIParent and f ~= WorldFrame then
				local w, h = f:GetSize()
				if w and w < 400 and h < 400 then names[#names + 1] = (f.GetDebugName and f:GetDebugName()) or f:GetName() or "?" end
			end
			f = EnumerateFrames(f)
		end
		Print("under the mouse: " .. (#names > 0 and table.concat(names, ", ") or "nothing") .. "  (typing box: " .. tostring(PC.activeBox) .. ")")
	elseif msg == "whisperclick" then db.clickWhispers = not db.clickWhispers
		Print(db.clickWhispers and "left-clicking a name starts a whisper (the game's way)." or "left-clicking a name opens the player menu.")
	elseif msg == "lock" then db.locked = not db.locked; ApplyLock(); Print(db.locked and "boxes locked." or "boxes unlocked.")
	else
		Print("the menu is the small button at the right of the chat tabs.  Drag a tab to move its box, drag the corner to resize.  /pchat lock - lock or unlock the boxes.  /pchat tabs - make any missing tabs again.  /pchat copy - copy chat.")
	end
end
