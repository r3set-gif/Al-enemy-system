-- Raycast-based melee combat system with combo tuning, VFX, knockback, and pooling.
--[[ FRAMEWORK OVERVIEW (READ THIS BEFORE ANYTHING OR YOU'LL BE LOST)
     Hit requests are fired from the client. Each hit request is caught and
     turned into a temporary 'note' table containing all the data needed to
     execute a hit. Attachments are created in body parts of the player this is 
     needed for ray detection attachments act like a guide so we can fetch its 
     position and catch the rays from their. Notes are added into one global table
     and processed by one global heartbeat loop.
]]
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local catchHitRequests = ReplicatedStorage.Remotes.CallServer

-- 0.5 This is a extra check that the pool function is only ran once 
-- avoiding multiple loops or uneeded instances
local poolsCreated = false

--[[ 1. Tables
1.1 cacheTracks: is a table that holds references to animation tracks that
    have already been loaded. This avoids repeatedly loading the same
    animations, saving resources.

1.2 activeCombos: is a table that holds all hit requests sent by every
   player. It is essential for tracking hit requests. I made this table
   player-shared for simplicity, so I don’t need nested loops or mulitple
   loops running at the same time on every players hit requests table to 
   access a specific player’s data. For scalability, it would be better 
   to use per-player keys instead.

1.3 ComboSettings: controls the customization of hits. It acts as a
   “customization board” that lets me easily alter the feel of combat.
   Placing it at the top of the script allows me to add new combos by
   simply adding another entry, as long as the key matches the combo’s
   name. To add a new entry mostly requires adding to local script
   logic and just adding a new entry to the ComboSettings table.

1.4 ComboAttachments holds all attachments made on a player’s rig. This
    is a player-shared table that helps with easy tracking, avoiding the 
    need to iterate over the player’s character repeatedly, and allows 
    fast access to attachments.
]]

local cacheTracks = {}
local activeCombos = {}
local ComboAttachments = {} 
local ComboSettings = { 
	Combo1 = {
		VelocityStrength = 10, 
		VFX = ReplicatedStorage.VFX.HitVFX.Attachment, 
		Sound = script["Hit Sound"],
		KnockBackAnim = script.Anims.Combo1KnockBack,
		HitLength = 3, 
		Damage = 5,
		AttachmentCount = 1,
		Pool = { VFX = {}, Sound = {} } 
	},
	Combo2 = {
		VelocityStrength = 15,
		VFX = ReplicatedStorage.VFX.HitVFX.Attachment, 
		Sound = script["Hit Sound"],
		KnockBackAnim = script.Anims.Combo2KnockBack,
		HitLength = 4,
		Damage = 7,
		AttachmentCount = 1,
		Pool = { VFX = {}, Sound = {} }
	},
	Combo3 = {
		VelocityStrength = 20,
		VFX = ReplicatedStorage.VFX["Full Impact"].Attachment,
		Sound = script.SuperHit,
		KnockBackAnim = script.Anims.Combo3KnockBack,
		HitLength = 5,
		Damage = 10,
		AttachmentCount = 2,
		Pool = { VFX = {}, Sound = {} }
	},
}
--[[2. Pool System : Optimization
The reason for creating a pool system was to reduce CPU spikes. Before
the pool, the script would create a new VFX and sound for every hit,
which was expensive and could hurt performance as more players joined.
With the pool system, VFX and sound are pre-made and reused, causing
only a minor spike at the start instead of repeated spikes throughout
the game.

2.1 POOL_INCREMENT
This determines how many instances are pre-made when a player joins.
It is set to 6, so 6 instances are created per player join and 6 are
removed when a player leaves. More players = bigger pool. VFX and
sounds are custom per combo, which makes the structure nested.

2.2 createPoolItem -- Creates emergency instances if pool is unavailable
A helper function that creates a new instance of a VFX or sound.
Each instance has an InUse flag so that, in rare cases where all
instances are being used, a new one can be created. Simply pass the
type of instance you need, and it returns a new one.

2.3 getFromPool -- Helps Access the pool
This retrieves an instance from the pool. It handles checking for
availability and creating a new instance if needed. It acts as the
main pool management function.

2.4 createPools -- Handles premaking instances in the pool
This loops through all combos and pre-makes instances when a player
joins. It ensures the pool is ready and not empty, so items are
instantly available when needed.

2.5 decreasePoolSize -- Handles Pool Cleanup 
The inverse of createPools, this reduces pool size when a player
leaves. This prevents excessive memory usage and potential lag from
keeping unused instances around.

The nested logic in decreasePoolSize and createPools exists because
each combo has its own sound and VFX, and the pools are stored inside
ComboSettings. This makes loops multi-level and harder to read.

For future improvements, it would be better to store pools in a separate
table, outside of ComboSettings. This would reduce nesting and improve
the readability and maintainability of the script.
]]
local POOL_INCREMENT = 6 
local function createPoolItem(instance:Instance) 
	return {
		Obj = instance:Clone(),
		InUse = false,
	}
end
local function getFromPool(comboName:string, poolType:string)
	local combo = ComboSettings[comboName] 
	if not combo then
		warn("Invalid combo:", comboName)
		return nil
	end
	local pool = combo and combo.Pool[poolType]
	if not pool then
		warn("Invalid pool type:", poolType, "for", comboName)
		return nil
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
local function createPools()
	if poolsCreated then
		return
	end
	for _, combo in pairs(ComboSettings) do 
		for poolType, pool in pairs(combo.Pool) do
			for i = 1, POOL_INCREMENT do
				table.insert(pool, createPoolItem(combo[poolType])) 
			end
		end
	end
end
local function decreasePoolSize()
	for _, combo in pairs(ComboSettings) do
		for poolType, pool in pairs(combo.Pool) do
			local removed = 0
			for i = #pool, 1, -1 do
				local item = pool[i]
				if not item.InUse then
					table.remove(pool, i)
					if item.Obj then
						Debris:AddItem(item.Obj, 0.1)
					end
					removed += 1
					if removed >= POOL_INCREMENT then
						break 
					end
				end
			end
		end
	end
end
--[[3. Impact and Knockback Effects : Visuals
These features are used to add a more realistic feel to combat.
LinearVelocity is used to create a visual effect when a player hits
another player. Even a small hit applies a subtle push, giving the
sense of stepping forward or impact.

3.1 applyVelocity – Creates a LinearVelocity instance and applies
it for 0.1 seconds. 
The strength of the velocity is controlled by ComboSettings, 
so stronger combos produce stronger impacts, while lighter 
hits feel smaller, mimicking real-world combat physics.

Each player has only one velocity instance created, which is reused
via the Enabled property. This reduces memory usage by avoiding
repeated creation and destruction of instances. The function handles
both small step-forward pushes and knockback effects. The attacker
parameter determines the direction of the velocity.

3.2 addKnockback – Handles the knockback animation and velocity.
This is called after a hit is registered and the sound is played.
Animations are loaded only once for optimization, and it reuses
applyVelocity to push the opponent back appropriately.
]]
local function applyVelocity(character, combo, attacker)
	if not character then 
		return
	end

	local comboData = ComboSettings[combo]
	if not comboData or not comboData.VelocityStrength then 
		return 
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then 
		return 
	end

	local velocityAttachment = root:FindFirstChild("VelocityAttachment")
	if not velocityAttachment then
		velocityAttachment = Instance.new("Attachment")
		velocityAttachment.Name = "VelocityAttachment"
		velocityAttachment.Parent = root
	end

	local linearVelocity = root:FindFirstChild("KnockbackVelocity")
	if not linearVelocity then
		linearVelocity = Instance.new("LinearVelocity")
		linearVelocity.Name = "KnockbackVelocity"
		linearVelocity.Attachment0 = velocityAttachment
		linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
		linearVelocity.MaxForce = math.huge
		linearVelocity.Parent = root
	end

	local direction = root.CFrame.LookVector
	if attacker then
		local attackerRoot = attacker:FindFirstChild("HumanoidRootPart")
		if attackerRoot then
			local diff = root.Position - attackerRoot.Position
			if diff.Magnitude > 0 then
				direction = diff.Unit
			end
		end
	end

	linearVelocity.VectorVelocity = direction * comboData.VelocityStrength
	linearVelocity.Enabled = true

	task.delay(0.1, function()
		if linearVelocity then
			linearVelocity.Enabled = false
		end
	end)
end
local function addKnockback(humanoid:Humanoid, character, combo:string, player)
	local animator = humanoid:FindFirstChildOfClass("Animator") 
	if not animator then 
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local anim = ComboSettings[combo].KnockBackAnim
	if not anim then
		return
	end
	local track = cacheTracks[humanoid][combo]
	if not track then
		track = animator:LoadAnimation(anim)
		cacheTracks[humanoid][combo] = track
	end
	track:Play()
	applyVelocity(character, combo, player) 
end 
--[[4. Hit Creating Process 
4.1 addHitRequest – Creates a note for the hit request and inserts
it into activeCombos. This approach is easy to scale because different
note types can be added in the future for special hits, and more
properties can be added to each note. Functions can then be updated
to process those new note types.

Each note only exists in the table for a short time. If it remains too
long, it becomes invalid (missed hit) or already processed. This is
necessary because combat is fast, and the script executes hits quickly.
Leaving notes in the table too long could result in repeated or
duplicate hits, which would break the combat logic.
]]
local function addHitRequest(player, character, combo:string)
	if not ComboSettings[combo] then
		warn("Rejected hit request: invalid combo", combo)
		return
	end
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
--[[5. Hit Registering System
5.1 isHitValid – Checks whether the note is still valid. Every note
is tracked using an os.clock timer. This ensures that, regardless of
circumstance, the note is removed after its duration expires. It’s safer
for a note to expire than to linger, because lingering notes could
cause repeated hits, crashes, or lag.

5.2 noteDataChecks – Verifies that the note contains all necessary
data before execution. This is a second layer of security to prevent
errors or undefined behavior. Without this check, the script could
fail or behave unpredictably. Only valid notes are returned for
processing.

5.3 registerHit – Called once a note is valid. This is where the
hit is executed for each attachment. Raycasts are performed for every
attachment, and when a hit is detected, the function fetches VFX,
sound, knockback effects from the pool, and applies damage. This is
a heavy function, so for future improvements, you could separate VFX,
sound, and knockback logic for clarity and maintainability.

5.4 processActiveNote – Coordinates the processing of a note. It
checks the note via noteDataChecks and then executes it with
registerHit. It also iterates through the player’s attachments to
determine the correct positions for raycast detection. This is the
central function that brings all the note processing together.
]]
local function isHitValid(notes)
	if notes.Processed then
		return false
	end
	
	if os.clock() - notes.StartTime > notes.Duration then 
		notes.Processed = true
		return false
	else
		return true
	end
end
local function noteDataChecks(note)
	if note.Processed or not isHitValid(note) then
		return nil
	end
	local char = note.Char
	local combo = note.Combo
	local hitCache = note.HitCache
	local raycastParams = note.RaycastParams
	if not char or not combo or not hitCache or not raycastParams then
		note.Processed = true
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
local function registerHit(attach, character, combo:string, hitCache, 
	raycastParams, attachments, root)
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
		if hum.Parent == nil then
			hitCache[hum] = nil
		else
			return
		end
	end 

	hitCache[hum] = true 
	addKnockback(hum, model, combo, character)

	local soundItem = getFromPool(combo, "Sound")
	if soundItem then 
		local sound = soundItem.Obj
		if sound.Parent ~= model.HumanoidRootPart then
			sound.Parent = model.HumanoidRootPart 
		end
		sound:Play()

		task.delay(2, function() 
			sound:Stop()
			soundItem.InUse = false
			sound.Parent = nil
		end)
	else 
		print("Sound Pool failed to fetch Combos Sound")
	end

	local vfxItem = getFromPool(combo, "VFX") 
	if vfxItem then
		local vfx = vfxItem.Obj
		if vfx.Parent ~= model.HumanoidRootPart then
			vfx.Parent = model.HumanoidRootPart 
		end
		for _, p in ipairs(vfx:GetChildren()) do 
			if p:IsA("ParticleEmitter") then
				p:Emit(10)
			end
		end
		task.delay(0.6, function()
			vfxItem.InUse = false
			vfx.Parent = nil 
		end)
	else
		print("VFX Pool failed to fetch Combos VFX")
	end
	hum:TakeDamage(ComboSettings[combo].Damage) 
end
local function processActiveNote(note)
	local char, combo, hitCache, raycastParams, attachments, root = noteDataChecks(note)
	if not char then
		return
	end
	for _, handTable in pairs(attachments) do
		for _, attach in ipairs(handTable) do
			registerHit(attach, char, combo, hitCache, raycastParams, attachments, root)
		end
	end
end
--[[ 6. Attachment Creating Process
This section explains how attachments are used to track positions for
raycasts to detect hits. The system is flexible so it can support both
R6 and R15 rigs, though R6-only could simplify things in the future.

6.1 findRigType – Determines the rig type of a character. We need
access to the left and right arms, but R6 and R15 rigs name these parts
differently. This function stores references to the correct parts based
on the rig type so that attachments can be created reliably. This also
prevents errors when iterating through attachments later.

6.2 createAttachments – Creates attachments in the hands based on
the rig type. First, it cleans up any existing attachments for that
player to avoid memory leaks when a character respawns or dies. Then,
it stores attachments in a table keyed by character for easy access.
Attachments are positioned relative to the hands and serve as temporary
raycast origins for hit detection. This allows the system to check hit
positions accurately and consistently for each combo.
]]
local function findRigType(character, humanoid:Humanoid)
	local rightPart, leftPart
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		leftPart = character:FindFirstChild("LeftArm")
		rightPart = character:FindFirstChild("RightArm")
	elseif humanoid.RigType == Enum.HumanoidRigType.R15 then
		leftPart = character:FindFirstChild("LeftHand")
		rightPart = character:FindFirstChild("RightHand")
	end
	return leftPart, rightPart
end
local function createAttachments(character, leftPart, rightPart)
	if ComboAttachments[character] then
		for _, combo in pairs(ComboAttachments[character]) do
			for _, hand in pairs(combo) do
				for _, attach in ipairs(hand) do
					if attach and attach.Parent then
						attach:Destroy()
					end
				end
			end
		end
	end

	ComboAttachments[character] = {} 
	for comboName, comboData in pairs(ComboSettings) do 
		ComboAttachments[character][comboName] = { Left = {}, Right = {} } 

		local leftSize = leftPart.Size
		local rightSize = rightPart.Size

		for i = 1, comboData.AttachmentCount do 
			local factor = (i / (comboData.AttachmentCount + 1)) - 0.5

			local left = Instance.new("Attachment", leftPart)
			left.Position = Vector3.new(leftSize.X * factor, 0, leftSize.Z * 0.1)
			table.insert(ComboAttachments[character][comboName].Left, left)

			local right = Instance.new("Attachment", rightPart)
			right.Position = Vector3.new(rightSize.X * factor, 0, rightSize.Z * 0.1)
			table.insert(ComboAttachments[character][comboName].Right, right)
		end
	end
end
--[[ 7. Heartbeat Loop
This is the main loop for processing hit requests. Notes can arrive at any
time, so the system needs to constantly check for new notes and process
them. The loop also removes notes that have already been processed or
expired. Running this per frame ensures hit detection is accurate and
timely. Delays in registering or deleting notes could cause delayed hits
or accidental repeated hits, which would break the feel of the combat.
]]
RunService.Heartbeat:Connect(function()
	for i = #activeCombos, 1, -1 do
		local note = activeCombos[i]
		processActiveNote(note)
		if note.Processed then
			table.remove(activeCombos, i)
			continue
		end
	end
end)
--[[ 8. Player Setup
When a player joins, we need to prepare the combat system for them.
The pool system is checked and created only once to avoid repeated
spikes and ensure all combos have preloaded VFX and sounds.

We then wait for the player’s character to spawn. Using the humanoid,
we determine the rig type (R6 or R15) so we know which hand parts to
attach raycast points to. This allows the combat system to work for
different rig types without hardcoding part names.

Finally, we create attachments on the hands. These attachments act as
tracking points for hit detection, stored in ComboAttachments for
fast access and easy cleanup later. This setup ensures hits are
accurately registered and avoids iterating over the character every frame.
]]
Players.PlayerAdded:Connect(function(player) 
	if not poolsCreated then
		createPools()
		poolsCreated = true
	end
	player.CharacterAdded:Connect(function(char)
		if not char then return end

		local humanoid = char:FindFirstChild("Humanoid")
		if not humanoid then return end

		local leftPart, rightPart = findRigType(char, humanoid)
		if not leftPart or not rightPart then
			return warn("Problem in fetching BodyParts")
		end

		createAttachments(char, leftPart, rightPart)
	end)
end)
--[[ 9. Player Cleanup
When a player leaves, we need to clean up everything associated with them.
Their attachments in ComboAttachments are cleared to avoid memory leaks
and dangling references. Active hit requests from that player are removed
from activeCombos as a safety check so no hits are processed for a
player who isn’t in the game.

The pool system is also adjusted. Since fewer players are present, the
demand for VFX and sound decreases, so we call decreasePoolSize to
remove unused instances and save memory. This ensures the system stays
efficient and prevents unnecessary growth of the pool over time.
]]
Players.PlayerRemoving:Connect(function(player) 
	local char = player.Character
	if char then
		ComboAttachments[char] = nil 
	end
	for i = #activeCombos, 1, -1 do
		if activeCombos[i].Player == player then
			table.remove(activeCombos, i)
		end
		
	end
	decreasePoolSize()
end)
--[[ 10. Hit Request
This is where hit requests are received from the client and converted
into notes for processing. Each note represents a single hit and
stores all necessary data like the player, target, combo type, and
raycast info.

After the note is created, a small forward push is applied to the
attacking player using applyVelocity. This adds a subtle step-
forward effect, making the combat feel more responsive and realistic.
]]
catchHitRequests.OnServerEvent:Connect(function(player, combo:string) 
	if not combo then return end
	if not player then return end
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end

	addHitRequest(player, char, combo)
	applyVelocity(char, combo)
end)
