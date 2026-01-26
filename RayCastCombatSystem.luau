 -- Raycast-based melee combat system with combo tuning, VFX, knockback, and pooling.
--[[ FRAMEWORK OVERVIEW (READ THIS BEFORE ANYTHING OR YOULL BE LOST)
   Each hit request becomes a temporary 'note' table with combo, timing, and raycast data.
   Hits use attachment-driven raycasts; each combo controls coverage and precision.
   Notes are processed every Heartbeat for accurate hit detection over time.
]]
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Receives client combo requests for server-side validation
local catchHitRequests = ReplicatedStorage.Remotes.CallServer

--[[ 1. Tables for combat data:
   ActiveCombos: stores hit 'notes' from players
   ComboSettings: settings per combo
   ComboAttachments: attachments for raycasting ]]
local activeCombos = {}
local ComboAttachments = {} 
local ComboSettings = { 
	Combo1 = {
		VelocityStrength = 10, 
		VFX = ReplicatedStorage.VFX.HitVFX.Attachment, 
		Sound = script["Hit Sound"],
		KnockBackAnim = script.Anims.Combo1KnockBack,
		HitLength = 4, 
		Damage = 5,
		AttachmentCount = 1,
		Pool = { VFX = {}, Sound = {} } 
	},
	Combo2 = {
		VelocityStrength = 20,
		VFX = ReplicatedStorage.VFX.HitVFX.Attachment, 
		Sound = script["Hit Sound"],
		KnockBackAnim = script.Anims.Combo2KnockBack,
		HitLength = 5,
		Damage = 7,
		AttachmentCount = 1,
		Pool = { VFX = {}, Sound = {} }
	},
	Combo3 = {
		VelocityStrength = 30,
		VFX = ReplicatedStorage.VFX["Full Impact"].Attachment,
		Sound = script.SuperHit,
		KnockBackAnim = script.Anims.Combo3KnockBack,
		HitLength = 7,
		Damage = 10,
		AttachmentCount = 2,
		Pool = { VFX = {}, Sound = {} }
	},
}
--[[ 2. CreatePooledObjectItem : Table
	Creates a new pool item for the specified instance type.

	This function is only called when all existing pool items are in use
	and a new one must be created. This is a rare case, but without this
	function, the system would be more likely to break under heavy load.

	Object pooling is used because repeatedly creating and destroying
	instances at runtime is expensive and can cause spikes in CPU and
	memory usage.
]]
local function createPoolItem(instance:Instance) 
	return {
		Obj = instance:Clone(),
		InUse = false,
	}
end
--[[ 3. GetFromPool : Instance
    Attempts to retrieve a pool item from the specified pool.

    This function is called when a hit is registered and we need VFX or
    sound for aesthetic purposes. It takes two parameters: the combo
    name (e.g., Combo1, Combo2) and the pool type (VFX or Sound).
    
    It handles retrieving a pool item, tracking it and making a new one if
    there isnt one available.
]]
local function getFromPool(comboName:string, poolType:string)
	local combo = ComboSettings[comboName] 
	local pool = combo and combo.Pool[poolType]
	if not pool then
		return
	end
	for _, item in ipairs(pool) do
		if not item.InUse then 
			item.InUse = true
			return item
		end
	end
	local newItem = createPoolItem(combo[poolType]) 
	newItem.InUse = true
	table.insert(pool, newItem)
	return newItem
end
--[[ 4. CreatePoolItemOnPlayerAdded : Loop
    Pre-populates the ComboSettings pools with VFX and Sound objects when 
    a player joins. 
    
    Each combo gets a default of 6 objects (VFX and Sounds) 
    to handle typical combat situations. This ensures that the pool isn’t 
    empty and reduces runtime spikes when combos are used.
]]
local function createPoolItemOnPlayerAdded()
	for _, combo in pairs(ComboSettings) do 
		for poolType, pool in pairs(combo.Pool) do
			for i = 1, 6 do
				table.insert(pool, createPoolItem(combo[poolType])) 
			end
		end
	end
end
--[[ 5. ApplyVelocity : BodyVelocity
    Applies a knockback or push effect to the specified character by
    creating a BodyVelocity instance.
    
    Note: In the future, this will be updated to use pooling and
    switched to LinearVelocity for better performance and control.
]]
local function applyVelocity(character, combo:string, attacker)
	local root = character:FindFirstChild("HumanoidRootPart")
	local attackerRoot = attacker and attacker:FindFirstChild("HumanoidRootPart")
	local direction
	if attackerRoot then
		direction = attackerRoot.CFrame.LookVector
	else
		direction = root.CFrame.LookVector
	end
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(5e4, 0, 5e4)
	bodyVelocity.Velocity = direction * ComboSettings[combo].VelocityStrength
	bodyVelocity.Parent = root
	return bodyVelocity
end
--[[ 6. AddKnockback : Action
    Adds knockback to the specified character when hit.
    Plays a knockback animation and applies a BodyVelocity to push the enemy back.
    Ensures an Animator exists on the humanoid so the animation can play properly.
    Different combos can have varying knockback strength and animations to make 
    attacks feel distinct.
]]
local function addKnockback(humanoid:Humanoid, character, combo:string, player)
	local animator = humanoid:FindFirstChildOfClass("Animator") 
	if not animator then 
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	animator:LoadAnimation(ComboSettings[combo].KnockBackAnim):Play()
	local bodyVelocity = applyVelocity(character, combo,player) 
	if not bodyVelocity then
		print("BodyVelocity failed to fetch")
		return
	end
	Debris:AddItem(bodyVelocity, 0.1)
end 
--[[ 7. AddHitRequest : Action
    Adds a combo note to the ActiveCombos table for processing.
    
    This function is called when a player triggers a hit request.
    As explained in the framework section, each hit is converted
    into a temporary "note" table that contains all data required
    to process the combo over time.

    The note stores:
    1. The player triggering the combo
    2. The character performing the combo
    3. The combo name being used
    4. A hit cache to prevent double hits
    5. A processed flag for cleanup
    6. The time the note was created
    7. The duration the note remains active
    8. Preconfigured raycast parameters

    Once created, the note is inserted into ActiveCombos and is
    validated and processed every Heartbeat until it expires.
]]
local function addHitRequest(player, character, combo:string)
	local params = RaycastParams.new() 
	params.FilterDescendantsInstances = { character } 
	params.FilterType = Enum.RaycastFilterType.Exclude
	local notes = { 
		Player = player,
		Char = character,
		Combo = combo,
		HitCache = {}, 
		Processed = false, 
		StartTime = os.clock(),
		Duration = 0.35,
		RaycastParams = params,
	}
	table.insert(activeCombos, notes) 
end
--[[ 8. IsHitValid : Boolean
    Determines whether a hit is still valid based on timing and processing state.

    When a player triggers a hit, the remote event collects all the necessary
    information—such as the player, character, combo type, and timing—into a
    structured table called a "note". This note tracks the start time of the hit
    and how long it is considered valid (the duration).  

    This function checks if the note has already been processed or if the
    hit has exceeded its valid window. If the hit has expired, it marks the
    note as processed so that it can later be removed by RemoveNoteFromTable.
    This prevents double hits, spam hits, and ensures that each attack is
    only applied once during its intended timeframe.
]]
local function isHitValid(notes)
	if os.clock() - notes.StartTime > notes.Duration then 
		notes.Processed = true
		return false
	else
		return true
	end
end
--[[ 9. NoteValidity : Variables
    Used to check if the note has valid indexes.
    
    This function is called before processing a note to ensure it has all the
    required data. If any of the required data is missing, the function returns
    nil, indicating that the note is invalid or expired. This prevents errors and weird hits.
]]
local function noteValidity(note)
	if note.Processed or not isHitValid(note) then
			return nil
		end
		local char = note.Char
		local combo = note.Combo
		local hitCache = note.HitCache
		local raycastParams = note.RaycastParams
		if not char or not combo or not hitCache or not raycastParams then
			print("Invalid combo note: missing data")
			return nil
		end
		local root = char:FindFirstChild("HumanoidRootPart")
		if not root then
			return nil
		end
		local attachments = ComboAttachments[char] and ComboAttachments[char][combo]
		if not attachments then
			return nil
		end
		return char, combo, hitCache, raycastParams, attachments, root
end
--[[ 10. FetchAttachsTable : Table
    Retrieves the attachment set for a specific character and combo.

    This function is used to safely access the ComboAttachments table.
    
    Returning nil instead of indexing directly prevents runtime
    errors when characters, combos, or attachments are missing.
    This function acts as a small safety layer before hit processing.
]]
local function fetchAttachsTable(character, combo:string)
	local charTable = ComboAttachments[character] 
	if not charTable then
		return nil
	end
	local set = charTable and charTable[combo] 
	if not set then
		return nil
	end
	return set
end
--[[ 11. RegisterHit : Action
    Performs hit detection and applies combat effects.

    This function is called for each attachment during combo processing.
    It raycasts forward from the attachment’s world position using the
    character’s facing direction and the combo’s configured hit length.

    If a valid humanoid target is detected and has not already been hit
    by this combo note, the function:
    - Registers the hit in the hit cache to prevent double hits
    - Applies knockback and knockback animation
    - Plays pooled sound and visual effects
    - Deals damage based on the combo settings

    This function represents the core hit-resolution logic of the
    combat system, combining detection, feedback, and damage handling
    in a single controlled execution path.
]]
local function registerHit(attach, character, combo:string, hitCache, raycastParams, attachments, root)
	local origin = attach.WorldPosition 
	local direction = root.CFrame.LookVector * ComboSettings[combo].HitLength
	local result = workspace:Raycast(origin, direction, raycastParams)

	if not result then
		return
	end 
	local model = result.Instance:FindFirstAncestorOfClass("Model") 
	if not model or model == character then
		return
	end 
	local root = model:FindFirstChild("HumanoidRootPart") 
	if not root then
		return
	end 
	local hum = model:FindFirstChildOfClass("Humanoid") 
	if not hum or hum.Health <= 0 then
		return
	end 
	if hitCache[hum] then
		return
	end 

	hitCache[hum] = true 
	addKnockback(hum,model,combo,character)

	local soundItem = getFromPool(combo, "Sound")
	if soundItem then 
		local sound = soundItem.Obj
		sound.Parent = model.HumanoidRootPart 
		sound:Play()

		task.delay(2, function() 
			sound:Stop()
			sound.Parent = nil
			soundItem.InUse = false
		end)
	else 
		print("Sound Pool failed to fetch Combos Sound")
	end

	local vfxItem = getFromPool(combo, "VFX") 
	if vfxItem then
		local vfx = vfxItem.Obj
		vfx.Parent = model.HumanoidRootPart 
		for _, p in ipairs(vfx:GetChildren()) do 
			if p:IsA("ParticleEmitter") then
				p:Emit(10)
			end
		end
		task.delay(0.6, function()
			vfx.Parent = nil 
			vfxItem.InUse = false
		end)
	else
		print("VFX Pool failed to fetch Combos VFX")
	end
	hum:TakeDamage(ComboSettings[combo].Damage) 
end

--[[ 12. RemoveNoteFromTable : Cleanup
    Cleans up processed combo notes or else if notes stay in the table 
    they will continue to run hits over and over again which can crash.
    Causing duplicate hits and spam hits.
]]
local function removeNoteFromTable(i) 
	if activeCombos[i].Processed then
		table.remove(activeCombos, i)
	end
end
--[[ 13. ProcessComboNote : Action
    Processes a single combo note during the Heartbeat loop.

    This function is called for each active note stored inthe ActiveCombos table. 
    It first validates the note using NoteValidity to ensure all required data still 
    exists and that the hit has not expired.

    If the note is valid, the function fetches the attachment sets associated
    with the character and combo, the calls registerHit for each attachment.
]]
local function processComboNote(note)
	local char, combo, hitCache, raycastParams, attachments, root = noteValidity(note)
	if not char then
		return
	end
	local set = fetchAttachsTable(char, combo)
	if not set then
		return
	end
	for _, handTable in pairs(set) do
		for _, attach in ipairs(handTable) do
			registerHit(attach, char, combo, hitCache, raycastParams, attachments, root)
		end
	end
end
--[[ 14. FindRigType : Body Parts
    Determines the correct limb parts based on the character's rig type.

    Roblox characters can use either R6 or R15 rigs, which have different
    limb naming conventions. This function checks the Humanoid's RigType
    and returns the appropriate left and right limb parts accordingly.

    This abstraction ensures that the combat system works seamlessly
    across both rig types without duplicating logic elsewhere.
]]
local function findRigType(character, humanoid:Humanoid)
	local rightPart, leftPart
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		leftPart = character:WaitForChild("LeftArm")
		rightPart = character:WaitForChild("RightArm")
	elseif humanoid.RigType == Enum.HumanoidRigType.R15 then
		leftPart = character:WaitForChild("LeftHand")
		rightPart = character:WaitForChild("RightHand")
	end
	return leftPart, rightPart
end
--[[ 15. CreateAttachments : Loop
    Creates and assigns hit-detection attachments for each combo.

    This function generates a set of attachments for every combo defined
    in ComboSettings and parents them to the character’s left and right
    hand (or arm) parts. The number of attachments created is determined
    by the combo’s AttachmentCount setting.

    These attachments act as dynamic raycast origins during combat,
    allowing hit detection to follow animated limb movement rather than
    relying on static hitboxes. All attachments are stored in the
    ComboAttachments table for fast access during processing.
]]
local function createAttachments(character, leftPart, rightPart)
	ComboAttachments[character] = {} 
	for comboName, comboData in pairs(ComboSettings) do 
		ComboAttachments[character][comboName] = { Left = {}, Right = {} } 
		for i = 1, comboData.AttachmentCount do 
			local left = Instance.new("Attachment", leftPart)
			left.Position = Vector3.new(-0.13, 0, 0.03)
			table.insert(ComboAttachments[character][comboName].Left, left)

			local right = Instance.new("Attachment", rightPart)
			right.Position = Vector3.new(0.13, 0, 0.03)
			table.insert(ComboAttachments[character][comboName].Right, right)
		end
	end
end
--[[ 16. Heartbeat : Loop
    The main processing loop for all active combo notes.

    This function runs every frame and is responsible for validating
    and processing each active combo note. Without this loop, none of
    the combat logic would execute.

    For each active note, the system checks validity and runs hit
    detection through RegisterHit using the note’s attachments.
    
    A secondary loop is used to clean up notes that have been marked
    as processed, ensuring expired combos are removed and duplicate
    hits cannot occur.
]]
RunService.Heartbeat:Connect(function()
	for _, note in ipairs(activeCombos) do
		processComboNote(note)
	end
	for i = #activeCombos, 1, -1 do
		removeNoteFromTable(i) 
	end
end)
--[[ 17. PlayerAdded : Event
    Handles character setup when a player joins the game.

    When a player is added, three main setup steps are performed:
    1. Uses FindRigType to determine the correct left and right
       arm/hand parts based on the character’s rig (R6 or R15).
    2. Creates attachments on the character’s limbs, which are later
       used to perform raycasts for accurate melee hit detection.
    3. Expands the global object pools to account for the new player.
       More players means more concurrent VFX and sounds may be
       required during combat.
]]
Players.PlayerAdded:Connect(function(player) 
	player.CharacterAdded:Connect(function(char)
		if not char then
			return
		end
		local humanoid = char:WaitForChild("Humanoid")
		if not humanoid then
			return
		end
		local leftPart, rightPart = findRigType(char,humanoid)
		if not leftPart or not rightPart then
			return print("Problem in fetching BodyParts")
		else
			createAttachments(char, leftPart, rightPart)
		end
		task.spawn(createPoolItemOnPlayerAdded)
	end)
end)
--[[ 18. PlayerRemoving : Event
    Cleans up character-related data when a player leaves the game.

    This function is called when a player is removed from the server.
    It clears the attachment data stored for the player’s character
    from the ComboAttachments table. This ensures that no unnecessary
    tables or references remain in memory once the character is gone,
    preventing memory leaks and stale data from being accessed later.
]]
Players.PlayerRemoving:Connect(function(player) 
	local char = player.Character
	if char then
		ComboAttachments[char] = nil 
	end
end)
--[[ 19. CatchHitRequests : RemoteEvent
    Handles hit requests sent from the client.

    In the LocalScript, when the player presses MouseButton1, the current
    combo index is calculated and sent to the server using this RemoteEvent.
    The server receives both the player and the combo name being used.

    Before creating a hit note, the server validates that the player,
    character, and combo still exist. This prevents invalid or malicious
    requests from creating unwanted notes.

    Once validated, AddHitRequest is called to convert the hit into a
    temporary note containing all required combat data. This note is then
    inserted into the ActiveCombos table for server-side processing.

    A brief push effect is also applied to the attacking player to enhance
    feedback and make hits feel more impactful and responsive.
]]
catchHitRequests.OnServerEvent:Connect(function(player, combo:string) 
	if not combo then
		return
	end 
	if not player then
		return
	end 
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	addHitRequest(player,char,combo)
	local bodyVelocity = applyVelocity(char, combo)
	Debris:AddItem(bodyVelocity, 0.1)
end)

