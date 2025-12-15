-- A singular NPC AI system that tries to mimick realistic human-like behaviour 
-- SERVICES --
local PFS = game:GetService("PathfindingService") -- Service used in navigation for NPC
-- REFERENCES --
local Enemy = workspace:WaitForChild("Policeman") -- The Enemy reference
local EnemyHRP = Enemy:WaitForChild("HumanoidRootPart") -- HRP reference to get its CFrame.lookvector further on in the script
local BuildingZone = workspace:WaitForChild("Patrol Zone") -- The zone the NPC Patrols (Part)
-- AI STATE VARIABLES --
local State = "Patrol" -- The Main State variable keeps track of what state npc is in. Implementing a FSM (Finite State Machine)
local TargetPlayer = nil -- The player who will be chased
-- DISTANCE CHECKING VARIABLES --
local DETECTION_RADIUS = 45 -- The radius distance you need to be to get chased
local ALERT_RADIUS = 60 -- The radius distance you need to be to Alert the NPC
-- ALERT VARIABLES --
local ALERT_COUNT = 2 -- How much times the NPC will look around before going back to normal
local ALERT_VIEW_ANGLE = 140 -- In alert mode NPC scans area by rotating itself this is the total degrees it rotates each side
local ALERT_TRIES = 0 -- How many times the NPC has been Alerted in a row without successfully finding a player.
local alertCooldownRemaining = 0 -- Prevent double alerts or glitchy behaviour 
local SWEEP_ANGLE = ALERT_VIEW_ANGLE / 2 -- 40 degrees each side. Variable made for better readability and control. 
-- ATTACK VARAIBLES --
local ATTACK_RANGE = 4 -- How close the NPC should be to attack the player
local ATTACK_COOLDOWN = 1 -- Cooldown time self explainantory 
local ATTACK_DAMAGE = 10 -- Damage on player/per hit
local lastAttack = 0 -- Time between attacks
-- PATROLLING BOUNDS -- Calculates the Axis and bounds of the patrol zone using vector math to help in generating patrol points
local SizeX = BuildingZone.Size.X / 2
local SizeZ = BuildingZone.Size.Z / 2
local MiniX = BuildingZone.Position.X - SizeX
local MaxiX = BuildingZone.Position.X + SizeX
local MiniZ = BuildingZone.Position.Z - SizeZ
local MaxiZ = BuildingZone.Position.Z + SizeZ
-->> FUNCTIONS
-- VISION SYSTEM: The vision system is made up of 2 functions. LineOfSight and InViewingAngle also 
-- LineOfSight(): A boolean function that tells us if a player is accessible to chase without any obstacles interfering
-- This is one part of the vision system but this alone doesnt tell us if the player can be chased because 
-- the npc should not be able to chase players who are behind them to mimick real life behaviour.
local function LineOfSight(plr) 
	-- First 4 lines check that we have the targetplayer and its hrp if not the function returns false
	local char = plr.Character
	if not char then return false end
	local playerHRP = char:FindFirstChild("HumanoidRootPart")
	if not playerHRP or not EnemyHRP then return false end 
	-- RayCasting from the Enemy to the TargetPlayer to detect if we can see them or if something is blocking them.
	local dir = playerHRP.Position - EnemyHRP.Position -- Calculates the direction from the npc to the player
	local rayparams = RaycastParams.new() 
	rayparams.FilterDescendantsInstances = {Enemy}
	rayparams.FilterType = Enum.RaycastFilterType.Exclude -- Creating raycast params and excluding npc from being detected by it
	local result = workspace:Raycast(EnemyHRP.Position, dir, rayparams) -- Shoots out raycast in direction of player
	-- If there is no result then there is no obstacle and it returns true meaning the player can be seen or the result is the player which also returns true
	if not result or result.Instance:IsDescendantOf(char) then return true else return false end 
end 
-- InViewAngle(): A boolean function that tells us if a player is in the viewing angle of the enemy returns false or true.
-- This prevents if the player is behind the enemy and not in the viewing angle.
local function InViewAngle(plr)
	-- First 4 lines check that we have the targetplayer and its hrp if not the function returns false
	local char = plr.Character
	if not char then return false end
	local plrHRP = char:FindFirstChild("HumanoidRootPart")
	if not plrHRP or not EnemyHRP then return false end 
	local npcLookDir = EnemyHRP.CFrame.LookVector -- Reference for where the npc is looking
	local dirToPlayer = (plrHRP.Position - EnemyHRP.Position).Unit -- Finds the direction to the player
	-- Creates a cone vision for the npc to reflect human like behaviour having the ability to see realistically
	local dot = npcLookDir:Dot(dirToPlayer) 
	return dot >= math.cos(math.rad(SWEEP_ANGLE)) -- Returns true if the player is in the dot product created
end
-- GetPatrolPoint(): Helper Function that returns a random point in the bounds used for the patrol.
local function GetPatrolPoint()
	local randomX = MiniX + math.random() * (MaxiX - MiniX) -- Using bounds and CFrame math to get random point in bounds
	local randomZ = MiniZ + math.random() * (MaxiZ - MiniZ)
	return Vector3.new(randomX, EnemyHRP.Position.Y, randomZ) -- Returns the random point
end
-- GetClosestPlayer(): Returns the closest player to the enemy
local function GetClosestPlayer() 
	local closestDist = math.huge
	for _, plr in ipairs(game.Players:GetPlayers()) do -- Loops around players to find the closet one using magnitude then returns the distance and the player
		local char = plr.Character
		if not char then continue end
		local HRP = char:FindFirstChild("HumanoidRootPart")
		if not HRP then continue end
		local dist = (HRP.Position - EnemyHRP.Position).Magnitude
		if dist < closestDist then
			closestDist = dist
			TargetPlayer = plr
		end
	end
	return TargetPlayer, closestDist
end
-- Chase(): Main function that handles the chasing and attacking of the enemy
local function Chase(plr) -- Runs only when State == "Chase" 
	print("Chasing") -- This function runs when player is in DETECTION_RADIUS 
	if not plr or not plr.Character then -- If player is not found it returns to patrol
		State = "Patrol" -- Resets State
		TargetPlayer = nil -- Resetting Target Player
		return
	end
	local humanoid = plr.Character:FindFirstChild("Humanoid")
	local HRP = plr.Character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not HRP then -- If humanoid or HRP is not found either it returns to patrol
		State = "Patrol"
		TargetPlayer = nil
		return
	end
	local attempts = 0 -- Path finding attempts until it gives up and resets to patrol
	local path
	repeat -- Repeats this block of code until...
		attempts += 1 -- It retries max 10 times to get to player 
		path = PFS:CreatePath() -- Creating paths to the player 
		pcall(function() -- Pcall for path finding errors
			path:ComputeAsync(EnemyHRP.Position, HRP.Position)
		end)
	until path.Status == Enum.PathStatus.Success or attempts > 10 -- Until it gets to max attempts or path is successful
	if attempts > 10 then State = "Patrol" return end -- If not successful in 10 attempts it returns to patrol
	for _, wp in ipairs(path:GetWaypoints()) do -- Loop that moves the enemy to the player
		if State ~= "Chase" then break end -- If the state changes to something else it breaks the loop
		local dist = (HRP.Position - EnemyHRP.Position).Magnitude
		local canSee = InViewAngle(plr) and LineOfSight(plr) -- Constantly checks if the player is in the vision system
		if dist > DETECTION_RADIUS or not canSee then -- If the player is out of range while chasing or we cant see them it breaks the loop
			State = "Patrol" -- returning back to patrol
			TargetPlayer = nil -- and resetting the target player
			break
		end
		if wp.Action == Enum.PathWaypointAction.Jump then -- If the path requires the NPC to jump it does
			Enemy.Humanoid.Jump = true
		end
		if dist <= ATTACK_RANGE and tick() - lastAttack >= ATTACK_COOLDOWN then -- If its in the ATTACK_RANGE then it attacks the player while checking cooldown
			lastAttack = tick() -- times when last attack was made
			humanoid:TakeDamage(ATTACK_DAMAGE)  -- Deals damage to player
		end
		Enemy.Humanoid:MoveTo(wp.Position) -- Moves itself to the next waypoint
		Enemy.Humanoid.MoveToFinished:Wait() -- Waits until NPC reaches the waypoint
	end
end
-- Patrol(): Main function that handles the patroling of the npc of an area
local function Patrol() -- Runs when State == "Patrol"
	print("Patroling")
	local attempts = 0 -- Same attempt system regarding the attempt of making paths to the points from GetPatrolPoint()
	local path
	repeat -- Same repeat implementation as the one in the chase function
		attempts += 1 -- Also added max 10 attempts to avoid overload
		path = PFS:CreatePath()
		pcall(function() -- Gets a random point in the Patrol Zone and computes a path
			path:ComputeAsync(EnemyHRP.Position, GetPatrolPoint())
		end)
	until path.Status == Enum.PathStatus.Success or attempts > 10
	if attempts > 10 then return end

	for _, wp in ipairs(path:GetWaypoints()) do -- NPC moving towards that point
		if State ~= "Patrol" then break end
		if wp.Action == Enum.PathWaypointAction.Jump then
			Enemy.Humanoid.Jump = true
		end
		Enemy.Humanoid:MoveTo(wp.Position)
		Enemy.Humanoid.MoveToFinished:Wait()
	end
	task.wait(math.random(1, 3)) -- Waiting time for natural feel 
end
-- Alert(): Main function that handles the alerting of the npc of the player
local function Alert() -- Runs when State == "Alert".
	local hrp = EnemyHRP
	local base = hrp.CFrame
	local stepTime = 0.005
	local stepAngle = 2
	-- Loop 1 that rotates right
	for dir = -SWEEP_ANGLE, SWEEP_ANGLE, stepAngle do 
		if State ~= "Alert" then break end -- if State changes while alert runs it breaks the loop
		hrp.CFrame = base * CFrame.Angles(0, math.rad(dir), 0) -- each iteration it rotates the hrp by 2 degrees
		local plr, dist = GetClosestPlayer() -- gets closet player 
		if plr and dist <= DETECTION_RADIUS and InViewAngle(plr) and LineOfSight(plr) then -- checking if they are in view as it scans the area
			State = "Chase" -- if they are in view it switches to chase 
			return
		end
		task.wait(stepTime)
	end
	-- Loop 2 that rotates left
	for dir = SWEEP_ANGLE, -SWEEP_ANGLE, -stepAngle do -- same as the one above but it goes left
		if State ~= "Alert" then break end
		hrp.CFrame = base * CFrame.Angles(0, math.rad(dir), 0)
		local plr, dist = GetClosestPlayer()
		if plr and dist <= DETECTION_RADIUS and InViewAngle(plr) and LineOfSight(plr) then
			State = "Chase"
			return
		end
		task.wait(stepTime)
	end
	alertCooldownRemaining = 3 -- Time remaining for the alert state cooldown
end

--<< LOOPS
-- STATE CONTROLLER LOOP: controls state variable based off conditional statements.
task.spawn(function()  
	while true do -- Using closetplayer and tracks its movement and states and once player is out of reach it changes states depending on radius
		local plr, dist = GetClosestPlayer()
		if alertCooldownRemaining > 0 then
			alertCooldownRemaining -= 0.1 -- decreases cooldown by 0.1 everytime until it hits 0
		end
		if plr and alertCooldownRemaining <= 0 then -- if cooldown is not active and player is detected
			local canSee = InViewAngle(plr) and LineOfSight(plr) -- Checking if player is in vision system
			if dist <= DETECTION_RADIUS and canSee then -- If player is in vision and range
				State = "Chase" -- chase the player
				TargetPlayer = plr -- Set player to target
				ALERT_TRIES = 0 -- Resets alert tries
			elseif dist <= ALERT_RADIUS and State ~= "Chase" then -- If player is not in vision but still in alert radius
				State = "Alert" -- Alert the Enemy
			end
		end
		task.wait(0.01)
	end
end)
-- BEHAVIOUR EXECUTOR LOOP: Executes the correct function based on State.
task.spawn(function() 
	while true do -- Constantly checks for changing states and calls the corresponding function 
		if State == "Patrol" then -- If state is patrol it will patrol
			Patrol()
		elseif State == "Chase" then -- If state is chase it will chase the player giving it the target player as a parmeter
			Chase(TargetPlayer)
		elseif State == "Alert" then
			if ALERT_TRIES >= ALERT_COUNT then -- Did a cooldown on alert to naturally go and not stay stuck if the player stands still
				ALERT_TRIES = 0 -- Resets alert tries
				ALERT_RADIUS = 0 -- Temporary alerting radius off
				State = "Patrol" -- Goes back to patrol
				Patrol()
				ALERT_RADIUS = 40 -- Temporary alerting radius on
			else
				ALERT_TRIES += 1 -- ELSE Adds alert try
				Alert()
			end
		end
		task.wait(0.01)
	end
end)

