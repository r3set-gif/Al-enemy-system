local Validate = game.ReplicatedStorage.Remotes.CallServer
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local ComboAttachs = {}

--- Combo Table stores the custom behaviour for each combo
local CustomBehaviour = {
    Combo1 = {
        HitBoxSizes = Vector3.new(5, 5, 5),
        VelocityStrength = 10,
        VFX = game.ReplicatedStorage.VFX.HitVFX.Attachment:Clone(),
        Sound = script["Hit Sound"],
        KnockBackAnim = script.Anims.Combo1KnockBack,
        HitLength = 4,
        Damage = 5,
        Attach = 2
    },
    Combo2 = {
        HitBoxSizes = Vector3.new(6, 6, 6),
        VelocityStrength = 20,
        VFX = game.ReplicatedStorage.VFX.HitVFX.Attachment:Clone(),
        Sound = script["Hit Sound"],
        KnockBackAnim = script.Anims.Combo2KnockBack,
        HitLength = 5,
        Damage = 7,
        Attach = 2
    },
    Combo3 = {
        HitBoxSizes = Vector3.new(9, 9, 9),
        VelocityStrength = 30,
        VFX = game.ReplicatedStorage.VFX["Full Impact"].Attachment:Clone(),
        Sound = script.SuperHit,
        KnockBackAnim = script.Anims.Combo3KnockBack,
        HitLength = 7,
        Damage = 10,
        Attach = 4
    }
}

local function AddVFX(model, Combo)
    local vfx = CustomBehaviour[Combo].VFX:Clone()
    vfx.Parent = model.HumanoidRootPart
    for _, c in ipairs(vfx:GetChildren()) do
        if c:IsA("ParticleEmitter") then
            c:Emit(10)
        end
    end
    return vfx
end

local function AddVelocity(model, char, Combo)
    local BV = Instance.new("BodyVelocity")
    BV.MaxForce = Vector3.new(5e4, 5e2, 5e4)
    BV.Velocity = (model.HumanoidRootPart.Position - char.HumanoidRootPart.Position).Unit
        * CustomBehaviour[Combo].VelocityStrength
    BV.Parent = model.HumanoidRootPart
    return BV
end

local function AddSound(model, Combo)
    local sound = CustomBehaviour[Combo].Sound:Clone()
    sound.Parent = model.HumanoidRootPart
    sound:Play()
    return sound
end

game.Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function(char)
        local humanoid = char:WaitForChild("Humanoid")
        local leftPart, rightPart

        if humanoid.RigType == Enum.HumanoidRigType.R6 then
            leftPart = char:WaitForChild("LeftArm")
            rightPart = char:WaitForChild("RightArm")
        else
            leftPart = char:WaitForChild("LeftHand")
            rightPart = char:WaitForChild("RightHand")
        end

        ComboAttachs[char] = {}

        for comboName, comboData in pairs(CustomBehaviour) do
            ComboAttachs[char][comboName] = { Left = {}, Right = {} }
            local total = comboData.Attach

            for j = 1, total do
                local offsetY = -0.065 * ((j - 1) - (total - 1) / 2)

                local leftAttach = Instance.new("Attachment")
                leftAttach.Name = comboName .. "Ray"
                leftAttach.Position = Vector3.new(-0.133, offsetY, 0.028)
                leftAttach.Parent = leftPart
                table.insert(ComboAttachs[char][comboName].Left, leftAttach)

                local rightAttach = Instance.new("Attachment")
                rightAttach.Name = comboName .. "Ray"
                rightAttach.Position = Vector3.new(0.112, offsetY, 0.028)
                rightAttach.Parent = rightPart
                table.insert(ComboAttachs[char][comboName].Right, rightAttach)
            end
        end
    end)
end)

Validate.OnServerEvent:Connect(function(player, Combo)
    local char = player.Character or player.CharacterAdded:Wait()
    if not char then return end

    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local BVP = Instance.new("BodyVelocity")
    BVP.MaxForce = Vector3.new(5e4, 5e2, 5e4)
    BVP.Velocity = char.HumanoidRootPart.CFrame.LookVector * CustomBehaviour[Combo].VelocityStrength
    BVP.Parent = char.HumanoidRootPart
    Debris:AddItem(BVP, 0.1)

    local hitboxActive = true
    local hitCache = {}
    local conn
    local lastCheck = 0

    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {char}
    params.FilterType = Enum.RaycastFilterType.Exclude

    conn = RunService.Heartbeat:Connect(function(dt)
        if not hitboxActive then return end

        lastCheck += dt
        if lastCheck < 0.03 then return end
        lastCheck = 0

        local set = ComboAttachs[char][Combo]

        for _, handTable in pairs(set) do
            for _, attach in ipairs(handTable) do
                local origin = attach.WorldPosition
                local direction = attach.WorldCFrame.LookVector * CustomBehaviour[Combo].HitLength

                local result = workspace:Raycast(origin, direction, params)
                if not result then continue end

                local hit = result.Instance
                local EnemyModel = hit:FindFirstAncestorOfClass("Model")
                if not EnemyModel or EnemyModel == char then continue end

                local Enemyhum = EnemyModel:FindFirstChildOfClass("Humanoid")
                if not Enemyhum or Enemyhum.Health <= 0 then continue end
                if hitCache[Enemyhum] then continue end
                hitCache[Enemyhum] = true

                local animator = Enemyhum:FindFirstChildOfClass("Animator")
                if not animator then
                    animator = Instance.new("Animator")
                    animator.Parent = Enemyhum
                end
                if not animator then continue end

                animator:LoadAnimation(CustomBehaviour[Combo].KnockBackAnim):Play()
                Enemyhum:TakeDamage(CustomBehaviour[Combo].Damage)
                Debris:AddItem(AddVFX(EnemyModel, Combo), 0.65)
                Debris:AddItem(AddSound(EnemyModel, Combo), 2)
                Debris:AddItem(AddVelocity(EnemyModel, char, Combo), 0.1)
            end
        end
    end)

    task.delay(0.65, function()
        hitboxActive = false
        hitCache = {}
        if conn then
            conn:Disconnect()
            conn = nil
        end
    end)
end)
