--[[
	WARNING: Heads up! This script has not been verified by ScriptBlox. Use at your own risk!
]]
--[[
  UAI Menu for ПАНЦИР
  - Drone ESP toggle
  - Auto Pantsir / Auto TOR-M1 (aim + fire at drones while seated)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local LOCAL = Players.LocalPlayer
local PlayerGui = LOCAL:WaitForChild("PlayerGui")
local HttpService = game:GetService("HttpService")

----------------------------------------------------------------
-- Cross-Client Sync (for multi-boxing)
----------------------------------------------------------------
local SYNC_FILE = "UAI_SharedTargets.json"
local BOTS_FILE = "UAI_SharedBots.json"
local lastSyncRead = 0
local cachedSyncData = {}
local lastBotsRead = 0
local cachedBots = {}
local lastBotHeartbeat = 0
local SYNC_HOLD = 25
local BOT_HOLD = 8

local function getSharedTargets(force)
	local now = os.clock()
	if not force and now - lastSyncRead < 0.05 then
		return cachedSyncData
	end
	lastSyncRead = now
	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(SYNC_FILE))
	end)
	if ok and type(data) == "table" then
		cachedSyncData = data
	else
		cachedSyncData = {}
	end
	return cachedSyncData
end

local function writeSharedTargets(targets)
	local tnow = workspace:GetServerTimeNow()
	local clean = {}
	for k, v in pairs(targets) do
		local ts = typeof(v) == "table" and tonumber(v.t) or tonumber(v)
		if ts and tnow - ts < SYNC_HOLD then
			clean[k] = typeof(v) == "table" and v or { t = ts, u = 0 }
		end
	end
	cachedSyncData = clean
	lastSyncRead = os.clock()
	pcall(function()
		writefile(SYNC_FILE, HttpService:JSONEncode(clean))
	end)
	return clean
end

local function getSharedBots(force)
	local now = os.clock()
	if not force and now - lastBotsRead < 0.2 then
		return cachedBots
	end
	lastBotsRead = now
	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(BOTS_FILE))
	end)
	if ok and type(data) == "table" then
		cachedBots = data
	else
		cachedBots = {}
	end
	return cachedBots
end

local function heartbeatBotSlot()
	local nowClock = os.clock()
	if nowClock - lastBotHeartbeat < 0.35 then
		return
	end
	lastBotHeartbeat = nowClock
	local tnow = workspace:GetServerTimeNow()
	local bots = getSharedBots(true)
	bots[tostring(LOCAL.UserId)] = tnow
	local clean = {}
	for id, ts in pairs(bots) do
		local n = tonumber(ts)
		if n and tnow - n < BOT_HOLD then
			clean[id] = n
		end
	end
	cachedBots = clean
	pcall(function()
		writefile(BOTS_FILE, HttpService:JSONEncode(clean))
	end)
end

local function getMyBotIndex()
	heartbeatBotSlot()
	local bots = getSharedBots(false)
	local ids = {}
	for id, ts in pairs(bots) do
		local n = tonumber(id)
		if n then
			table.insert(ids, n)
		end
	end
	table.sort(ids)
	for i, id in ipairs(ids) do
		if id == LOCAL.UserId then
			return i, #ids
		end
	end
	return 1, math.max(#ids, 1)
end

local function markSharedTarget(droneId)
	if not droneId then return end
	local idStr = tostring(droneId)
	local targets = getSharedTargets(true)
	targets[idStr] = { t = workspace:GetServerTimeNow(), u = LOCAL.UserId }
	writeSharedTargets(targets)
end

local function isSharedTarget(droneId)
	if not droneId then return false end
	local targets = getSharedTargets(false)
	local v = targets[tostring(droneId)]
	if not v then return false end
	local ts = typeof(v) == "table" and tonumber(v.t) or tonumber(v)
	local owner = typeof(v) == "table" and tonumber(v.u) or 0
	if not ts then return false end
	if workspace:GetServerTimeNow() - ts >= SYNC_HOLD then return false end
	return owner ~= LOCAL.UserId
end

local function tryClaimSharedTarget(droneId)
	if not droneId then return false end
	local idStr = tostring(droneId)
	local targets = getSharedTargets(true)
	local tnow = workspace:GetServerTimeNow()
	local v = targets[idStr]
	if v then
		local ts = typeof(v) == "table" and tonumber(v.t) or tonumber(v)
		local owner = typeof(v) == "table" and tonumber(v.u) or 0
		if ts and tnow - ts < SYNC_HOLD and owner ~= LOCAL.UserId then
			return false
		end
	end
	targets[idStr] = { t = tnow, u = LOCAL.UserId }
	writeSharedTargets(targets)
	return true
end

-- stop previous
if type(_G.UAI_StopMenu) == "function" then
	pcall(_G.UAI_StopMenu)
end
if type(_G.UAI_StopDroneESP) == "function" then
	pcall(_G.UAI_StopDroneESP)
end
if type(_G.UAI_StopAutoPantsir) == "function" then
	pcall(_G.UAI_StopAutoPantsir)
end
if type(_G.UAI_StopAutoTor) == "function" then
	pcall(_G.UAI_StopAutoTor)
end
if type(_G.UAI_StopAutoStrela) == "function" then
	pcall(_G.UAI_StopAutoStrela)
end

local oldGui = PlayerGui:FindFirstChild("UAI_Menu")
if oldGui then
	oldGui:Destroy()
end

----------------------------------------------------------------
-- Shared helpers
----------------------------------------------------------------
local function getDroneType(drone)
	local named = drone:GetAttribute("DroneName")
	if typeof(named) == "string" and named ~= "" then
		return named
	end
	for _, child in ipairs(drone:GetChildren()) do
		if child:IsA("Model") and not string.find(child.Name, "UAI_", 1, true) then
			return child.Name
		end
	end
	return "Drone"
end

local function getAnchor(drone)
	if not drone then
		return nil
	end
	if drone:IsA("Model") then
		local ok, primary = pcall(function()
			return drone.PrimaryPart
		end)
		if ok and primary then
			return primary
		end
	end
	local body = drone:FindFirstChild("Body", true)
	if body and body:IsA("BasePart") then
		return body
	end
	return drone:FindFirstChildWhichIsA("BasePart", true)
end

local function hasDroneId(model)
	if not model or not model:IsA("Model") then
		return false
	end
	if model:GetAttribute("DroneId") ~= nil then
		return true
	end
	return model:FindFirstChild("droneid") ~= nil
		or model:FindFirstChild("DroneId") ~= nil
		or model:FindFirstChild("DroneID") ~= nil
end

local function isFpvTarget(model)
	if not model then
		return true
	end
	if CollectionService:HasTag(model, "IsFpv") or CollectionService:HasTag(model, "FPVDr") then
		return true
	end
	local name = tostring(model:GetAttribute("DroneName") or "")
	local lower = string.lower(name)
	if string.find(lower, "fpv", 1, true) or string.find(lower, "fp1", 1, true) then
		return true
	end
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Model") then
			local n = string.lower(child.Name)
			if string.find(n, "fpv", 1, true) then
				return true
			end
		end
	end
	return false
end

local function isValidFireTarget(model)
	if not model or not model.Parent or not model:IsA("Model") then
		return false
	end
	if model.Name ~= "Drone" then
		return false
	end
	if model:GetAttribute("Destroyed") == true then
		return false
	end
	if model:GetAttribute("Explodedr") == true then
		return false
	end
	-- take every live drone with an id + anchor, including FPV
	if not hasDroneId(model) then
		return false
	end
	return getAnchor(model) ~= nil
end

-- TOR ignores these drone types (by DroneName / child model name)
local function isTorExcludedTarget(model)
	if not model then
		return true
	end
	local names = {}
	local function push(v)
		if typeof(v) == "string" and v ~= "" then
			table.insert(names, string.lower(v))
		end
	end
	push(model:GetAttribute("DroneName"))
	push(model.Name)
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Model") and not string.find(child.Name, "UAI_", 1, true) then
			push(child.Name)
		end
	end

	for _, n in ipairs(names) do
		-- FPV Mk. I / Mk1
		if string.find(n, "fpv", 1, true) and (string.find(n, "mk", 1, true) or string.find(n, "мк", 1, true)) then
			return true
		end
		-- FPV (Legacy) / FPVOld
		if string.find(n, "legacy", 1, true) or n == "fpvold" or string.find(n, "fpv (legacy)", 1, true) then
			return true
		end
		-- FPV (k. ... ) short / common blocked FPV labels
		if string.find(n, "fpv (k", 1, true) or n == "fpv (k." then
			return true
		end
		-- Hornet / Lancet / Switching
		if string.find(n, "hornet", 1, true)
			or string.find(n, "lancet", 1, true)
			or string.find(n, "switching", 1, true) then
			return true
		end
	end
	return false
end

local function listDrones()
	local out = {}
	local drones = workspace:FindFirstChild("Drones")
	if not drones then
		return out
	end
	local function addFolder(folder)
		if not folder then
			return
		end
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and child.Name == "Drone" and isValidFireTarget(child) then
				table.insert(out, child)
			end
		end
	end
	addFolder(drones:FindFirstChild("SpawnedDrones"))
	local scout = drones:FindFirstChild("Scout")
	addFolder(scout and scout:FindFirstChild("Spawned"))
	return out
end

local function listTorDrones()
	local out = {}
	for _, drone in ipairs(listDrones()) do
		if not isTorExcludedTarget(drone) then
			table.insert(out, drone)
		end
	end
	return out
end

----------------------------------------------------------------
-- Drone ESP
----------------------------------------------------------------
local esp = {
	on = false,
	tracked = {},
	updateConn = nil,
	hooks = {},
}

local COLOR_BOT = Color3.fromRGB(255, 70, 70)
local COLOR_PLAYER = Color3.fromRGB(60, 180, 255)
local TEXT_BOT = Color3.fromRGB(255, 180, 180)
local TEXT_PLAYER = Color3.fromRGB(160, 230, 255)
local ESP_MAX_DIST = 20000

local function resolvePilotName(userId)
	if not userId or userId <= 0 then
		return nil
	end
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		return plr.DisplayName ~= "" and plr.DisplayName or plr.Name
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" then
		return name
	end
	return tostring(userId)
end

local function readControl(drone)
	local isPlayer = drone:GetAttribute("IsPlayerDrone") == true
	local ownerId = drone:GetAttribute("OwnerUserId")
	if typeof(ownerId) ~= "number" then
		ownerId = nil
	end
	if ownerId and ownerId > 0 then
		isPlayer = true
	end
	local pilot = isPlayer and resolvePilotName(ownerId) or nil
	return isPlayer, ownerId, pilot
end

local function espUntrack(drone)
	local data = esp.tracked[drone]
	if not data then
		return
	end
	for _, c in ipairs(data.conns or {}) do
		c:Disconnect()
	end
	if data.highlight then
		data.highlight:Destroy()
	end
	if data.billboard then
		data.billboard:Destroy()
	end
	esp.tracked[drone] = nil
end

local function espTrack(drone)
	if not esp.on or esp.tracked[drone] then
		return
	end
	if not drone:IsA("Model") or drone.Name ~= "Drone" then
		return
	end
	local oldHl = drone:FindFirstChild("UAI_DroneESP")
	if oldHl then
		oldHl:Destroy()
	end
	local oldBb = drone:FindFirstChild("UAI_DroneESP_BB")
	if oldBb then
		oldBb:Destroy()
	end
	local anchor = getAnchor(drone)
	if not anchor then
		return
	end

	local isPlayer = select(1, readControl(drone))
	local hl = Instance.new("Highlight")
	hl.Name = "UAI_DroneESP"
	hl.Adornee = drone
	hl.FillTransparency = 0.55
	hl.OutlineTransparency = 0
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor = isPlayer and COLOR_PLAYER or COLOR_BOT
	hl.Parent = drone

	local bb = Instance.new("BillboardGui")
	bb.Name = "UAI_DroneESP_BB"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(200, 48)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.MaxDistance = ESP_MAX_DIST
	bb.Parent = drone

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextStrokeTransparency = 0.3
	label.TextWrapped = true
	label.TextColor3 = isPlayer and TEXT_PLAYER or TEXT_BOT
	label.Text = getDroneType(drone)
	label.Parent = bb

	local conns = {
		drone.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				espUntrack(drone)
			end
		end),
	}

	esp.tracked[drone] = {
		highlight = hl,
		billboard = bb,
		label = label,
		isPlayer = isPlayer,
		conns = conns,
	}
end

local function espScan()
	local drones = workspace:FindFirstChild("Drones")
	if not drones then
		return
	end
	local function scan(folder)
		if not folder then
			return
		end
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and child.Name == "Drone" then
				espTrack(child)
			end
		end
	end
	scan(drones:FindFirstChild("SpawnedDrones"))
	local scout = drones:FindFirstChild("Scout")
	scan(scout and scout:FindFirstChild("Spawned"))
end

local function espHookFolders()
	for _, c in ipairs(esp.hooks) do
		c:Disconnect()
	end
	esp.hooks = {}
	local drones = workspace:FindFirstChild("Drones")
	if not drones then
		return
	end
	local function hook(folder)
		if not folder then
			return
		end
		table.insert(esp.hooks, folder.ChildAdded:Connect(function(child)
			task.defer(function()
				if esp.on and child.Parent and child:IsA("Model") and child.Name == "Drone" then
					espTrack(child)
				end
			end)
		end))
		table.insert(esp.hooks, folder.ChildRemoved:Connect(function(child)
			if esp.tracked[child] then
				espUntrack(child)
			end
		end))
	end
	hook(drones:FindFirstChild("SpawnedDrones"))
	local scout = drones:FindFirstChild("Scout")
	hook(scout and scout:FindFirstChild("Spawned"))
end

local function stopEsp()
	esp.on = false
	if esp.updateConn then
		esp.updateConn:Disconnect()
		esp.updateConn = nil
	end
	for _, c in ipairs(esp.hooks) do
		c:Disconnect()
	end
	esp.hooks = {}
	for drone in pairs(esp.tracked) do
		espUntrack(drone)
	end
end

local function startEsp()
	stopEsp()
	esp.on = true
	espHookFolders()
	espScan()
	esp.updateConn = RunService.Heartbeat:Connect(function()
		local char = LOCAL.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local root = hrp and hrp.Position
		if not root then
			return
		end
		for drone, data in pairs(esp.tracked) do
			if not drone.Parent then
				espUntrack(drone)
			else
				local isPlayer, _, pilot = readControl(drone)
				local typeName = getDroneType(drone)
				data.highlight.FillColor = isPlayer and COLOR_PLAYER or COLOR_BOT
				data.label.TextColor3 = isPlayer and TEXT_PLAYER or TEXT_BOT
				local anchor = getAnchor(drone)
				if anchor then
					local dist = (anchor.Position - root).Magnitude
					if dist > ESP_MAX_DIST then
						data.highlight.Enabled = false
						data.billboard.Enabled = false
					else
						data.highlight.Enabled = true
						data.billboard.Enabled = true
						local who = isPlayer and (pilot and ("PLAYER:" .. pilot) or "PLAYER") or "BOT"
						data.label.Text = string.format("%s\n%s  [%.0fm]", typeName, who, dist)
					end
				end
			end
		end
	end)
end

_G.UAI_StopDroneESP = stopEsp

----------------------------------------------------------------
-- People ESP (Civilians / Defenders / Operators)
----------------------------------------------------------------
local people = {
	on = false,
	tracked = {},
	updateConn = nil,
	hooks = {},
}

local COLOR_CIV = Color3.fromRGB(60, 220, 90)      -- Civilization / Civilians = green
local COLOR_DEF = Color3.fromRGB(70, 170, 255)     -- Defender = blue
local COLOR_OP = Color3.fromRGB(255, 70, 70)       -- Operator = red
local COLOR_UNK = Color3.fromRGB(200, 200, 200)
local TEXT_CIV = Color3.fromRGB(170, 255, 190)
local TEXT_DEF = Color3.fromRGB(170, 220, 255)
local TEXT_OP = Color3.fromRGB(255, 180, 180)
local TEXT_UNK = Color3.fromRGB(220, 220, 220)
local PEOPLE_MAX_DIST = 20000

local function getPlayerFaction(plr)
	if not plr then
		return "Unknown"
	end
	local char = plr.Character
	local teamAttr = char and char:GetAttribute("Team")
	if typeof(teamAttr) == "string" and teamAttr ~= "" then
		return teamAttr
	end
	if plr.Team and plr.Team.Name ~= "" then
		return plr.Team.Name
	end
	return "Unknown"
end

local function factionVisual(faction)
	local f = string.lower(tostring(faction or ""))
	if string.find(f, "civil", 1, true) then
		return COLOR_CIV, TEXT_CIV, "CIV"
	elseif string.find(f, "defend", 1, true) then
		return COLOR_DEF, TEXT_DEF, "DEF"
	elseif string.find(f, "oper", 1, true) then
		return COLOR_OP, TEXT_OP, "OP"
	end
	return COLOR_UNK, TEXT_UNK, "?"
end

local function peopleUntrack(plr)
	local data = people.tracked[plr]
	if not data then
		return
	end
	for _, c in ipairs(data.conns or {}) do
		c:Disconnect()
	end
	if data.highlight then
		data.highlight:Destroy()
	end
	if data.billboard then
		data.billboard:Destroy()
	end
	people.tracked[plr] = nil
end

local function peopleTrack(plr)
	if not people.on or not plr or plr == LOCAL or people.tracked[plr] then
		return
	end
	local char = plr.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("HumanoidRootPart", true)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum then
		return
	end

	local oldHl = char:FindFirstChild("UAI_PeopleESP")
	if oldHl then
		oldHl:Destroy()
	end
	local oldBb = char:FindFirstChild("UAI_PeopleESP_BB")
	if oldBb then
		oldBb:Destroy()
	end

	local faction = getPlayerFaction(plr)
	local fill, textCol, short = factionVisual(faction)

	local hl = Instance.new("Highlight")
	hl.Name = "UAI_PeopleESP"
	hl.Adornee = char
	hl.FillTransparency = 0.55
	hl.OutlineTransparency = 0
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillColor = fill
	hl.Parent = char

	local bb = Instance.new("BillboardGui")
	bb.Name = "UAI_PeopleESP_BB"
	bb.Adornee = hrp
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(180, 42)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.MaxDistance = PEOPLE_MAX_DIST
	bb.Parent = char

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextStrokeTransparency = 0.3
	label.TextWrapped = true
	label.TextColor3 = textCol
	label.Text = string.format("%s\n%s", plr.DisplayName ~= "" and plr.DisplayName or plr.Name, short)
	label.Parent = bb

	local conns = {
		char.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				peopleUntrack(plr)
			end
		end),
		hum.Died:Connect(function()
			peopleUntrack(plr)
		end),
	}

	people.tracked[plr] = {
		highlight = hl,
		billboard = bb,
		label = label,
		faction = faction,
		conns = conns,
	}
end

local function peopleRescan()
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LOCAL then
			if people.tracked[plr] and plr.Character ~= people.tracked[plr].highlight.Adornee then
				peopleUntrack(plr)
			end
			if not people.tracked[plr] then
				peopleTrack(plr)
			end
		end
	end
end

local function stopPeople()
	people.on = false
	if people.updateConn then
		people.updateConn:Disconnect()
		people.updateConn = nil
	end
	for _, c in ipairs(people.hooks) do
		c:Disconnect()
	end
	people.hooks = {}
	for plr in pairs(people.tracked) do
		peopleUntrack(plr)
	end
end

local function startPeople()
	stopPeople()
	people.on = true

	table.insert(people.hooks, Players.PlayerAdded:Connect(function(plr)
		table.insert(people.hooks, plr.CharacterAdded:Connect(function()
			task.defer(function()
				if people.on then
					peopleTrack(plr)
				end
			end)
		end))
		if plr.Character then
			task.defer(function()
				if people.on then
					peopleTrack(plr)
				end
			end)
		end
	end))
	table.insert(people.hooks, Players.PlayerRemoving:Connect(function(plr)
		peopleUntrack(plr)
	end))
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LOCAL then
			table.insert(people.hooks, plr.CharacterAdded:Connect(function()
				task.defer(function()
					if people.on then
						peopleUntrack(plr)
						peopleTrack(plr)
					end
				end)
			end))
		end
	end

	peopleRescan()
	people.updateConn = RunService.Heartbeat:Connect(function()
		if not people.on then
			return
		end
		local myChar = LOCAL.Character
		local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
		local root = myHrp and myHrp.Position
		if not root then
			return
		end
		for plr, data in pairs(people.tracked) do
			local char = plr.Character
			if not char or not char.Parent then
				peopleUntrack(plr)
			else
				local faction = getPlayerFaction(plr)
				local fill, textCol, short = factionVisual(faction)
				data.faction = faction
				data.highlight.FillColor = fill
				data.label.TextColor3 = textCol
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hrp then
					local dist = (hrp.Position - root).Magnitude
					if dist > PEOPLE_MAX_DIST then
						data.highlight.Enabled = false
						data.billboard.Enabled = false
					else
						data.highlight.Enabled = true
						data.billboard.Enabled = true
						local nick = plr.DisplayName ~= "" and plr.DisplayName or plr.Name
						data.label.Text = string.format("%s\n%s  [%.0fm]", nick, short, dist)
					end
				end
			end
		end
	end)
end

_G.UAI_StopPeopleESP = stopPeople

----------------------------------------------------------------
-- Auto Pantsir
----------------------------------------------------------------
local auto = {
	on = false,
	conn = nil,
	status = "off",
	lastFire = 0,
	lastAim = 0,
	lastWeaponSwitch = 0,
	gunsHolding = false,
	currentTarget = nil,
	firing = false,
	firedIds = {}, -- one shot per drone, then next
	gen = 0,
	setButton = nil,
}

-- only one auto loop across reloads
if type(_G.UAI_AutoGen) ~= "number" then
	_G.UAI_AutoGen = 0
end

local AIM_INTERVAL = 0.1
local FIRE_INTERVAL_ROCKET = 1.35
local FIRE_INTERVAL_BURST = 0.45
local WEAPON_SWITCH_INTERVAL = 1.0
local MAX_RANGE = 45000
local MAX_ACTIVE_PANTSIR_SAMS = 2 -- game rejects more with "maximum number of total launched SAMs"
local MIN_PITCH = -0.4363323129985824
local MAX_PITCH = 1.5707963267948966

local function findSeatedVehicle(expectedName, hasParts)
	local char = LOCAL.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then
		return nil
	end
	local model = seat:FindFirstAncestorWhichIsA("Model")
	while model and model.Parent do
		local nameOk = true
		if expectedName then
			nameOk = string.find(string.lower(model.Name), string.lower(expectedName), 1, true) ~= nil
		end
		if nameOk and hasParts(model) then
			return model
		end
		model = model.Parent:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

local function findActivePantsir()
	local seated = findSeatedVehicle(nil, function(model)
		return model:FindFirstChild("GUN_Remotes") ~= nil and model:FindFirstChild("MainModel") ~= nil
	end)
	if seated then
		return seated, nil
	end
	for _, gui in ipairs(PlayerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and string.find(gui.Name, "PantsirGui", 1, true) then
			local obj = gui:FindFirstChild("PantsirObj")
			if obj and obj:IsA("ObjectValue") and obj.Value and obj.Value.Parent then
				return obj.Value, gui
			end
		end
	end
	return nil, nil
end

local function getPantsirParts(pantsir)
	local remotes = pantsir:FindFirstChild("GUN_Remotes")
	local states = pantsir:FindFirstChild("GUN_States")
	local main = pantsir:FindFirstChild("MainModel")
	local other = main and main:FindFirstChild("Other")
	local mainBashnya = other and other:FindFirstChild("MainBashnya")
	local camAtt = mainBashnya and mainBashnya:FindFirstChild("CamAtt")
	local bashnya = main and main:FindFirstChild("Bashnya")
	local radar = bashnya and bashnya:FindFirstChild("Radar")
	local radarPrimary = radar and radar.PrimaryPart
	if not remotes or not states or not camAtt then
		return nil
	end
	return {
		remotes = remotes,
		states = states,
		camAtt = camAtt,
		radarPrimary = radarPrimary,
		aim = remotes:FindFirstChild("Bashnya_Aim"),
		fire = remotes:FindFirstChild("Fire"),
		changeWeapon = remotes:FindFirstChild("ChangeWeapon"),
		changeMode = remotes:FindFirstChild("ChangeMode_Request"),
		toggleRadar = remotes:FindFirstChild("Toggle_Radar"),
		weapon = states:FindFirstChild("CurrentWeapon"),
		gunsMode = states:FindFirstChild("CurrentGunsGuidance"),
		samMode = states:FindFirstChild("CurrentSAMGuidance"),
		radarEnabled = states:FindFirstChild("RadarEnabled"),
		samAmmo = states:FindFirstChild("SAMAmmos"),
		gunAmmo = states:FindFirstChild("GUNAmmos"),
		samCd = states:FindFirstChild("SAMCooldownSeconds"),
		gunCd = states:FindFirstChild("GUNCooldownSeconds"),
		samReloading = states:FindFirstChild("SAMReloading"),
		gunsReloading = states:FindFirstChild("GunsReloading"),
		pantsir = pantsir,
	}
end

local function countActivePantsirSams(pantsir)
	if not pantsir then
		return 0
	end
	local spawned = pantsir:FindFirstChild("SpawnedMissiles")
	if not spawned then
		return 0
	end
	local n = 0
	for _, child in ipairs(spawned:GetChildren()) do
		if child:IsA("Model") then
			local lower = string.lower(child.Name)
			if string.find(lower, "rocket", 1, true)
				or string.find(lower, "missile", 1, true)
				or string.find(lower, "sam", 1, true)
				or string.find(lower, "pantsir", 1, true) then
				n += 1
			end
		end
	end
	return n
end

local function firePantsirRocket(ctx, target)
	if not ctx or not ctx.fire or not target then
		return false, "no remote"
	end
	local beforeAmmo = ctx.samAmmo and ctx.samAmmo.Value or 0
	local beforeCd = ctx.samCd and ctx.samCd.Value or 0
	local beforeActive = countActivePantsirSams(ctx.pantsir)
	pcall(function()
		ctx.fire:FireServer("Launch", target)
	end)
	for _ = 1, 8 do
		task.wait(0.05)
		local ammoNow = ctx.samAmmo and ctx.samAmmo.Value or beforeAmmo
		local cdNow = ctx.samCd and ctx.samCd.Value or beforeCd
		local activeNow = countActivePantsirSams(ctx.pantsir)
		if ammoNow < beforeAmmo or cdNow > beforeCd or activeNow > beforeActive then
			return true, "ok"
		end
	end
	local activeNow = countActivePantsirSams(ctx.pantsir)
	if activeNow >= MAX_ACTIVE_PANTSIR_SAMS then
		return false, "max_sams"
	end
	-- treat unknown result as accepted to avoid a second rocket on same drone
	return true, "assumed_ok"
end

local function computeAim(camAtt, targetPos)
	local offset = camAtt.WorldCFrame:PointToObjectSpace(targetPos)
	local yaw = math.atan2(-offset.X, -offset.Z)
	local horiz = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
	local pitch = math.atan2(offset.Y, math.max(horiz, 1e-4))
	pitch = math.clamp(pitch, MIN_PITCH, MAX_PITCH)
	local cf = camAtt.WorldCFrame * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	return yaw, pitch, cf.Position, cf.LookVector
end

local function droneKey(drone)
	local id = drone:GetAttribute("DroneId")
	if id ~= nil then
		return tostring(id)
	end
	return tostring(drone)
end

local function pruneFiredIds()
	local alive = {}
	for _, drone in ipairs(listDrones()) do
		alive[droneKey(drone)] = true
	end
	for key in pairs(auto.firedIds) do
		if not alive[key] then
			auto.firedIds[key] = nil
		end
	end
end

local function markFired(drone)
	if drone then
		auto.firedIds[droneKey(drone)] = os.clock()
		markSharedTarget(drone:GetAttribute("DroneId") or droneKey(drone))
	end
end

local function wasFired(drone)
	return drone ~= nil and auto.firedIds[droneKey(drone)] ~= nil
end

local function pickTarget(fromPos)
	pruneFiredIds()
	heartbeatBotSlot()
	local myIndex, botCount = getMyBotIndex()

	local free = {}
	for _, drone in ipairs(listDrones()) do
		local id = drone:GetAttribute("DroneId") or droneKey(drone)
		if not wasFired(drone) and not isSharedTarget(id) then
			local anchor = getAnchor(drone)
			if anchor then
				local dist = (anchor.Position - fromPos).Magnitude
				if dist <= MAX_RANGE then
					table.insert(free, { drone = drone, id = id, dist = dist })
				end
			end
		end
	end
	table.sort(free, function(a, b)
		return a.dist < b.dist
	end)

	-- bot #1 takes 1st free, bot #2 takes 2nd free, etc.
	local startAt = myIndex
	for i = startAt, #free, botCount do
		local item = free[i]
		if item and tryClaimSharedTarget(item.id) then
			return item.drone
		end
	end
	-- fallback: claim any remaining free target
	for _, item in ipairs(free) do
		if tryClaimSharedTarget(item.id) then
			return item.drone
		end
	end
	return nil
end



local function stopGunsHold(ctx)
	if auto.gunsHolding and ctx and ctx.fire then
		pcall(function()
			ctx.fire:FireServer("Stop")
		end)
	end
	auto.gunsHolding = false
end

local function stopAuto()
	auto.on = false
	auto.status = "off"
	auto.currentTarget = nil
	auto.firing = false
	auto.firedIds = {}
	auto.gen += 1
	_G.UAI_AutoGen = auto.gen
	if auto.conn then
		auto.conn:Disconnect()
		auto.conn = nil
	end
	local pantsir = select(1, findActivePantsir())
	if pantsir then
		local ctx = getPantsirParts(pantsir)
		stopGunsHold(ctx)
	end
end

local function ensureModes(ctx)
	if ctx.radarEnabled and ctx.radarEnabled.Value == false and ctx.toggleRadar then
		pcall(function()
			ctx.toggleRadar:FireServer()
		end)
	end
	-- Prefer Automatic gun mode for Burst
	if ctx.gunsMode and ctx.gunsMode.Value == "Manual" and ctx.changeMode then
		pcall(function()
			ctx.changeMode:FireServer("CurrentGUNSGuidance")
		end)
	end
	-- SAM stays Automatic so the turret aims itself (no mouse aiming)
	if ctx.samMode and ctx.samMode.Value ~= "Automatic" and ctx.changeMode then
		pcall(function()
			ctx.changeMode:FireServer("CurrentSAMGuidance")
		end)
	end
end

local function startAuto()
	stopAuto()
	auto.on = true
	auto.status = "waiting seat"
	auto.gen += 1
	local myGen = auto.gen
	_G.UAI_AutoGen = myGen
	auto.conn = RunService.Heartbeat:Connect(function()
		if not auto.on or myGen ~= _G.UAI_AutoGen then
			return
		end
		local pantsir = select(1, findActivePantsir())
		if not pantsir then
			auto.status = "сядь в Панцирь"
			auto.currentTarget = nil
			return
		end
		local ctx = getPantsirParts(pantsir)
		if not ctx or not ctx.aim or not ctx.fire then
			auto.status = "нет ремоутов"
			return
		end
		ensureModes(ctx)
		stopGunsHold(ctx)

		local now = os.clock()
		local weapon = ctx.weapon and ctx.weapon.Value or "Guns"
		local samAmmo = ctx.samAmmo and ctx.samAmmo.Value or 0
		local samCd = ctx.samCd and ctx.samCd.Value or 0
		local samReloading = ctx.samReloading and ctx.samReloading.Value

		-- Always stay on Rockets; never use 30mm
		if weapon ~= "Rockets" then
			auto.currentTarget = nil
			if ctx.changeWeapon and now - auto.lastWeaponSwitch >= WEAPON_SWITCH_INTERVAL then
				auto.lastWeaponSwitch = now
				pcall(function()
					ctx.fire:FireServer("Stop")
				end)
				pcall(function()
					ctx.changeWeapon:FireServer()
				end)
				auto.status = "→ только ракеты"
			end
			return
		end

		-- No rockets / reloading → do NOT aim at enemies; wait for ammo
		if samAmmo <= 0 or samReloading then
			auto.currentTarget = nil
			auto.status = samReloading and "перезарядка ракет — не целюсь" or "ракеты пусты — жду патроны"
			return
		end

		local origin = ctx.radarPrimary and ctx.radarPrimary.Position or ctx.camAtt.WorldPosition
		local target = pickTarget(origin)
		auto.currentTarget = target
		if not target then
			auto.status = "нет целей"
			return
		end

		local anchor = getAnchor(target)
		if not anchor then
			auto.currentTarget = nil
			return
		end
		local dist = (anchor.Position - origin).Magnitude
		local typeName = getDroneType(target)
		local who = (target:GetAttribute("IsPlayerDrone") == true) and "PLAYER" or "BOT"
		auto.status = string.format("%s %s %.0fm [1 выстрел] x%d", who, typeName, dist, samAmmo)

		if now - auto.lastAim >= AIM_INTERVAL then
			auto.lastAim = now
			local yaw, pitch, pos, look = computeAim(ctx.camAtt, anchor.Position)
			pcall(function()
				ctx.aim:FireServer(yaw, pitch, pos, look)
			end)
		end

		-- one rocket per drone, then hop. On SAM air-limit: wait, do NOT disable auto
		local activeSams = countActivePantsirSams(pantsir)
		if activeSams >= MAX_ACTIVE_PANTSIR_SAMS then
			auto.status = string.format("лимит SAM в воздухе (%d) — жду", activeSams)
			return
		end

		if samCd <= 0 and not auto.firing and now - auto.lastFire >= FIRE_INTERVAL_ROCKET then
			auto.firing = true
			auto.lastFire = now
			local shotTarget = target
			-- mark FIRST so the same drone never gets a second launch
			markFired(shotTarget)
			auto.currentTarget = nil
			task.spawn(function()
				local ok, reason = firePantsirRocket(ctx, shotTarget)
				if ok then
					-- cut possible second auto-salvo from SAM Automatic
				pcall(function()
						ctx.fire:FireServer("Stop")
					end)
					auto.status = "пуск OK → следующий"
				elseif reason == "max_sams" then
					-- keep auto ON; allow retry on this drone when a slot frees
					auto.firedIds[droneKey(shotTarget)] = nil
					auto.status = "лимит SAM — жду слот"
					auto.lastFire = now - (FIRE_INTERVAL_ROCKET - 0.6)
				else
					-- do not unmark: prevents double-shot on same drone
					auto.status = "пуск спорный — дрон пропущен"
				end
				task.wait(0.15)
				auto.firing = false
			end)
		end
	end)
end

_G.UAI_StopAutoPantsir = stopAuto

----------------------------------------------------------------
----------------------------------------------------------------
-- Auto TOR-M1
----------------------------------------------------------------
local tor = {
	on = false,
	conn = nil,
	status = "off",
	lastFire = 0,
	lastAim = 0,
	currentTarget = nil,
	lockSince = nil,
	firing = false,
	firedIds = {},
	gen = 0,
	smoothYaw = nil,
	smoothPitch = nil,
	lastSentYaw = nil,
	lastSentPitch = nil,
}

if type(_G.UAI_TorGen) ~= "number" then
	_G.UAI_TorGen = 0
end

local TOR_AIM_INTERVAL = 0.12
local TOR_FIRE_INTERVAL = 4.15
local TOR_FIRE_RANGE = 17000
local TOR_DETECT_RANGE = 99999
local TOR_AIM_SETTLE = 0
local TOR_FIRE_RETRY = 0.35
local TOR_AIM_DEADZONE = 0.012
local TOR_AIM_SMOOTH = 0.55
local TOR_MISS_GRACE = 1.4
local TOR_MISS_MAX_WAIT = 16

local function findActiveTor()
	local seated = findSeatedVehicle("Tor-M1", function(model)
		return model:FindFirstChild("GUN_Remotes") ~= nil
	end)
	if seated then
		return seated, nil
	end
	for _, guiObj in ipairs(PlayerGui:GetChildren()) do
		if guiObj:IsA("ScreenGui") and string.find(guiObj.Name, "TorM1Gui", 1, true) then
			local obj = guiObj:FindFirstChild("TorObject")
			if obj and obj:IsA("ObjectValue") and obj.Value and obj.Value.Parent then
				if string.find(string.lower(obj.Value.Name), "tor%-m1") or string.find(string.lower(obj.Value.Name), "tor") then
					return obj.Value, guiObj
				end
			end
		end
	end
	return nil, nil
end

local function getTorParts(torModel)
	local remotes = torModel:FindFirstChild("GUN_Remotes")
	local states = torModel:FindFirstChild("GUN_States")
	local corpus = torModel:FindFirstChild("TorCorpus")
	local main = corpus and (corpus.PrimaryPart or corpus:FindFirstChild("Main"))
	local camAtt = main and main:FindFirstChild("Camera")
	local bashnya = torModel:FindFirstChild("Bashnya")
	local radar = bashnya and bashnya:FindFirstChild("Radar")
	local radarPrimary = radar and radar.PrimaryPart
	if not remotes or not states or not camAtt then
		return nil
	end
	return {
		remotes = remotes,
		states = states,
		camAtt = camAtt,
		radarPrimary = radarPrimary,
		radarModel = radar,
		aim = remotes:FindFirstChild("Bashnya_Aim"),
		fire = remotes:FindFirstChild("Fire"),
		toggleRadar = remotes:FindFirstChild("Toggle_Radar"),
		changeSamMode = remotes:FindFirstChild("ChangeSamMode_Request"),
		samAmmo = states:FindFirstChild("SAMAmmos"),
		samCd = states:FindFirstChild("SAMCooldownSeconds"),
		samReloading = states:FindFirstChild("SAMReloading"),
		radarEnabled = states:FindFirstChild("RadarEnabled"),
		samMode = states:FindFirstChild("CurrentSAMGuidance"),
		torModel = torModel,
	}
end

local function torKey(drone)
	local id = drone:GetAttribute("DroneId")
	if id ~= nil then
		return tostring(id)
	end
	return tostring(drone)
end

local function pruneTorFired()
	local alive = {}
	for _, drone in ipairs(listTorDrones()) do
		alive[torKey(drone)] = true
	end
	for key in pairs(tor.firedIds) do
		if not alive[key] then
			tor.firedIds[key] = nil
		end
	end
end

local function markTorFired(drone, dist)
	if not drone then
		return
	end
	local anchor = getAnchor(drone)
	local y = anchor and anchor.Position.Y or 0
	tor.firedIds[torKey(drone)] = {
		t = os.clock(),
		dist = typeof(dist) == "number" and dist or 0,
		sawMissile = false,
		alt = y,
		lastY = y,
		lastT = os.clock(),
	}
	markSharedTarget(drone:GetAttribute("DroneId") or torKey(drone))
end

local function wasTorFired(drone)
	return drone ~= nil and tor.firedIds[torKey(drone)] ~= nil
end

local function getTorShotInfo(drone)
	if not drone then
		return nil
	end
	local info = tor.firedIds[torKey(drone)]
	if typeof(info) == "table" then
		return info
	end
	return nil
end

local function isTorKillConfirmed(drone, shotInfo)
	if not drone or not drone.Parent then
		return true
	end
	if drone:GetAttribute("Destroyed") == true or drone:GetAttribute("Explodedr") == true then
		return true
	end
	if drone:GetAttribute("IsDiving") == true then
		return true
	end
	local anchor = getAnchor(drone)
	if not anchor then
		return true
	end
	if typeof(shotInfo) == "table" and typeof(shotInfo.alt) == "number" then
		if shotInfo.alt - anchor.Position.Y >= 60 then
			return true
		end
		if typeof(shotInfo.lastY) == "number" and typeof(shotInfo.lastT) == "number" then
			local dt = os.clock() - shotInfo.lastT
			if dt > 0.05 and (anchor.Position.Y - shotInfo.lastY) / dt <= -55 then
				return true
			end
		end
	end
	return false
end

local function isStillValidTorTarget(drone, fromPos)
	if isTorKillConfirmed(drone, drone and tor.firedIds[torKey(drone)]) then
		return false
	end
	if not isValidFireTarget(drone) or isTorExcludedTarget(drone) then
		return false
	end
	if drone:GetAttribute("IsDiving") == true then
		return false
	end
	local anchor = getAnchor(drone)
	if not anchor then
		return false
	end
	if fromPos and (anchor.Position - fromPos).Magnitude > TOR_DETECT_RANGE then
		return false
	end
	return true
end

local function countActiveTorMissiles(torModel)
	if not torModel then
		return 0
	end
	local spawned = torModel:FindFirstChild("SpawnedMissiles")
	if not spawned then
		return 0
	end
	local n = 0
	for _, child in ipairs(spawned:GetChildren()) do
		if child:IsA("Model") or child:IsA("BasePart") then
			local lower = string.lower(child.Name)
			if string.find(lower, "rocket", 1, true)
				or string.find(lower, "missile", 1, true)
				or string.find(lower, "sam", 1, true)
				or string.find(lower, "tor", 1, true)
				or string.find(lower, "zur", 1, true) then
				n += 1
			end
		end
	end
	return n
end

local function getTorRadarGui(torModel)
	for _, guiObj in ipairs(PlayerGui:GetChildren()) do
		if guiObj:IsA("ScreenGui") and string.find(guiObj.Name, "TorM1Gui", 1, true) then
			local obj = guiObj:FindFirstChild("TorObject")
			if not obj or not obj:IsA("ObjectValue") or obj.Value == nil or obj.Value == torModel then
				return guiObj
			end
		end
	end
	if torModel then
		local embedded = torModel:FindFirstChild("TorM1Gui")
		if embedded and embedded:IsA("ScreenGui") then
			return embedded
		end
	end
	return nil
end

local function getTorRadarBlips(torModel)
	local gui = getTorRadarGui(torModel)
	if not gui then
		return {}
	end
	local display = gui:FindFirstChild("RadarDisplay", true)
	local folder = display and display:FindFirstChild("Targets")
	if not folder then
		return {}
	end
	local center = display.AbsolutePosition + display.AbsoluteSize * 0.5
	local radius = math.max(display.AbsoluteSize.X, display.AbsoluteSize.Y) * 0.5
	if radius < 1 then
		radius = 1
	end
	local blips = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child.Name ~= "TargetTemplate" and child:IsA("GuiObject") and child.Visible then
			local abs = child.AbsolutePosition + child.AbsoluteSize * 0.5
			local dx = abs.X - center.X
			local dy = abs.Y - center.Y
			table.insert(blips, {
				ang = math.atan2(dx, -dy),
				rangeFrac = math.clamp(math.sqrt(dx * dx + dy * dy) / radius, 0, 1.15),
			})
		end
	end
	return blips
end

local function matchDroneToRadarBlips(drone, fromPos, blips)
	if not drone or not fromPos or not blips or #blips == 0 then
		return false
	end
	local anchor = getAnchor(drone)
	if not anchor then
		return false
	end
	local offset = anchor.Position - fromPos
	local dist = math.max(offset.Magnitude, 1)
	local yaw = math.atan2(offset.X, offset.Z)
	local rangeFrac = dist / TOR_DETECT_RANGE
	local best = math.huge
	for _, blip in ipairs(blips) do
		local dang = math.abs(yaw - blip.ang)
		dang = math.min(dang, math.abs(dang - math.pi * 2))
		local score = dang * 1.7 + math.abs(rangeFrac - blip.rangeFrac) * 0.9
		if score < best then
			best = score
		end
	end
	return best <= 0.85
end

local function pickTorTarget(fromPos, torModel)
	pruneTorFired()
	heartbeatBotSlot()
	if isStillValidTorTarget(tor.currentTarget, fromPos) then
		local curId = tor.currentTarget:GetAttribute("DroneId") or torKey(tor.currentTarget)
		if not isSharedTarget(curId) then
			markSharedTarget(curId)
			return tor.currentTarget, 0
		end
	end
	tor.currentTarget = nil
	tor.lockSince = nil

	local blips = getTorRadarBlips(torModel)
	local myIndex, botCount = getMyBotIndex()
	local free = {}
	for _, drone in ipairs(listTorDrones()) do
		local id = drone:GetAttribute("DroneId") or torKey(drone)
		if not wasTorFired(drone) and not isSharedTarget(id) then
			local anchor = getAnchor(drone)
			if anchor then
				local dist = (anchor.Position - fromPos).Magnitude
				if dist <= TOR_DETECT_RANGE then
					local onRadar = matchDroneToRadarBlips(drone, fromPos, blips)
					table.insert(free, {
						drone = drone,
						id = id,
						dist = dist,
						score = dist - (onRadar and 250 or 0),
					})
				end
			end
		end
	end
	table.sort(free, function(a, b)
		if a.score == b.score then
			return a.dist < b.dist
		end
		return a.score < b.score
	end)

	for i = myIndex, #free, botCount do
		local item = free[i]
		if item and tryClaimSharedTarget(item.id) then
			return item.drone, #blips
		end
	end
	for _, item in ipairs(free) do
		if tryClaimSharedTarget(item.id) then
			return item.drone, #blips
		end
	end
	return nil, #blips
end

local function stopTor()
	tor.on = false
	tor.status = "off"
	tor.currentTarget = nil
	tor.lockSince = nil
	tor.firing = false
	tor.firedIds = {}
	tor.smoothYaw = nil
	tor.smoothPitch = nil
	tor.lastSentYaw = nil
	tor.lastSentPitch = nil
	tor.gen += 1
	_G.UAI_TorGen = tor.gen
	if tor.conn then
		tor.conn:Disconnect()
		tor.conn = nil
	end
end

local function ensureTorModes(ctx)
	if ctx.radarEnabled and ctx.radarEnabled.Value == false and ctx.toggleRadar then
		pcall(function()
			ctx.toggleRadar:FireServer()
		end)
	end
	if ctx.samMode and ctx.samMode.Value ~= "Automatic" and ctx.changeSamMode then
		pcall(function()
			ctx.changeSamMode:FireServer()
		end)
	end
end

local function fireTorRocket(ctx, target)
	if not ctx or not ctx.fire or not target then
		return false
	end
	local beforeAmmo = ctx.samAmmo and ctx.samAmmo.Value or 0
	local beforeCd = ctx.samCd and ctx.samCd.Value or 0
	local beforeMissiles = countActiveTorMissiles(ctx.torModel)
	pcall(function()
		ctx.fire:FireServer(target)
	end)
	for _ = 1, 8 do
		task.wait(0.05)
		local ammoNow = ctx.samAmmo and ctx.samAmmo.Value or beforeAmmo
		local cdNow = ctx.samCd and ctx.samCd.Value or beforeCd
		local missilesNow = countActiveTorMissiles(ctx.torModel)
		if ammoNow < beforeAmmo or cdNow > beforeCd or missilesNow > beforeMissiles then
			return true
		end
	end
	return true
end

local function aimTor(ctx, anchor)
	local yaw, pitch = computeAim(ctx.camAtt, anchor.Position)
	if tor.smoothYaw == nil then
		tor.smoothYaw = yaw
		tor.smoothPitch = pitch
	else
		tor.smoothYaw += (yaw - tor.smoothYaw) * TOR_AIM_SMOOTH
		tor.smoothPitch += (pitch - tor.smoothPitch) * TOR_AIM_SMOOTH
	end
	local sendYaw = math.floor(tor.smoothYaw * 30 + 0.5) / 30
	local sendPitch = math.floor(tor.smoothPitch * 30 + 0.5) / 30
	local dy = tor.lastSentYaw and math.abs(sendYaw - tor.lastSentYaw) or math.huge
	local dp = tor.lastSentPitch and math.abs(sendPitch - tor.lastSentPitch) or math.huge
	if dy < TOR_AIM_DEADZONE and dp < TOR_AIM_DEADZONE then
		return
	end
	local cf = ctx.camAtt.WorldCFrame * CFrame.Angles(0, sendYaw, 0) * CFrame.Angles(sendPitch, 0, 0)
	pcall(function()
		ctx.aim:FireServer(sendYaw, sendPitch, cf.Position, cf.LookVector)
	end)
	tor.lastSentYaw = sendYaw
	tor.lastSentPitch = sendPitch
end

local function startTor()
	stopTor()
	if auto.on then
		stopAuto()
	end
	tor.on = true
	tor.status = "waiting seat"
	tor.gen += 1
	local myGen = tor.gen
	_G.UAI_TorGen = myGen
	tor.conn = RunService.Heartbeat:Connect(function()
		if not tor.on or myGen ~= _G.UAI_TorGen then
			return
		end
		local torModel = select(1, findActiveTor())
		if not torModel then
			tor.status = "сядь в TOR-M1"
			tor.currentTarget = nil
			tor.lockSince = nil
			return
		end
		local ctx = getTorParts(torModel)
		if not ctx or not ctx.aim or not ctx.fire then
			tor.status = "нет ремоутов"
			return
		end
		ensureTorModes(ctx)

		local now = os.clock()
		local samAmmo = ctx.samAmmo and ctx.samAmmo.Value or 0
		local samCd = ctx.samCd and ctx.samCd.Value or 0
		local samReloading = ctx.samReloading and ctx.samReloading.Value
		if samAmmo <= 0 or samReloading then
			tor.currentTarget = nil
			tor.lockSince = nil
			tor.status = samReloading and "TOR перезарядка" or "TOR ракеты пусты"
			return
		end

		local origin = ctx.radarPrimary and ctx.radarPrimary.Position or ctx.camAtt.WorldPosition
		local target, radarBlips = pickTorTarget(origin, torModel)
		if target ~= tor.currentTarget then
			tor.currentTarget = target
			tor.lockSince = target and now or nil
			tor.smoothYaw = nil
			tor.smoothPitch = nil
			tor.lastSentYaw = nil
			tor.lastSentPitch = nil
		end
		if not target then
			tor.status = (radarBlips > 0) and string.format("TOR радар: %d блип(ов)", radarBlips) or "TOR: нет целей"
			return
		end

		local anchor = getAnchor(target)
		if not anchor then
			tor.currentTarget = nil
			return
		end
		local dist = (anchor.Position - origin).Magnitude
		local inFireRange = dist <= TOR_FIRE_RANGE
		local onRadar = matchDroneToRadarBlips(target, origin, getTorRadarBlips(torModel))
		local shotInfo = getTorShotInfo(target)
		local typeName = getDroneType(target)
		local who = (target:GetAttribute("IsPlayerDrone") == true) and "PLAYER" or "BOT"

		if not tor.firing and now - tor.lastAim >= TOR_AIM_INTERVAL then
			tor.lastAim = now
			aimTor(ctx, anchor)
		end

		if shotInfo then
			local age = now - shotInfo.t
			local activeMissiles = countActiveTorMissiles(torModel)
			if activeMissiles > 0 then
				shotInfo.sawMissile = true
			end
			shotInfo.lastY = anchor.Position.Y
			shotInfo.lastT = now
			if isTorKillConfirmed(target, shotInfo) then
				markTorFired(target, dist)
				tor.currentTarget = nil
				tor.lockSince = nil
				tor.status = "TOR килл/пике — следующий"
				return
			end
			if activeMissiles > 0 then
				tor.status = string.format("TOR ракета летит %.0fm", dist)
				return
			end
			local missReady = (shotInfo.sawMissile and age >= TOR_MISS_GRACE) or age >= TOR_MISS_MAX_WAIT
			if missReady and inFireRange and samCd <= 0 and not tor.firing and now - tor.lastFire >= TOR_FIRE_INTERVAL then
				tor.firedIds[torKey(target)] = nil
				tor.status = string.format("TOR промах — ещё раз %.0fm", dist)
			else
				tor.status = string.format("TOR ждём результат %.0fm (%.1fs)", dist, age)
				return
			end
		end

		if not inFireRange then
			tor.status = string.format("TOR %s %s %.0fm [%s] — жду ≤%d", who, typeName, dist, onRadar and "радар" or "вижу", TOR_FIRE_RANGE)
			return
		end

		local lockedFor = tor.lockSince and (now - tor.lockSince) or 0
		if TOR_AIM_SETTLE > 0 and lockedFor < TOR_AIM_SETTLE then
			tor.status = string.format("TOR наводка %.0fm…", dist)
			return
		end

		if samCd <= 0 and not tor.firing and now - tor.lastFire >= TOR_FIRE_INTERVAL then
			tor.firing = true
			tor.lastFire = now
			local shotTarget = target
			local shotDist = dist
			aimTor(ctx, anchor)
			task.spawn(function()
				local ok = fireTorRocket(ctx, shotTarget)
				if ok then
					markTorFired(shotTarget, shotDist)
					tor.status = "TOR пуск — ждём килл"
				else
					tor.firedIds[torKey(shotTarget)] = nil
					tor.lastFire = now - (TOR_FIRE_INTERVAL - TOR_FIRE_RETRY)
					tor.status = "TOR выстрел не прошёл — retry"
				end
				task.wait(0.15)
				tor.firing = false
			end)
		else
			tor.status = string.format("TOR %s %s %.0fm [%s] x%d", who, typeName, dist, onRadar and "огонь+радар" or "огонь", samAmmo)
		end
	end)
end

_G.UAI_StopAutoTor = stopTor

----------------------------------------------------------------
-- Auto Strela-10

----------------------------------------------------------------
local strela = {
	on = false,
	conn = nil,
	status = "off",
	lastFire = 0,
	lastAim = 0,
	currentTarget = nil,
	lockSince = nil,
	firing = false,
	firedIds = {},
	gen = 0,
	smoothYaw = nil,
	smoothPitch = nil,
	lastSentYaw = nil,
	lastSentPitch = nil,
}

if type(_G.UAI_StrelaGen) ~= "number" then
	_G.UAI_StrelaGen = 0
end

local STRELA_AIM_INTERVAL = 0.32
local STRELA_FIRE_INTERVAL = 1.35
local STRELA_MAX_RANGE = 12000
local STRELA_AIM_SETTLE = 0.45
local STRELA_FIRE_RETRY = 0.55
local STRELA_AIM_DEADZONE = 0.025
local STRELA_AIM_SMOOTH = 0.16
local STRELA_MIN_PITCH = -0.6108652381980153 -- ~-35 deg
local STRELA_MAX_PITCH = 1.5707963267948966 -- ~90 deg

local function findActiveStrela()
	local seated = findSeatedVehicle("Strela-10", function(model)
		return model:FindFirstChild("GunObjects") ~= nil
	end)
	if seated then
		return seated, nil
	end
	for _, guiObj in ipairs(PlayerGui:GetChildren()) do
		if guiObj:IsA("ScreenGui") and string.find(guiObj.Name, "StrelaGui", 1, true) then
			local obj = guiObj:FindFirstChild("Value") or guiObj:FindFirstChild("StrelaObject") or guiObj:FindFirstChild("StrelaObj")
			if obj and obj:IsA("ObjectValue") and obj.Value and obj.Value.Parent then
				if string.find(string.lower(obj.Value.Name), "strela%-10") or string.find(string.lower(obj.Value.Name), "strela") then
					return obj.Value, guiObj
				end
			end
		end
	end
	return nil, nil
end

local function getStrelaParts(strelaModel)
	local gun = strelaModel:FindFirstChild("GunObjects")
	local remotes = gun and gun:FindFirstChild("GUN_Remotes")
	local states = gun and gun:FindFirstChild("GUN_States")
	local bashnya = strelaModel:FindFirstChild("Bashnya")
	local pusk = bashnya and bashnya:FindFirstChild("Пусковая")
	local osnova = pusk and pusk:FindFirstChild("osnova")
	local camAtt = osnova and osnova:FindFirstChild("CamAtt")
	if not camAtt and pusk then
		camAtt = pusk:FindFirstChild("CamAtt", true)
	end
	if not remotes or not states or not camAtt then
		return nil
	end
	return {
		remotes = remotes,
		states = states,
		camAtt = camAtt,
		aim = remotes:FindFirstChild("BashnyaAim"),
		fire = remotes:FindFirstChild("Fire"),
		stop = remotes:FindFirstChild("Stop"),
		ammo = states:FindFirstChild("Ammos"),
		cd = states:FindFirstChild("CooldownSeconds"),
		reloading = states:FindFirstChild("IsReloading"),
	}
end

local function strelaKey(drone)
	local id = drone:GetAttribute("DroneId")
	if id ~= nil then
		return tostring(id)
	end
	return tostring(drone)
end

local function pruneStrelaFired()
	local alive = {}
	for _, drone in ipairs(listDrones()) do
		alive[strelaKey(drone)] = true
	end
	for key in pairs(strela.firedIds) do
		if not alive[key] then
			strela.firedIds[key] = nil
		end
	end
end

local function markStrelaFired(drone)
	if drone then
		strela.firedIds[strelaKey(drone)] = os.clock()
		markSharedTarget(drone:GetAttribute("DroneId") or strelaKey(drone))
	end
end

local function wasStrelaFired(drone)
	return drone ~= nil and strela.firedIds[strelaKey(drone)] ~= nil
end

local function pickStrelaTarget(fromPos)
	pruneStrelaFired()
	heartbeatBotSlot()
	local myIndex, botCount = getMyBotIndex()
	local free = {}
	for _, drone in ipairs(listDrones()) do
		local id = drone:GetAttribute("DroneId") or strelaKey(drone)
		if not wasStrelaFired(drone) and not isSharedTarget(id) then
			local anchor = getAnchor(drone)
			if anchor then
				local dist = (anchor.Position - fromPos).Magnitude
				if dist <= STRELA_MAX_RANGE then
					table.insert(free, { drone = drone, id = id, dist = dist })
				end
			end
		end
	end
	table.sort(free, function(a, b)
		return a.dist < b.dist
	end)
	for i = myIndex, #free, botCount do
		local item = free[i]
		if item and tryClaimSharedTarget(item.id) then
			return item.drone
		end
	end
	for _, item in ipairs(free) do
		if tryClaimSharedTarget(item.id) then
			return item.drone
		end
	end
	return nil
end

local function computeStrelaAim(camAtt, targetPos)
	local offset = camAtt.WorldCFrame:PointToObjectSpace(targetPos)
	local yaw = math.atan2(-offset.X, -offset.Z)
	local horiz = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
	local pitch = math.atan2(offset.Y, math.max(horiz, 1e-4))
	pitch = math.clamp(pitch, STRELA_MIN_PITCH, STRELA_MAX_PITCH)
	local cf = camAtt.WorldCFrame * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	return yaw, pitch, cf.Position, cf.LookVector
end

local function stopStrela()
	strela.on = false
	strela.status = "off"
	strela.currentTarget = nil
	strela.lockSince = nil
	strela.firing = false
	strela.firedIds = {}
	strela.smoothYaw = nil
	strela.smoothPitch = nil
	strela.lastSentYaw = nil
	strela.lastSentPitch = nil
	strela.gen += 1
	_G.UAI_StrelaGen = strela.gen
	if strela.conn then
		strela.conn:Disconnect()
		strela.conn = nil
	end
end

local function fireStrelaRocket(ctx, target)
	if not ctx or not ctx.fire or not target then
		return false
	end
	local beforeAmmo = ctx.ammo and ctx.ammo.Value or 0
	local beforeCd = ctx.cd and ctx.cd.Value or 0
	pcall(function()
		ctx.fire:FireServer(target)
	end)
	for _ = 1, 8 do
		task.wait(0.05)
		local ammoNow = ctx.ammo and ctx.ammo.Value or beforeAmmo
		local cdNow = ctx.cd and ctx.cd.Value or beforeCd
		if ammoNow < beforeAmmo or cdNow > beforeCd then
			return true
		end
	end
	return true
end

local function startStrela()
	stopStrela()
	if auto.on then
		stopAuto()
	end
	if tor.on then
		stopTor()
	end
	strela.on = true
	strela.status = "waiting seat"
	strela.gen += 1
	local myGen = strela.gen
	_G.UAI_StrelaGen = myGen
	strela.conn = RunService.Heartbeat:Connect(function()
		if not strela.on or myGen ~= _G.UAI_StrelaGen then
			return
		end
		local strelaModel = select(1, findActiveStrela())
		if not strelaModel then
			strela.status = "сядь в Стрела-10"
			strela.currentTarget = nil
			strela.lockSince = nil
			return
		end
		local ctx = getStrelaParts(strelaModel)
		if not ctx or not ctx.aim or not ctx.fire then
			strela.status = "нет ремоутов"
			return
		end

		local now = os.clock()
		local ammo = ctx.ammo and ctx.ammo.Value or 0
		local cd = ctx.cd and ctx.cd.Value or 0
		local reloading = ctx.reloading and ctx.reloading.Value

		if ammo <= 0 or reloading then
			strela.currentTarget = nil
			strela.lockSince = nil
			strela.status = reloading and "Стрела перезарядка" or "Стрела ракеты пусты"
			return
		end

		local origin = ctx.camAtt.WorldPosition
		local target = pickStrelaTarget(origin)
		if target ~= strela.currentTarget then
			strela.currentTarget = target
			strela.lockSince = target and now or nil
			strela.smoothYaw = nil
			strela.smoothPitch = nil
			strela.lastSentYaw = nil
			strela.lastSentPitch = nil
		end
		if not target then
			strela.status = "Стрела: нет целей"
			return
		end

		local anchor = getAnchor(target)
		if not anchor then
			strela.currentTarget = nil
			strela.lockSince = nil
			return
		end
		local dist = (anchor.Position - origin).Magnitude
		local typeName = getDroneType(target)
		local who = (target:GetAttribute("IsPlayerDrone") == true) and "PLAYER" or "BOT"
		strela.status = string.format("Стрела %s %s %.0fm [1 выстрел] x%d", who, typeName, dist, ammo)

		if (not strela.firing) and now - strela.lastAim >= STRELA_AIM_INTERVAL then
			strela.lastAim = now
			local yaw, pitch = computeStrelaAim(ctx.camAtt, anchor.Position)
			if strela.smoothYaw == nil then
				strela.smoothYaw = yaw
				strela.smoothPitch = pitch
			else
				local a = STRELA_AIM_SMOOTH
				strela.smoothYaw += (yaw - strela.smoothYaw) * a
				strela.smoothPitch += (pitch - strela.smoothPitch) * a
			end
			-- quantize to kill micro-jitter on hinges
			local sendYaw = math.floor(strela.smoothYaw * 40 + 0.5) / 40
			local sendPitch = math.floor(strela.smoothPitch * 40 + 0.5) / 40
			local dy = strela.lastSentYaw and math.abs(sendYaw - strela.lastSentYaw) or math.huge
			local dp = strela.lastSentPitch and math.abs(sendPitch - strela.lastSentPitch) or math.huge
			if dy >= STRELA_AIM_DEADZONE or dp >= STRELA_AIM_DEADZONE then
				local cf = ctx.camAtt.WorldCFrame
					* CFrame.Angles(0, sendYaw, 0)
					* CFrame.Angles(sendPitch, 0, 0)
				pcall(function()
					ctx.aim:FireServer(sendYaw, sendPitch, cf.Position, cf.LookVector)
				end)
				strela.lastSentYaw = sendYaw
				strela.lastSentPitch = sendPitch
			end
		end

		local lockedFor = strela.lockSince and (now - strela.lockSince) or 0
		if lockedFor < STRELA_AIM_SETTLE then
			strela.status = string.format("Стрела наводка %.0fm…", dist)
			return
		end

		if cd <= 0 and not strela.firing and now - strela.lastFire >= STRELA_FIRE_INTERVAL then
			strela.firing = true
			strela.lastFire = now
			local shotTarget = target
			markStrelaFired(shotTarget)
			strela.currentTarget = nil
			strela.lockSince = nil
			task.spawn(function()
				local ok = fireStrelaRocket(ctx, shotTarget)
				if ok then
					strela.status = "Стрела пуск OK → следующий"
				else
					strela.firedIds[strelaKey(shotTarget)] = nil
					strela.lastFire = now - (STRELA_FIRE_INTERVAL - STRELA_FIRE_RETRY)
					strela.status = "Стрела пуск не принят — retry"
				end
				task.wait(0.2)
				strela.firing = false
			end)
		end
	end)
end

_G.UAI_StopAutoStrela = stopStrela

----------------------------------------------------------------
-- Menu GUI
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "UAI_Menu"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(230, 290)
frame.Position = UDim2.new(0, 20, 0.35, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
frame.BackgroundTransparency = 0.12
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(70, 90, 130)
stroke.Thickness = 1.2
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -36, 0, 28)
title.Position = UDim2.fromOffset(10, 6)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(230, 235, 255)
title.Text = "Гумаров секс"
title.Parent = frame

local hideBtn = Instance.new("TextButton")
hideBtn.Size = UDim2.fromOffset(24, 24)
hideBtn.Position = UDim2.new(1, -30, 0, 6)
hideBtn.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
hideBtn.Text = "–"
hideBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
hideBtn.Font = Enum.Font.GothamBold
hideBtn.TextSize = 16
hideBtn.Parent = frame
Instance.new("UICorner", hideBtn).CornerRadius = UDim.new(0, 6)

local body = Instance.new("Frame")
body.Name = "Body"
body.BackgroundTransparency = 1
body.Size = UDim2.new(1, -16, 1, -40)
body.Position = UDim2.fromOffset(8, 36)
body.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = body

local function makeToggle(name, text)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.new(1, 0, 0, 32)
	btn.BackgroundColor3 = Color3.fromRGB(45, 52, 68)
	btn.TextColor3 = Color3.fromRGB(235, 235, 245)
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = 14
	btn.Text = text .. ": OFF"
	btn.AutoButtonColor = true
	btn.Parent = body
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
	return btn
end

local espBtn = makeToggle("EspBtn", "Drone ESP")
local peopleBtn = makeToggle("PeopleBtn", "People ESP")
local autoBtn = makeToggle("AutoBtn", "Авто Панцирь")
local torBtn = makeToggle("TorBtn", "Авто TOR-M1")
local strelaBtn = makeToggle("StrelaBtn", "Авто Стрела-10")

local status = Instance.new("TextLabel")
status.Name = "Status"
status.Size = UDim2.new(1, 0, 0, 40)
status.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
status.TextColor3 = Color3.fromRGB(180, 200, 220)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = "Статус: ожидание"
status.Parent = body
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 8)
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingTop = UDim.new(0, 6)
pad.Parent = status

local function setToggleVisual(btn, on, label)
	btn.Text = label .. ": " .. (on and "ON" or "OFF")
	btn.BackgroundColor3 = on and Color3.fromRGB(40, 110, 70) or Color3.fromRGB(45, 52, 68)
end

espBtn.MouseButton1Click:Connect(function()
	if esp.on then
		stopEsp()
		setToggleVisual(espBtn, false, "Drone ESP")
	else
		startEsp()
		setToggleVisual(espBtn, true, "Drone ESP")
	end
end)

peopleBtn.MouseButton1Click:Connect(function()
	if people.on then
		stopPeople()
		setToggleVisual(peopleBtn, false, "People ESP")
	else
		startPeople()
		setToggleVisual(peopleBtn, true, "People ESP")
	end
end)

autoBtn.MouseButton1Click:Connect(function()
	if auto.on then
		stopAuto()
		setToggleVisual(autoBtn, false, "Авто Панцирь")
		status.Text = "Статус: авто выкл"
	else
		if tor.on then
			stopTor()
			setToggleVisual(torBtn, false, "Авто TOR-M1")
		end
		if strela.on then
			stopStrela()
			setToggleVisual(strelaBtn, false, "Авто Стрела-10")
		end
		auto.setButton = function(on)
			setToggleVisual(autoBtn, on, "Авто Панцирь")
		end
		startAuto()
		setToggleVisual(autoBtn, true, "Авто Панцирь")
	end
end)

torBtn.MouseButton1Click:Connect(function()
	if tor.on then
		stopTor()
		setToggleVisual(torBtn, false, "Авто TOR-M1")
		status.Text = "Статус: TOR выкл"
	else
		if auto.on then
			stopAuto()
			setToggleVisual(autoBtn, false, "Авто Панцирь")
		end
		if strela.on then
			stopStrela()
			setToggleVisual(strelaBtn, false, "Авто Стрела-10")
		end
		startTor()
		setToggleVisual(torBtn, true, "Авто TOR-M1")
	end
end)

strelaBtn.MouseButton1Click:Connect(function()
	if strela.on then
		stopStrela()
		setToggleVisual(strelaBtn, false, "Авто Стрела-10")
		status.Text = "Статус: Стрела выкл"
	else
		if auto.on then
			stopAuto()
			setToggleVisual(autoBtn, false, "Авто Панцирь")
		end
		if tor.on then
			stopTor()
			setToggleVisual(torBtn, false, "Авто TOR-M1")
		end
		startStrela()
		setToggleVisual(strelaBtn, true, "Авто Стрела-10")
	end
end)

local collapsed = false
hideBtn.MouseButton1Click:Connect(function()
	collapsed = not collapsed
	body.Visible = not collapsed
	frame.Size = collapsed and UDim2.fromOffset(230, 36) or UDim2.fromOffset(230, 290)
	hideBtn.Text = collapsed and "+" or "–"
end)

-- drag
local dragging = false
local dragStart, startPos
title.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = frame.Position
	end
end)
title.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if not dragging then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end
end)

local statusConn = RunService.Heartbeat:Connect(function()
	if strela.on then
		status.Text = "Авто: " .. tostring(strela.status)
	elseif tor.on then
		status.Text = "Авто: " .. tostring(tor.status)
	elseif auto.on then
		status.Text = "Авто: " .. tostring(auto.status)
	elseif esp.on then
		local n = 0
		for _ in pairs(esp.tracked) do
			n += 1
		end
		status.Text = string.format("ESP: %d дронов", n)
	elseif people.on then
		local n = 0
		for _ in pairs(people.tracked) do
			n += 1
		end
		status.Text = string.format("People ESP: %d", n)
	else
		status.Text = "Статус: меню готово\nRightShift — показать/скрыть"
	end
end)

local toggleMenuConn = UserInputService.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightShift then
		gui.Enabled = not gui.Enabled
	end
end)

_G.UAI_StopMenu = function()
	stopEsp()
	if type(stopPeople) == "function" then
		pcall(stopPeople)
	end
	stopAuto()
	stopTor()
	stopStrela()
	if statusConn then
		statusConn:Disconnect()
	end
	if toggleMenuConn then
		toggleMenuConn:Disconnect()
	end
	if gui then
		gui:Destroy()
	end
	print("[UAI] Menu stopped")
end

-- restore ESP if previous script left highlights; start clean with ESP on for convenience? leave off
setToggleVisual(espBtn, false, "Drone ESP")
setToggleVisual(peopleBtn, false, "People ESP")
setToggleVisual(autoBtn, false, "Авто Панцирь")
setToggleVisual(torBtn, false, "Авто TOR-M1")
setToggleVisual(strelaBtn, false, "Авто Стрела-10")

print("[UAI] Гумаров секс ready — RightShift toggle. Buttons: Drone ESP, People ESP, Авто Панцирь, Авто TOR-M1, Авто Стрела-10")
return "Гумаров секс loaded"
