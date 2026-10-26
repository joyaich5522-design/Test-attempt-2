--[[
	Ember -- a floating-dock UI for the UAI agent core.

	Layout (nothing like a sidebar + window):
	  * a small draggable dock pill at the bottom: Chat / Menu / Stop
	  * the chat slides up as a sheet from behind the dock
	  * settings live in a drawer that slides in from the right edge
	  * tool calls collapse into one "Activity" row per turn

	The UI never touches the agent directly. It only talks to a `core` table,
	so you wire it once (see GLUE at the bottom) and the rest is self-contained.

	core = {
		send     = function(text) end,
		abort    = function() end,
		newChat  = function() end,
		onEvent  = function(handler) return disconnect end,  -- handler(ev) gets session events
		modes    = function() return { {id=, label=, hint=}, ... } end,
		getMode  = function() return id end,
		setMode  = function(id) end,
		groups   = function() return { {id=, label=, total=, enabled=}, ... } end,
		setGroup = function(id, enabled) end,
	}
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local T = {
	bg = Color3.fromRGB(24, 26, 43),
	panel = Color3.fromRGB(32, 35, 58),
	raised = Color3.fromRGB(43, 47, 77),
	line = Color3.fromRGB(62, 67, 104),
	text = Color3.fromRGB(233, 230, 221),
	dim = Color3.fromRGB(142, 147, 176),
	accent = Color3.fromRGB(143, 211, 182),
	accentText = Color3.fromRGB(20, 40, 33),
	warn = Color3.fromRGB(242, 182, 109),
	bad = Color3.fromRGB(229, 124, 124),
	font = Enum.Font.Nunito,
	fontBold = Enum.Font.GothamBold,
}

local function make(class, props, children)
	local inst = Instance.new(class)
	local parent
	for key, value in pairs(props or {}) do
		if key == "Parent" then parent = value else inst[key] = value end
	end
	for _, child in ipairs(children or {}) do child.Parent = inst end
	if parent then inst.Parent = parent end
	return inst
end

local function corner(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function outline(color, thickness)
	return make("UIStroke", {
		Color = color, Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function padding(top, side)
	return make("UIPadding", {
		PaddingTop = UDim.new(0, top), PaddingBottom = UDim.new(0, top),
		PaddingLeft = UDim.new(0, side or top), PaddingRight = UDim.new(0, side or top),
	})
end

local function text(props)
	local base = {
		BackgroundTransparency = 1, Font = T.font, TextColor3 = T.text, TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true, RichText = false, BorderSizePixel = 0,
	}
	for key, value in pairs(props) do base[key] = value end
	return make("TextLabel", base)
end

local function button(props, children)
	local base = {
		AutoButtonColor = false, BackgroundColor3 = T.raised, BorderSizePixel = 0,
		Font = T.font, TextColor3 = T.text, TextSize = 15,
	}
	for key, value in pairs(props) do base[key] = value end
	local btn = make("TextButton", base, children)
	local rest = btn.BackgroundColor3
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = rest:Lerp(Color3.new(1, 1, 1), 0.12) }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = rest }):Play()
	end)
	return btn
end

local function shorten(value, limit)
	value = tostring(value or "")
	if #value <= limit then return value end
	return value:sub(1, limit - 1) .. "..."
end

local function guiParent()
	local ok, hui = pcall(function() return gethui() end)
	if ok and hui then return hui end
	local okCore, core = pcall(function()
		local service = game:GetService("CoreGui")
		local probe = Instance.new("Folder")
		probe.Parent = service -- errors in a normal LocalScript, which has no CoreGui access
		probe:Destroy()
		return service
	end)
	if okCore and core then return core end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function Ember(core)
	local screen = make("ScreenGui", {
		Name = "Ember", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
	})

	local connections, busy, order = {}, false, 0
	local activity -- the Activity row for the turn in progress

	---------------------------------------------------------------- sheet
	local SHEET_OPEN = UDim2.new(0.5, 0, 1, -84)
	local SHEET_SHUT = UDim2.new(0.5, 0, 1.8, 0)

	local sheet = make("Frame", {
		Name = "Sheet", AnchorPoint = Vector2.new(0.5, 1), Position = SHEET_SHUT,
		Size = UDim2.new(0.94, 0, 0.66, 0), BackgroundColor3 = T.bg, Visible = false,
		BorderSizePixel = 0, Parent = screen,
	}, {
		corner(20), outline(T.line, 1),
		make("UISizeConstraint", { MaxSize = Vector2.new(580, 600), MinSize = Vector2.new(260, 240) }),
	})

	local header = make("Frame", {
		Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1, Parent = sheet,
	})
	text({
		Text = "Agent", Font = T.fontBold, TextSize = 17, Position = UDim2.new(0, 18, 0, 0),
		Size = UDim2.new(0.4, 0, 1, 0), TextYAlignment = Enum.TextYAlignment.Center, Parent = header,
	})
	local statusLabel = text({
		Text = "Ready", TextSize = 14, TextColor3 = T.dim, TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 0),
		Size = UDim2.new(0.55, 0, 1, 0), TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})
	make("Frame", {
		Size = UDim2.new(1, -28, 0, 1), Position = UDim2.new(0, 14, 1, -1),
		BackgroundColor3 = T.line, BorderSizePixel = 0, Parent = header,
	})

	local scroll = make("ScrollingFrame", {
		Position = UDim2.new(0, 0, 0, 48), Size = UDim2.new(1, 0, 1, -48 - 64),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollBarImageColor3 = T.line, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = sheet,
	}, {
		padding(12, 16),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12) }),
	})

	local function toBottom()
		task.defer(function()
			scroll.CanvasPosition = Vector2.new(0, scroll.AbsoluteCanvasSize.Y)
		end)
	end

	local function nextOrder()
		order = order + 1
		return order
	end

	local function addUser(body)
		local wrap = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = scroll,
		})
		make("TextLabel", {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.new(0.82, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = T.raised, BorderSizePixel = 0, Font = T.font, TextSize = 16,
			TextColor3 = T.text, TextWrapped = true, Text = body,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = wrap,
		}, { corner(14), padding(10, 14) })
		toBottom()
	end

	local function addReply(body)
		local wrap = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = scroll,
		})
		make("Frame", {
			Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = T.accent, BorderSizePixel = 0, Parent = wrap,
		}, { corner(2) })
		text({
			Text = body, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -14, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, TextSelectable = true, Parent = wrap,
		})
		toBottom()
	end

	local function addNote(body, color)
		local wrap = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), Parent = scroll,
		})
		text({
			Text = body, TextSize = 14, TextColor3 = color or T.dim,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			TextXAlignment = Enum.TextXAlignment.Center, Parent = wrap,
		})
		toBottom()
	end

	---------------------------------------------------------------- activity
	local function newActivity()
		local row = make("Frame", {
			BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder(), BorderSizePixel = 0, Parent = scroll,
		}, {
			corner(10),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		local head = button({
			Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Text = "",
			LayoutOrder = 0, Parent = row,
		})
		local title = text({
			Text = "Working", TextSize = 14, TextColor3 = T.dim, Position = UDim2.new(0, 12, 0, 0),
			Size = UDim2.new(1, -24, 1, 0), TextYAlignment = Enum.TextYAlignment.Center, Parent = head,
		})
		local list = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false, LayoutOrder = 1, Parent = row,
		}, {
			padding(4, 12),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
		})
		local state = { rows = {}, count = 0, failed = 0, list = list, title = title }
		local function retitle()
			local arrow = list.Visible and "Hide" or "Show"
			local what = state.count == 1 and "1 step" or (state.count .. " steps")
			local tail = state.failed > 0 and (", " .. state.failed .. " failed") or ""
			title.Text = what .. tail .. "  (" .. arrow:lower() .. ")"
		end
		head.MouseButton1Click:Connect(function()
			list.Visible = not list.Visible
			retitle()
		end)
		state.retitle = retitle
		return state
	end

	local function addTool(id, name)
		if not activity then activity = newActivity() end
		activity.count = activity.count + 1
		local line = text({
			Text = "...  " .. tostring(name), TextSize = 14, TextColor3 = T.dim,
			Size = UDim2.new(1, 0, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = activity.count, Parent = activity.list,
		})
		activity.rows[tostring(id)] = { line = line, name = tostring(name) }
		activity.retitle()
		toBottom()
	end

	local function finishTool(id, ok)
		if not activity then return end
		local entry = activity.rows[tostring(id)]
		if not entry then return end
		entry.line.Text = (ok and "ok   " or "fail ") .. entry.name
		entry.line.TextColor3 = ok and T.accent or T.bad
		if not ok then activity.failed = activity.failed + 1 end
		activity.retitle()
	end

	---------------------------------------------------------------- permission card
	local function addPermission(ev)
		local card = make("Frame", {
			BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(), BorderSizePixel = 0, Parent = scroll,
		}, {
			corner(12), outline(T.warn, 1), padding(12),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
		})
		text({
			Text = "Allow " .. tostring(ev.name) .. "?", Font = T.fontBold, TextSize = 16,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card,
		})
		local ok, encoded = pcall(function() return HttpService:JSONEncode(ev.args or {}) end)
		text({
			Text = shorten(ok and encoded or "", 220), TextSize = 13, TextColor3 = T.dim,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = card,
		})
		local actions = make("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 3, Parent = card,
		}, { make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}) })

		local function settle(allowed, remember, label)
			actions:Destroy()
			text({
				Text = label, TextSize = 14, TextColor3 = allowed and T.accent or T.bad,
				Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Parent = card,
			})
			if type(ev.resolve) == "function" then pcall(ev.resolve, allowed, remember) end
		end
		local function choice(label, fill, textColor, order, handler)
			local b = button({
				Text = label, BackgroundColor3 = fill, TextColor3 = textColor, Font = T.fontBold,
				Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = order, Parent = actions,
			}, { corner(8), padding(0, 14) })
			b.MouseButton1Click:Connect(handler)
		end
		choice("Allow", T.accent, T.accentText, 1, function() settle(true, false, "Allowed") end)
		choice("Always allow", T.raised, T.text, 2, function() settle(true, true, "Always allowed") end)
		choice("Deny", T.raised, T.bad, 3, function() settle(false, false, "Denied") end)
		toBottom()
	end

	---------------------------------------------------------------- helper agents
	-- The core can delegate work to subagents and reports them as subagent:* events.
	-- Field names beyond `kind` and `text` are read defensively, since I have not
	-- seen that module: the card still works if some of them are missing.
	local agents = {}

	local function agentCard(ev)
		local key = tostring(ev.callId or ev.agentId or ev.id or "agent")
		local card = agents[key]
		if card then return card end
		local frame = make("Frame", {
			BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(), BorderSizePixel = 0, Parent = scroll,
		}, {
			corner(12), outline(T.line, 1), padding(10, 12),
			make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
		})
		card = { tools = 0, frame = frame }
		card.title = text({
			Text = "Helper agent", Font = T.fontBold, TextSize = 15, LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = frame,
		})
		card.status = text({
			Text = "Working", TextSize = 13, TextColor3 = T.warn, LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 16), Parent = frame,
		})
		card.body = text({
			Text = "", TextSize = 13, TextColor3 = T.dim, LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = frame,
		})
		agents[key] = card
		return card
	end

	local function renderAgent(card)
		local lines = {}
		if card.tools > 0 then
			lines[#lines + 1] = card.tools == 1 and "1 tool call" or (card.tools .. " tool calls")
		end
		if card.last then lines[#lines + 1] = card.last end
		card.body.Text = table.concat(lines, "\n")
		toBottom()
	end

	local function handleAgent(kind, ev)
		local card = agentCard(ev)
		if kind == "subagent:start" then
			local task = ev.task or ev.title or ev.description or ev.name
			if task then card.title.Text = "Helper: " .. shorten(task, 90) end
			card.status.Text = "Working"
		elseif kind == "subagent:tool" then
			card.tools = card.tools + 1
			card.last = "Running " .. tostring(ev.name or ev.tool or "a tool")
		elseif kind == "subagent:text" then
			if ev.text and ev.text ~= "" then card.last = shorten(ev.text, 160) end
		elseif kind == "subagent:done" then
			local failed = ev.error ~= nil or ev.ok == false
			card.status.Text = failed and "Failed" or "Done"
			card.status.TextColor3 = failed and T.bad or T.accent
			if failed and ev.error then card.last = shorten(ev.error, 160) end
		end
		renderAgent(card)
	end

	---------------------------------------------------------------- composer
	local composer = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(1, -24, 0, 46), BackgroundColor3 = T.panel, BorderSizePixel = 0, Parent = sheet,
	}, { corner(23), outline(T.line, 1) })

	local input = make("TextBox", {
		BackgroundTransparency = 1, Position = UDim2.new(0, 18, 0, 0), Size = UDim2.new(1, -72, 1, 0),
		Font = T.font, TextSize = 16, TextColor3 = T.text, PlaceholderText = "Tell the agent what to do",
		PlaceholderColor3 = T.dim, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "", Parent = composer,
	})
	local sendButton = button({
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = T.accent, Text = "Go", TextColor3 = T.accentText, Font = T.fontBold, TextSize = 14,
		Parent = composer,
	}, { corner(17) })

	local function submit()
		local body = input.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if body == "" then return end
		local ok, reason = core.send(body)
		if ok == false then
			addNote(tostring(reason or "The agent could not take that message."), T.warn)
			return
		end
		input.Text = ""
	end
	sendButton.MouseButton1Click:Connect(submit)
	input.FocusLost:Connect(function(enter) if enter then submit() end end)

	---------------------------------------------------------------- drawer
	local DRAWER_OPEN = UDim2.new(1, 0, 0, 0)
	local DRAWER_SHUT = UDim2.new(1, 300, 0, 0)

	local drawer = make("Frame", {
		AnchorPoint = Vector2.new(1, 0), Position = DRAWER_SHUT, Size = UDim2.new(0, 280, 1, 0),
		BackgroundColor3 = T.bg, BorderSizePixel = 0, Visible = false, ZIndex = 5, Parent = screen,
	}, { outline(T.line, 1) })

	local drawerList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 3, ScrollBarImageColor3 = T.line, AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(), ZIndex = 5, Parent = drawer,
	}, {
		padding(16),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
	})

	local function refreshDrawer()
		for _, child in ipairs(drawerList:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		local n = 0
		local function add(inst) n = n + 1 inst.LayoutOrder = n inst.ZIndex = 5 inst.Parent = drawerList return inst end

		add(text({ Text = "Menu", Font = T.fontBold, TextSize = 20, Size = UDim2.new(1, 0, 0, 30) }))

		local fresh = add(button({
			Text = "Start a new chat", Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = T.accent,
			TextColor3 = T.accentText, Font = T.fontBold,
		}, { corner(10) }))
		fresh.MouseButton1Click:Connect(function()
			core.newChat()
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			activity = nil
		end)

		add(text({ Text = "What the agent may do", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
			TextYAlignment = Enum.TextYAlignment.Bottom }))
		local current = core.getMode()
		for _, mode in ipairs(core.modes()) do
			local picked = mode.id == current
			local row = add(button({
				Text = "", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = picked and T.raised or T.panel,
			}, { corner(10), padding(10, 12), picked and outline(T.accent, 1) or nil }))
			text({ Text = mode.label, Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 18),
				TextColor3 = picked and T.accent or T.text, ZIndex = 6, Parent = row })
			text({ Text = mode.hint or "", TextSize = 13, TextColor3 = T.dim, Position = UDim2.new(0, 0, 0, 20),
				Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 6, Parent = row })
			row.MouseButton1Click:Connect(function()
				core.setMode(mode.id)
				refreshDrawer()
			end)
		end

		add(text({ Text = "Tool groups", Font = T.fontBold, TextSize = 15, Size = UDim2.new(1, 0, 0, 30),
			TextYAlignment = Enum.TextYAlignment.Bottom }))
		for _, group in ipairs(core.groups()) do
			local row = add(button({
				Text = "", Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = T.panel,
			}, { corner(10) }))
			text({ Text = group.label, TextSize = 15, TextColor3 = group.enabled and T.text or T.dim,
				Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -90, 1, 0),
				TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 6, Parent = row })
			text({ Text = group.enabled and "On" or "Off", TextSize = 14, Font = T.fontBold,
				TextColor3 = group.enabled and T.accent or T.dim, TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0, 60, 1, 0),
				TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 6, Parent = row })
			row.MouseButton1Click:Connect(function()
				core.setGroup(group.id, not group.enabled)
				refreshDrawer()
			end)
		end
	end

	---------------------------------------------------------------- dock
	local dock = make("Frame", {
		Name = "Dock", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.new(0, 0, 0, 52), AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.bg, BorderSizePixel = 0, ZIndex = 8, Parent = screen,
	}, {
		corner(26), outline(T.line, 1),
		padding(7, 10),
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
			VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local grip = make("Frame", {
		Size = UDim2.fromOffset(14, 30), BackgroundTransparency = 1, LayoutOrder = 0, ZIndex = 9, Parent = dock,
	}, {
		make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(4, 22), BackgroundColor3 = T.line, BorderSizePixel = 0, ZIndex = 9 }, { corner(2) }),
	})

	local function dockButton(label, order, fill, color)
		return button({
			Text = label, Size = UDim2.new(0, 0, 0, 38), AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = fill or T.panel, TextColor3 = color or T.text, Font = T.fontBold,
			LayoutOrder = order, ZIndex = 9, Parent = dock,
		}, { corner(19), padding(0, 16) })
	end

	local chatButton = dockButton("Chat", 1, T.accent, T.accentText)
	local menuButton = dockButton("Menu", 2)
	local stopButton = dockButton("Stop", 3, T.bad, Color3.fromRGB(45, 18, 18))
	stopButton.Visible = false

	local sheetOpen, drawerOpen = false, false

	local function setSheet(open)
		sheetOpen = open
		if open then sheet.Visible = true end
		local tween = TweenService:Create(sheet,
			TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = open and SHEET_OPEN or SHEET_SHUT })
		tween.Completed:Connect(function() if not sheetOpen then sheet.Visible = false end end)
		tween:Play()
		chatButton.Text = open and "Hide" or "Chat"
		if open then toBottom() end
	end

	local function setDrawer(open)
		drawerOpen = open
		if open then
			refreshDrawer()
			drawer.Visible = true
		end
		local tween = TweenService:Create(drawer,
			TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Position = open and DRAWER_OPEN or DRAWER_SHUT })
		tween.Completed:Connect(function() if not drawerOpen then drawer.Visible = false end end)
		tween:Play()
		menuButton.Text = open and "Close" or "Menu"
	end

	chatButton.MouseButton1Click:Connect(function() setSheet(not sheetOpen) end)
	menuButton.MouseButton1Click:Connect(function() setDrawer(not drawerOpen) end)
	stopButton.MouseButton1Click:Connect(function() core.abort() end)

	-- Drag the dock by its grip.
	local dragging, dragStart, dockStart = false, nil, nil
	grip.InputBegan:Connect(function(inputObject)
		local kind = inputObject.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragging, dragStart, dockStart = true, inputObject.Position, dock.Position
			inputObject.Changed:Connect(function()
				if inputObject.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	table.insert(connections, UserInputService.InputChanged:Connect(function(inputObject)
		local kind = inputObject.UserInputType
		if dragging and (kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch) then
			local delta = inputObject.Position - dragStart
			dock.Position = UDim2.new(dockStart.X.Scale, dockStart.X.Offset + delta.X,
				dockStart.Y.Scale, dockStart.Y.Offset + delta.Y)
		end
	end))

	---------------------------------------------------------------- events
	local function setBusy(value)
		busy = value
		stopButton.Visible = value
	end

	local function handle(ev)
		local kind = ev.kind
		if kind == "user" then
			activity = nil
			agents = {}
			setBusy(true)
			addUser(tostring(ev.text or ""))
		elseif type(kind) == "string" and kind:sub(1, 9) == "subagent:" then
			handleAgent(kind, ev)
		elseif kind == "assistant:text" then
			addReply(tostring(ev.text or ""))
		elseif kind == "tool:call" then
			addTool(ev.id, ev.name)
		elseif kind == "tool:result" then
			finishTool(ev.id, true)
		elseif kind == "tool:error" then
			finishTool(ev.id, false)
		elseif kind == "permission:ask" then
			addPermission(ev)
			if not sheetOpen then setSheet(true) end
		elseif kind == "status" then
			statusLabel.Text = tostring(ev.text or "")
			if ev.text == "Ready" then setBusy(false) end
		elseif kind == "error" then
			addNote(tostring(ev.message or "Something went wrong."), T.bad)
			if ev.fatal then setBusy(false) end
		elseif kind == "abort" then
			addNote("Stopped", T.dim)
			setBusy(false)
		elseif kind == "turn:end" then
			setBusy(false)
		elseif kind == "cleared" then
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			activity = nil
		end
	end

	local detach = core.onEvent(function(ev) task.defer(handle, ev) end)

	local api = {}
	function api.destroy()
		if type(detach) == "function" then pcall(detach)
		elseif type(detach) == "table" and detach.Disconnect then pcall(detach.Disconnect, detach) end
		for _, c in ipairs(connections) do c:Disconnect() end
		screen:Destroy()
	end
	function api.toggle() setSheet(not sheetOpen) end

	screen.Parent = guiParent()
	return api
end

---------------------------------------------------------------- start
-- Run on its own, this file opens Ember against a stand-in core so you can see
-- the layout. To drive the real agent, set getgenv().EmberCore first (see GLUE).
local function demoCore()
	local listeners = {}
	local mode = "ask"
	local on = { instance = true, script = true, fs = true }
	local function emit(ev)
		for _, fn in ipairs(listeners) do fn(ev) end
	end
	return {
		send = function(body)
			emit({ kind = "user", text = body })
			task.delay(0.4, function()
				emit({ kind = "status", text = "Thinking" })
				emit({ kind = "tool:call", id = "demo1", name = "instance_inspect" })
				task.wait(0.7)
				emit({ kind = "tool:result", id = "demo1", name = "instance_inspect", ok = true })
				emit({ kind = "assistant:text", text = "Demo mode: Ember is running without the agent core, so nothing real happened. You said: " .. body })
				emit({ kind = "turn:end" })
				emit({ kind = "status", text = "Ready" })
			end)
			return true
		end,
		abort = function() emit({ kind = "abort" }) end,
		newChat = function() emit({ kind = "cleared" }) end,
		onEvent = function(fn)
			table.insert(listeners, fn)
			return function()
				for i, existing in ipairs(listeners) do
					if existing == fn then table.remove(listeners, i) break end
				end
			end
		end,
		modes = function()
			return {
				{ id = "readonly", label = "Read only", hint = "Nothing is changed or run." },
				{ id = "ask", label = "Ask first", hint = "Anything that changes the game waits for you." },
				{ id = "auto", label = "Auto", hint = "Writes run freely. Dangerous steps still ask." },
			}
		end,
		getMode = function() return mode end,
		setMode = function(id) mode = id end,
		groups = function()
			return {
				{ id = "instance", label = "Instance tree", enabled = on.instance },
				{ id = "script", label = "Code", enabled = on.script },
				{ id = "fs", label = "Files", enabled = on.fs },
			}
		end,
		setGroup = function(id, enabled) on[id] = enabled end,
	}
end

local shared = (getgenv and getgenv()) or _G
if shared.EmberUI and shared.EmberUI.destroy then pcall(shared.EmberUI.destroy) end
shared.EmberUI = Ember(shared.EmberCore or demoCore())
return shared.EmberUI

--[[ GLUE ------------------------------------------------------------------
	Goes inside the bundle where `env` exists, in place of the call that
	starts the old UI (the boot step at the bottom of uai.lua). Set the core
	first, then run this file, which picks it up:

	local sessions = env.require("agent/session")
	local permissions = env.require("agent/permissions")
	local registry = env.require("agent/registry")

	getgenv().EmberCore = ({
		send = function(text) return sessions.current().send(text) end,
		abort = function() return sessions.current().abort() end,
		newChat = function() sessions.newThread() end,
		onEvent = function(handler)
			return sessions.anyEvent:connect(function(session, ev)
				if session == sessions.current() then handler(ev) end
			end)
		end,
		modes = function()
			local out = {}
			for _, id in ipairs(permissions.MODES) do
				out[#out + 1] = { id = id, label = permissions.MODE_LABELS[id], hint = permissions.MODE_HINTS[id] }
			end
			return out
		end,
		getMode = permissions.mode,
		setMode = permissions.setMode,
		groups = registry.groups,
		setGroup = registry.setGroupEnabled,
	})

	loadstring(readfile("ember.lua"))()
------------------------------------------------------------------------- ]]
