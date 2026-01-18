local Validate = game.ReplicatedStorage.Remotes.CallServer -- The RemoteEvent that catches players input from localscript
local Debris = game:GetService("Debris") -- Cleaning Up Service
local RunService = game:GetService("RunService") -- Used to detect hit requests each frame
local ComboAttachs = {} -- Table to store attachments for each combo on each player
local ActiveCombos = {} -- Table to store active hitting requests from any players in server
local ComboSettings = { -- A table to store settings for each combo
	-- Each combo has its own settings
	Combo1 = {
		VelocityStrength = 10, -- Strength of the body velocity on char and enemy for a knockback effect
		VFX = game.ReplicatedStorage.VFX.HitVFX.Attachment, -- Custom VFX for each combo (Pooled)
		Sound = script["Hit Sound"], -- Custom Sound for each combo (Pooled)
		KnockBackAnim = script.Anims.Combo1KnockBack, -- The animation to play on the enemy for a knockback effect
		HitLength = 4, -- Used to determine the length of the hit window/rays
		Damage = 5, -- How much damage that combo does
		Attach = 1, -- The number of attachments to use for the combo x2 its setting up the placement for the rays
		Pool = { VFX = {}, Sound = {} } -- Pools for VFX and Sound to avoid memory spikes
	}, -- I used a Nested table for the pool because pools are combo-related every combo has its own vfx and sound
	Combo2 = {
		VelocityStrength = 20,
		VFX = game.ReplicatedStorage.VFX.HitVFX.Attachment, -- Combo1 and 2 VFX and Sound are the same but they are just placeholders
		Sound = script["Hit Sound"],
		KnockBackAnim = script.Anims.Combo2KnockBack,
		HitLength = 5,
		Damage = 7,
		Attach = 1,
		Pool = { VFX = {}, Sound = {} }
	},
	Combo3 = {
		VelocityStrength = 30,
		VFX = game.ReplicatedStorage.VFX["Full Impact"].Attachment,
		Sound = script.SuperHit,
		KnockBackAnim = script.Anims.Combo3KnockBack,
		HitLength = 7,
		Damage = 10,
		Attach = 2,
		Pool = { VFX = {}, Sound = {} }
	},
}
local function CreatePoolItem(instance) -- A function to create a pool item to simplify the process
	return { -- Also for readability for myself
		Obj = instance:Clone(),
		InUse = false
	}
end
local function GetFromPool(comboName, poolType) -- A helper function to get a pool item from a pool
	local combo = ComboSettings[comboName] -- This function is ran when hits are detected and VFX and sound are needed
	local pool = combo and combo.Pool[poolType]
	if not pool then return end
	for _, item in ipairs(pool) do 
		if not item.InUse then -- item.InUse makes sure that the item is not in use by another combo
			item.InUse = true 
			return item
		end
	end
	local newItem = CreatePoolItem(combo[poolType]) -- If item is used or no item is available, create a new one
	newItem.InUse = true
	table.insert(pool, newItem)
	return newItem
end
local function ApplyVelocity(char, combo) -- another helper function used to apply body velocity to the given char
	local root = char:FindFirstChild("HumanoidRootPart") -- Used to avoid repeated code and simplify the code
	if not root then return end
	local bv = Instance.new("BodyVelocity")
	bv.MaxForce = Vector3.new(5e4, 0, 5e4)
	bv.Velocity = root.CFrame.LookVector * ComboSettings[combo].VelocityStrength -- VelocityStrength is used to determine the strength of the knockback
	bv.Parent = root
	return bv
end
-- THE MAIN GLOBAL LOOP USED TO CHECK FOR COMBO VALIDITY
RunService.Heartbeat:Connect(function() -- Recieves requests from ActiveCombos table and excutes them depending on if they are valid or not
	for _, notes in ipairs(ActiveCombos) do -- To understand this table refer to line 188
		if notes.Processed then continue end -- Processed is used to avoid checking the same combo over and over again
		if os.clock() - notes.StartTime > notes.Duration then -- If the combo has been active for more than the duration of the combo, it is invalid
			notes.Processed = true
			continue
		end
		local char = notes.Char -- The person who requested the hit
		if not char then print("Players char is nil") continue end -- If the char is nil, Combo is invalid
		local combo = notes.Combo -- The combo that was requested eg. "Combo1"
		local hitCache = notes.HitCache -- A table that stores the characters that have been hit by the notes
		local Params = notes.RaycastParams -- RaycastParams is used to avoid raycasting the player hitting
		if not Params or not combo or not hitCache then print("Missing Data") continue end -- If none of the above exists, Combo is invalid
		local root = char:FindFirstChild("HumanoidRootPart") -- The root part of the player used to get raycast direction
		if not root then continue end -- If the root is nil, Combo is invalid
		local charTable = ComboAttachs[char] -- To understand this table refer to line 155
		local set = charTable and charTable[combo] -- This is the table where the attachments for that combo are stored
		if not set then continue end -- If those attachments dont exist then theres a error in the script and combo is automatically invalid
		for _, handTable in pairs(set) do -- This loop is used to iterate over the Combos
			for _, attach in ipairs(handTable) do -- This loop is used to iterate over the Combos attachments
				local origin = attach.WorldPosition -- Now the logic will raycast each attachments position
				local direction = root.CFrame.LookVector * ComboSettings[combo].HitLength
				local result = workspace:Raycast(origin, direction, Params) -- This is the raycast
				if not result then continue end -- If the raycast doesnt hit anything, the loop skips the note and moves onto the next note
				local model = result.Instance:FindFirstAncestorOfClass("Model") -- This is used to find the char model that the raycast hit
				if not model or model == char then continue end -- If the model is nil or the model is the player, the loop skips the note and moves onto the next note
				local hum = model:FindFirstChildOfClass("Humanoid") -- self explanatory
				if not hum or hum.Health <= 0 then continue end -- If the humanoid is nil or the humanoid is dead, the loop skips the note and moves onto the next note
				if hitCache[hum] then continue end -- If the humanoid has already been hit, the loop skips the note and moves onto the next note this reduces double hits
				hitCache[hum] = true -- If the humanoid hasnt been hit, it is added to the hit cache
				local animator = hum:FindFirstChildOfClass("Animator") -- This is used to play the knockback animation
				if not animator then -- If somehow the humanoid doesnt have an animator, one is created
					animator = Instance.new("Animator")
					animator.Parent = hum
				end
				animator:LoadAnimation(ComboSettings[combo].KnockBackAnim):Play()
				local BV = ApplyVelocity(char,combo) -- This is the body velocity used to apply a knockback effect
				if not BV then print("BodyVelocity failed to fetch") continue end
				Debris:AddItem(BV, 0.1)
				local soundItem = GetFromPool(combo, "Sound") -- Using the helper function, a sound is gotten from the sound pool
				if soundItem then -- After we get it we customise its properties and parent it to the model
					local sound = soundItem.Obj
					sound.Parent = model.HumanoidRootPart -- Parenting it to the model for a realsitic audio effect
					sound:Play()
					task.delay(2, function() -- After we finish using it we stop it and parent it back to the pool
						sound:Stop()
						sound.Parent = nil
						soundItem.InUse = false
					end)
				else -- If not we debug it
					print("Sound Pool failed to fetch Combos Sound")
				end
				local vfxItem = GetFromPool(combo, "VFX") -- The same method is used to get the VFX item
				if vfxItem then
					local vfx = vfxItem.Obj
					vfx.Parent = model.HumanoidRootPart -- parenting it to the model for a hit effect
					for _, p in ipairs(vfx:GetChildren()) do -- We loop through the particles and emit them so the vfx gets enabled
						if p:IsA("ParticleEmitter") then
							p:Emit(10)
						end
					end
					task.delay(0.6, function()
						vfx.Parent = nil -- After we finish using it we stop it and parent it back to the pool
						vfxItem.InUse = false
					end)
				else
					print("VFX Pool failed to fetch Combos VFX")
				end
				hum:TakeDamage(ComboSettings[combo].Damage) -- Lastly we deal damage to the humanoid depending on the combo type
			end
		end
	end
	for i = #ActiveCombos, 1, -1 do -- Meanwhile we also run another loop to remove any processed notes immediately
		if ActiveCombos[i].Processed then
			table.remove(ActiveCombos, i)
		end
	end
end)
game.Players.PlayerAdded:Connect(function(plr) -- When a player joins we create attachments for each combo
	plr.CharacterAdded:Connect(function(char) -- Storing them in the ComboAttachs table
		if not char then return end
		local humanoid = char:WaitForChild("Humanoid")
		if not humanoid then return end
		-- We try to find out which rigtype the player is. for further notices either the script will support r15 or r6
		local leftPart = humanoid.RigType == Enum.HumanoidRigType.R6 and char.LeftArm or char.LeftHand
		local rightPart = humanoid.RigType == Enum.HumanoidRigType.R6 and char.RightArm or char.RightHand
		ComboAttachs[char] = {} -- Creating a table for the player only to avoid mixing instances
		-- Attachments are duplicated per combo to allow per-combo hit tuning customising ray placement for bigger hits or smaller hits
		for comboName, comboData in pairs(ComboSettings) do -- Looping through the ComboSettings to find out how much attachs are needed for each loop
			ComboAttachs[char][comboName] = { Left = {}, Right = {} } -- Creating a table for the combo to store the attachments
			for i = 1, comboData.Attach do -- Creating the desired amount of attachments for each hand per combo
				local left = Instance.new("Attachment", leftPart)
				left.Position = Vector3.new(-0.13, 0, 0.03)
				table.insert(ComboAttachs[char][comboName].Left, left)
				local right = Instance.new("Attachment", rightPart)
				right.Position = Vector3.new(0.13, 0, 0.03)
				table.insert(ComboAttachs[char][comboName].Right, right)
			end
		end
		for _, combo in pairs(ComboSettings) do -- Here is the logic to create the pool items
			for poolType, pool in pairs(combo.Pool) do
				for i = 1, 10 do
					table.insert(pool, CreatePoolItem(combo[poolType])) -- Here we create the pool items and store them in the pool using the helper function
				end
			end
		end
	end)
	game.Players.PlayerRemoving:Connect(function(player) -- When a player leaves we clean up the attachments
		local char = player.Character 
		if char then
			ComboAttachs[char] = nil -- Removing player from the table
		end
	end)
end)
Validate.OnServerEvent:Connect(function(player, combo) -- The Remote Event is called when the player wants to hit
	if not combo then return end -- If the combo is nil we return
	if not player then return end -- If the player is nil we return
	local char = player.Character 
	if not char then return end
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end
	local params = RaycastParams.new() -- We premake the raycast params to avoid making a new one every time
	params.FilterDescendantsInstances = { char } -- We exclude the player from the raycast
	params.FilterType = Enum.RaycastFilterType.Exclude
	local Notes ={ -- The remote event collects all this info and stores it in a table
			Player = player, -- The player hitting the combo
			Char = char, -- The character of the player hitting the combo
			Combo = combo, -- The Combo the player is hitting
			HitCache = {}, -- A table to store the characters that have been hit by the note to prevent double hits
			Processed = false, -- A flag to mark the note as processed
			StartTime = os.clock(), -- The time the note was created
			Duration = 0.35, -- The duration of the note
			RaycastParams = params -- The raycast params we premade
		}
	table.insert(ActiveCombos, Notes) -- We store the note in the ActiveCombos table
	-- The notes is like a note asking if the combo is valid and if it is its info is used to execute the hit
	local BV = ApplyVelocity(char, combo) -- We apply the body velocity to the player for a hitting effect
	Debris:AddItem(BV, 0.1) -- We remove the body velocity after 0.1 seconds to clean up
end)
