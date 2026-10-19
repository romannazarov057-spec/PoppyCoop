--[[
PoppyCoop — co-op skeleton for Poppy Playtime (UE 4.27, via UE4SS v3.0.1).

Goal of this slice (playbook "how co-op mods work", stage 2): a second,
player-shaped actor (the "puppet") that exists in the live world and whose
transform we can drive from code. No networking yet.

Why this looks unusual
----------------------
UE4SS's own UWorld::SpawnActor re-implementation crashes on this engine, and even
UGameplayStatics::BeginDeferredActorSpawnFromClass through its ProcessEvent hook
does (upstream issue UE4SS-RE/RE-UE4SS#527, still open in v3.0.1). The console
cheat `summon` is reported to spawn reliably, and it is the game's own code path,
so that is how the puppet is created. Once it exists we find it with FindFirstOf.

Stages, each independently testable:
  open  : jump from the main menu into Chapter 1 (console `open`)
  spawn : `summon` a SkeletalMeshActor and pick it up
  dress : give the puppet the player's skeletal mesh + anim class
  drive : move the puppet in a local orbit

Console commands in the UE4SS GUI console:
  coop_status / coop_open / coop_spawn / coop_despawn / coop_debug
]]

if Print == nil then Print = print end

local UEHelpers = require("UEHelpers")

local CONFIG = {
    autoOpenMap = true,      -- jump into Chapter 1 from the menu
    autoSpawnPuppet = true,  -- summon + adopt the puppet once in gameplay
    autoDressPuppet = true,  -- copy the player's mesh/anim onto the puppet
    copyAnim = false,        -- copy the player's AnimBP too (crashes on a bare actor)
    copyMaterials = false,   -- copy the player's materials (crashes: see NOTES.md)
    puppetAnim = "legs_Walk_anim", -- sequence to play on the puppet once dressed; "" = stay still
    autoDrivePuppet = true,  -- move the puppet in a local orbit
    openDelayTicks = 20,     -- 500 ms/tick -> ~10 s in the menu before `open`
    spawnDelayTicks = 20,    -- ~10 s in gameplay before summoning (let streaming settle)
    summonClass = "/Script/Engine.SkeletalMeshActor",
    summonTimeoutTicks = 20, -- give up adopting a summoned actor after ~10 s
    driveStartTicks = 0,     -- start driving immediately after dressing

    -- Transport seam. "file" is a stand-in for the local automated test: the mod
    -- writes its own avatar state to <netDir>\<playerId>.state and drives the
    -- puppet to whatever <netDir>\<peerId>.state holds. The real transport
    -- (Steam/Spacewar via a helper, per playbook/networking-steam-spacewar.md)
    -- plugs in behind this: relay/cooprelay.py moves those two files across.
    transport = "file",
    netDir = "D:\\coop-work\\poppy-playtime\\net",
    driveMode = "peer",      -- "peer" = follow peer.state, else "orbit"/"pose" = local demo
    playerId = "A",          -- overridden by playerid.txt in the game's working dir
    poseDistance = 350.0,    -- "pose" mode: how far in front of the player to park the puppet
}

local CHAPTER1_MAP = "/Game/Levels/PP_FinalLevel"

local coop = {
    tick = 0,
    openTried = false,
    gameplayTicks = 0,
    lastPawnName = nil,
    lastWorld = nil,
    puppet = nil,
    summonState = nil,   -- nil | "pending" | "done"
    summonTick = -999,
    summonTries = 0,
    summonBefore = nil,  -- set of puppet-class full names seen before summoning
    puppetTicks = 0,     -- ticks since the puppet was adopted
}

local function log(fmt, ...)
    print(string.format("[PoppyCoop] " .. fmt .. "\n", ...))
end

local function safe(label, fn)
    local ok, a, b = pcall(fn)
    if not ok then
        -- Must not raise by itself: use print, not log.
        print(string.format("[PoppyCoop] %s ERROR: %s\n", tostring(label), tostring(a)))
        return nil
    end
    return a, b
end

local function nameOf(obj)
    if obj == nil then return "nil" end
    return safe("nameOf", function() return obj:GetFullName() end) or "<invalid>"
end

local function isValid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- An FName arrives in Lua as a userdata whose __tostring prints "<class>: <address>",
-- which is useless for reading bone names. The text is behind :ToString(); fall back to
-- the address form rather than raising, so a build without that method still logs.
local function fnameText(obj)
    if obj == nil then return "nil" end
    local ok, s = pcall(function() return obj:ToString() end)
    if ok and type(s) == "string" and s ~= "" then return s end
    return tostring(obj)
end

local function fmtVec(v)
    if v == nil then return "?" end
    local ok, s = pcall(string.format, "%.2f %.2f %.2f", v.X, v.Y, v.Z)
    return ok and s or "?"
end

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

-- Which player this process is. playerid.txt in the working directory (the game's
-- Win64 folder) wins, so two copies of the game can run side by side.
coop.id = (function()
    local id = nil
    safe("readId", function()
        local f = io.open("playerid.txt", "r")
        if f then id = f:read("*l"); f:close() end
    end)
    id = id and id:match("^%s*(%w+)%s*$")
    return id or CONFIG.playerId
end)()

-- Where this instance's transport files live. deploy.ps1 can pin it per copy with
-- netdir.txt; otherwise the shared CONFIG.netDir is used (plain file transport).
CONFIG.netDir = (function()
    local d = nil
    safe("readNetDir", function()
        local f = io.open("netdir.txt", "r")
        if f then d = f:read("*l"); f:close() end
    end)
    d = d and d:match("^%s*(.-)%s*$")
    if d and d ~= "" then return d end
    return CONFIG.netDir
end)()

-- Lookups that never raise (UEHelpers getters call error() while a level streams).
local function getWorld() return FindFirstOf("World") end
local function getPlayerController() return FindFirstOf("PlayerController") end

local function getPlayerPawn()
    local pc = getPlayerController()
    if not isValid(pc) then return nil end
    local pawn = safe("pawn", function() return pc.Pawn end)
    return isValid(pawn) and pawn or nil
end

local function classHas(obj, needle)
    local n = nameOf(safe("class", function() return obj:GetClass() end))
    return string.find(n, needle, 1, true) ~= nil
end

local function consoleCommand(cmd)
    local ksl = safe("GetKismetSystemLibrary", function() return UEHelpers.GetKismetSystemLibrary() end)
    if not isValid(ksl) then
        log("console: KismetSystemLibrary not available")
        return false
    end
    local ctx = getPlayerController() or getWorld()
    safe("ExecuteConsoleCommand", function() return ksl:ExecuteConsoleCommand(ctx, cmd, nil) end)
    return true
end

local function openChapter1()
    if coop.openTried then return end
    coop.openTried = true
    log("open: asking the game to load %s", CHAPTER1_MAP)
    ExecuteInGameThread(function()
        consoleCommand("open " .. CHAPTER1_MAP)
        log("console: sent 'open %s'", CHAPTER1_MAP)
    end)
end

local function puppetClassName()
    -- "SkeletalMeshActor" from "/Script/Engine.SkeletalMeshActor"
    return CONFIG.summonClass:match("([^%.]+)$") or CONFIG.summonClass
end

local function snapshotPuppetNames()
    local set = {}
    safe("snapshot", function()
        local all = FindAllOf(puppetClassName())
        if all then
            for _, a in ipairs(all) do set[nameOf(a)] = true end
        end
    end)
    return set
end

local function findNewPuppet()
    local found = nil
    safe("findNew", function()
        local all = FindAllOf(puppetClassName())
        if all then
            for _, a in ipairs(all) do
                if isValid(a) and not (coop.summonBefore or {})[nameOf(a)] then
                    found = a
                    break
                end
            end
        end
    end)
    return found
end

-- Declared here, defined further down: dressing the puppet also gives it its walk
-- animation, and the two are in different sections of this file.
local applyPuppetAnim

local function dressPuppet(puppet, pawn)
    local playerMesh = safe("playerMesh", function() return pawn.Mesh end)
    local puppetComp = safe("puppetComp", function() return puppet.SkeletalMeshComponent end)
    if not (isValid(playerMesh) and isValid(puppetComp)) then
        log("dress: no mesh to copy (playerMesh=%s puppetComp=%s)", nameOf(playerMesh), nameOf(puppetComp))
        return
    end

    local skAsset = safe("skAsset", function() return playerMesh.SkeletalMesh end)

    -- There is no SetAnimInstanceClass in this build; AnimClass is a plain property.
    -- NOTE: the player's AnimBP dereferences its owning pawn, so assigning it to a
    -- bare SkeletalMeshActor makes it crash (null owner). Off by default.
    local animClass = safe("animClass", function() return playerMesh.AnimClass end)

    -- Read the player's materials here (a TArray property read), apply them below.
    local mats = nil
    if CONFIG.copyMaterials then
        mats = safe("materials", function() return playerMesh:GetMaterials() end)
    end

    -- The pawn's mesh carries a scale of its own (14.37 on this build); a summoned actor
    -- starts at 1. Without this the puppet is dressed correctly and renders at a
    -- fourteenth of the player's size, which reads as "the puppet is not there at all".
    local scale = safe("playerScale", function() return playerMesh:K2_GetComponentScale() end)

    -- Every mutation of the puppet's component runs on the game thread. Animation is
    -- evaluated there, and a call from the mod's own thread races it: that race is
    -- what faulted the game with a null read (+0x10) straight after the walk sequence
    -- was applied off-thread. The summon console command already goes this way.
    ExecuteInGameThread(function()
        safe("setMesh", function() puppetComp:SetSkeletalMesh(skAsset, true) end)
        if scale then
            safe("setScale", function() puppet:SetActorScale3D(vec(scale.X, scale.Y, scale.Z)) end)
        end
        if CONFIG.copyAnim then
            safe("setAnim", function() puppetComp.AnimClass = animClass end)
        end
        if mats then
            local copied = 0
            for i = 1, #mats do
                local m = mats[i]
                if m then
                    safe("setMat", function() puppetComp:SetMaterial(i - 1, m) end)
                    copied = copied + 1
                end
            end
            log("dress: materials copied = %d", copied)
        end
    end)

    log("dress: mesh=%s anim=%s scale=%s",
        nameOf(skAsset), nameOf(animClass), fmtVec(scale))

    -- The player's AnimBP can never go on the puppet (it casts to PlayerBP_C and reads
    -- the owning pawn). A plain sequence on the same skeleton can, and legs alone is
    -- what the rig actually is, so the puppet gets that instead of standing frozen.
    if CONFIG.puppetAnim ~= "" then
        applyPuppetAnim(CONFIG.puppetAnim)
    end
end

-- ---------------------------------------------------------------------------
-- Appearance: materials and animation.
--
-- The player's rig is animated by Plegs_rig_AnimBP, which does a dynamic cast to
-- PlayerBP_C and reads the owning pawn (velocity, location). On a bare
-- SkeletalMeshActor that cast lands on nothing and the graph faults, which is why
-- copying AnimClass is off by default. The rig does ship a plain walk sequence
-- (/Game/Player/Rig/Anim/legs_Walk_anim), so single-node animation can give the
-- puppet a believable pose without the AnimBP.
--
-- Everything here is reachable from console commands so each attempt can be tried
-- and observed in one run instead of one code change per run.
-- ---------------------------------------------------------------------------

local ANIM_SINGLE_NODE = 1   -- EAnimationMode::AnimationSingleNode

local function puppetComp()
    return safe("puppetComp", function()
        if not isValid(coop.puppet) then return nil end
        return coop.puppet.SkeletalMeshComponent
    end)
end

local function playerComp()
    local pawn = getPlayerPawn()
    return safe("playerComp", function()
        if not isValid(pawn) then return nil end
        return pawn.Mesh
    end)
end

local function findAnimSequence(part)
    local found = nil
    safe("findSeq", function()
        local all = FindAllOf("AnimSequence")
        if all then
            for _, a in ipairs(all) do
                if isValid(a) and string.find(nameOf(a), part, 1, true) then
                    found = a
                    break
                end
            end
        end
    end)
    return found
end

-- What a component would actually draw: per-slot GetMaterial resolves the
-- component's override if there is one, else the mesh asset's own material.
local function describeComp(tag, comp)
    if not isValid(comp) then
        log("diag[%s]: no component", tag)
        return
    end
    local mesh = safe("mesh", function() return comp.SkeletalMesh end)
    local inst = safe("animInst", function() return comp:GetAnimInstance() end)
    local cls = safe("animClass", function() return comp.AnimClass end)
    local n = safe("numMat", function() return comp:GetNumMaterials() end) or 0
    log("diag[%s]: mesh=%s slots=%d animInstance=%s animClass=%s",
        tag, nameOf(mesh), n, nameOf(inst), nameOf(cls))
    for i = 0, n - 1 do
        local m = safe("mat", function() return comp:GetMaterial(i) end)
        log("diag[%s]: slot %d = %s", tag, i, nameOf(m))
    end
end

local function diagPuppet()
    log("diag: puppet=%s", nameOf(coop.puppet))
    describeComp("player", playerComp())
    describeComp("puppet", puppetComp())
    -- How big the puppet is and how far away it sits. The rig's reference pose spans a
    -- few units, so an unscaled summoned actor parked CONFIG.poseDistance away can end
    -- up a couple of pixels wide, which is worth measuring before assuming the pose is
    -- invisible for another reason.
    local pawn = getPlayerPawn()
    if isValid(pawn) and isValid(coop.puppet) then
        local d = safe("dist", function() return pawn:GetDistanceTo(coop.puppet) end)
        log("diag: distance player->puppet = %s", d and string.format("%.1f", d) or "?")
    end

    -- The summoned actor's own scale is 1, while the pawn's mesh may be scaled by its
    -- Blueprint. Same mesh, same material, different size on screen: this is the number
    -- that says whether the puppet renders at the player's size at all.
    local pc, uc = playerComp(), puppetComp()
    if isValid(pc) then
        log("diag[player]: scale=%s refBone0=%s",
            fmtVec(safe("pscale", function() return pc:K2_GetComponentScale() end)),
            fmtVec(safe("pref", function() return pc:GetRefPosePosition(0) end)))
    end
    if isValid(uc) then
        log("diag[puppet]: scale=%s refBone0=%s",
            fmtVec(safe("uscale", function() return uc:K2_GetComponentScale() end)),
            fmtVec(safe("uref", function() return uc:GetRefPosePosition(0) end)))
    end

    -- Was the mesh actually submitted for drawing in the last half second? This is the
    -- one question a screenshot cannot answer for me: it separates "the puppet is
    -- dressed right but frustum-culled / zero-sized" from "the puppet is on screen".
    log("diag: rendered recently player=%s puppet=%s (component) playerActor=%s puppetActor=%s",
        tostring(safe("prr", function() return pc:WasRecentlyRendered(0.5) end)),
        tostring(safe("urr", function() return uc:WasRecentlyRendered(0.5) end)),
        tostring(safe("par", function() return pawn:WasRecentlyRendered(0.5) end)),
        tostring(safe("uar", function() return coop.puppet:WasRecentlyRendered(0.5) end)))
end

-- Is the puppet's animation actually advancing? "An anim instance is attached" is not
-- the same as "it is playing": the position readout is what moves, and only that shows
-- a pose is going to change from one frame to the next.
local function animStatus(tag, comp)
    if not isValid(comp) then
        log("animstat[%s]: no component", tag)
        return
    end
    local mode = safe("mode", function() return comp:GetAnimationMode() end)
    local playing = safe("playing", function() return comp:IsPlaying() end)
    local pos = safe("pos", function() return comp:GetPosition() end)
    local rate = safe("rate", function() return comp:GetPlayRate() end)
    log("animstat[%s]: mode=%s playing=%s pos=%s rate=%s",
        tag, tostring(mode), tostring(playing), tostring(pos), tostring(rate))
end

local function listBones()
    local comp = puppetComp()
    if not isValid(comp) then log("bones: no puppet component"); return end
    local n = safe("numBones", function() return comp:GetNumBones() end) or 0
    log("bones: %d total", n)
    for i = 0, math.min(n, 30) - 1 do
        local b = safe("bone", function() return comp:GetBoneName(i) end)
        local ref = safe("refPose", function() return comp:GetRefPosePosition(i) end)
        local refText = ""
        if ref then
            refText = string.format(" ref=(%.1f %.1f %.1f)", ref.X, ref.Y, ref.Z)
        end
        log("bones: %d = %s%s", i, fnameText(b), refText)
    end
end

applyPuppetAnim = function(part)
    local comp = puppetComp()
    if not isValid(comp) then log("anim: no puppet component"); return end
    local seq = findAnimSequence(part)
    log("anim: lookup '%s' -> %s", part, nameOf(seq))
    if not isValid(seq) then return end
    -- Same rule as dressing: animation is evaluated on the game thread, so the switch
    -- goes through it too. Called from dress at spawn time or from cmd.txt later; both
    -- run on the mod's own thread.
    ExecuteInGameThread(function()
        safe("animMode", function() comp:SetAnimationMode(ANIM_SINGLE_NODE) end)
        safe("animSet", function() comp:SetAnimation(seq) end)
        safe("animPlay", function() comp:Play(true) end)
        local inst = safe("animCheck", function() return comp:GetAnimInstance() end)
        log("anim: playing %s, animInstance now %s", nameOf(seq), nameOf(inst))
        animStatus("puppet", comp)
    end)
end

-- Reading a single bone's world position is a dead end on this build.
--
-- USkeletalMeshComponent here has no GetBoneLocationByName (that one belongs to
-- UPoseableMeshComponent, and calling it raises "function not found"). The general
-- path is USceneComponent::GetSocketLocation, which a skeletal mesh resolves for bone
-- names - but calling it froze the mod's thread on every attempt: once straight from
-- the tick loop, and once queued with ExecuteInGameThread, which stopped the loop just
-- the same (A.state stopped ticking, nothing logged, no error anywhere, process alive
-- and responsive). GetRefPosePosition(index) does answer, but it is the *reference*
-- pose: it returns identical numbers for the animated player and the puppet, so it
-- says nothing about movement. And reading the USkeletalMeshComponent property
-- CachedBoneSpaceTransforms[index].Translation - a property read rather than a call -
-- comes back as -nan / 2.8e37, i.e. the wrong bytes, so that route is out too.
--
-- So a pose is proven to move by the animation's own clock instead: see animStatus().
-- It reports the single node instance's position, which only advances because the
-- animation pass re-evaluates the pose every frame.

-- The risky experiment, kept opt-in: put the player's own (dynamic) materials on the
-- puppet. Logged slot by slot so a crash can be pinned to a slot.
local function copyMaterials()
    local src, dst = playerComp(), puppetComp()
    if not (isValid(src) and isValid(dst)) then
        log("mats: need both components (src=%s dst=%s)", nameOf(src), nameOf(dst))
        return
    end
    local n = safe("numMat", function() return src:GetNumMaterials() end) or 0
    log("mats: player slots=%d", n)
    for i = 0, n - 1 do
        local m = safe("getMat", function() return src:GetMaterial(i) end)
        if isValid(m) then
            local ok = safe("setMat", function() dst:SetMaterial(i, m); return true end)
            log("mats: slot %d <- %s ok=%s", i, nameOf(m), tostring(ok))
        else
            log("mats: slot %d empty on the player", i)
        end
    end
end

local function adoptPuppet(puppet, pawn)
    coop.puppet = puppet
    coop.summonState = "done"
    coop.puppetTicks = 0
    log("spawn: adopted puppet = %s", nameOf(puppet))

    safe("noCollision", function() puppet:SetActorEnableCollision(false) end)

    local ploc = safe("playerLoc", function() return pawn:K2_GetActorLocation() end)
    if ploc then
        ExecuteInGameThread(function()
            safe("place", function()
                -- FHitResult is an out param: nil makes UE4SS fault, pass a table.
                return puppet:K2_SetActorLocation(vec(ploc.X + 200, ploc.Y, ploc.Z), false, {}, false)
            end)
        end)
    end

    if CONFIG.autoDressPuppet then dressPuppet(puppet, pawn) end
end

local function despawnPuppet()
    if not isValid(coop.puppet) then
        coop.puppet = nil
        return false
    end
    local p = coop.puppet
    coop.puppet = nil
    coop.summonState = nil
    ExecuteInGameThread(function() safe("destroy", function() p:K2_DestroyActor() end) end)
    log("despawn: puppet destroyed")
    return true
end

local function summonStep(pawn)
    -- state machine: send the summon, then look for the new actor a couple of ticks later
    if coop.summonState == nil then
        coop.summonTries = coop.summonTries + 1
        coop.summonBefore = snapshotPuppetNames()
        coop.summonState = "pending"
        coop.summonTick = coop.tick
        local n = 0
        for _ in pairs(coop.summonBefore) do n = n + 1 end
        log("spawn: summon %s (try %d, existing=%d)", puppetClassName(), coop.summonTries, n)
        ExecuteInGameThread(function()
            consoleCommand("summon " .. CONFIG.summonClass)
        end)
        return
    end

    if coop.summonState == "pending" and (coop.tick - coop.summonTick) >= 4 then
        local puppet = findNewPuppet()
        if isValid(puppet) then
            adoptPuppet(puppet, pawn)
        elseif (coop.tick - coop.summonTick) >= CONFIG.summonTimeoutTicks then
            log("spawn: summon produced no actor within %d ticks, retrying", CONFIG.summonTimeoutTicks)
            coop.summonState = nil
        end
    end
end

-- Transport seam, "file" backend. Plain io so it works with UE4SS's Lua; the paths
-- are ASCII on purpose (Lua's io.open uses the ANSI code page on Windows).
local function netPath(name) return CONFIG.netDir .. "\\" .. name end
-- Two players for now: this process is A or B, and reads the other one's file.
local function peerId() return (coop.id == "A") and "B" or "A" end
local function selfStatePath() return netPath(coop.id .. ".state") end
local function peerStatePath() return netPath(peerId() .. ".state") end

local function writeSelfState(pawn)
    local loc = safe("selfLoc", function() return pawn:K2_GetActorLocation() end)
    local rot = safe("selfRot", function() return pawn:K2_GetActorRotation() end)
    if not loc then return end
    safe("writeSelf", function()
        local f = io.open(selfStatePath(), "w")
        if not f then return end
        f:write(string.format("%.2f %.2f %.2f %.2f\n",
            loc.X, loc.Y, loc.Z, rot and rot.Yaw or 0))
        f:close()
    end)
end

local function readPeerState()
    local text = nil
    safe("readPeer", function()
        local f = io.open(peerStatePath(), "r")
        if f then
            text = f:read("*a")
            f:close()
        end
    end)
    if not text then return nil end
    local xs, ys, zs, ys2 = text:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s*(%-?%d+%.?%d*)")
    if not xs then return nil end
    return vec(tonumber(xs), tonumber(ys), tonumber(zs)), tonumber(ys2) or 0
end

-- Automated input channel for tests (and, later, a debug console): the file
-- <netDir>\cmd.txt holds commands, one per line, and is consumed on read.
--   pawnloc X Y Z   teleport the local player pawn (proves movement propagates)
--   puppetloc X Y Z teleport the puppet (used to prove it is on screen at all)
--   pupperscale S    scale the puppet uniformly (the summoned actor has no scale of its own)
--   drive <mode>    set the drive mode (pose, orbit, peer)
--   diag            dump player and puppet mesh/material/animation state
--   anim <part>     play an animation sequence (substring of its path) on the puppet
--   animstat        print the puppet's animation clock and keep printing it every second
--   animpose <t>    freeze the walk at time t in its cycle (see the note before animStatus)
--   animplay        start the walk again
--   animoff         stop the puppet's animation
--   mats            copy the player's live materials onto the puppet (opt-in, risky)
--   console <text>  run a console command
local function pollCommands(pawn)
    local text = nil
    safe("cmdRead", function()
        local f = io.open(netPath("cmd.txt"), "r")
        if f then text = f:read("*a"); f:close() end
    end)
    if not text or text == "" then return end
    safe("cmdDelete", function() os.remove(netPath("cmd.txt")) end)
    for line in text:gmatch("[^\r\n]+") do
        local cmd, rest = line:match("^(%S+)%s*(.*)$")
        if cmd == "pawnloc" then
            local x, y, z = rest:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)")
            if x then
                local ok = safe("cmdPawnLoc", function()
                    return pawn:K2_SetActorLocation(vec(tonumber(x), tonumber(y), tonumber(z)), false, {}, false)
                end)
                log("cmd: pawnloc %s %s %s -> %s", x, y, z, tostring(ok))
            else
                log("cmd: bad pawnloc '%s'", rest)
            end
        elseif cmd == "console" and rest ~= "" then
            consoleCommand(rest)
            log("cmd: console '%s'", rest)
        elseif cmd == "puppetloc" and rest ~= "" then
            local x, y, z = rest:match("(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)")
            local p = coop.puppet
            if x then
                ExecuteInGameThread(function()
                    local ok = safe("puppetloc", function()
                        return p:K2_SetActorLocation(vec(tonumber(x), tonumber(y), tonumber(z)), false, {}, false)
                    end)
                    log("cmd: puppetloc %s %s %s -> %s", x, y, z, tostring(ok))
                end)
            else
                log("cmd: bad puppetloc '%s'", rest)
            end
        elseif cmd == "drive" and rest ~= "" then
            CONFIG.driveMode = rest
            log("cmd: drive mode = %s", rest)
        elseif cmd == "pupperscale" and rest ~= "" then
            local s = tonumber(rest)
            if s then
                local p = coop.puppet
                ExecuteInGameThread(function()
                    local ok = safe("pupperscale", function()
                        p:SetActorScale3D(vec(s, s, s))
                        return true
                    end)
                    log("cmd: pupperscale %.2f -> %s", s, tostring(ok))
                end)
            else
                log("cmd: bad pupperscale '%s'", rest)
            end
        elseif cmd == "diag" then
            diagPuppet()
        elseif cmd == "bones" then
            listBones()
        elseif cmd == "anim" and rest ~= "" then
            applyPuppetAnim(rest)
        elseif cmd == "animstat" then
            coop.animWatch = true
            animStatus("puppet", puppetComp())
        elseif cmd == "animoff" then
            coop.animWatch = nil
            local comp = puppetComp()
            ExecuteInGameThread(function() safe("animStop", function() comp:Stop() end) end)
            log("cmd: animation stopped")
        elseif cmd == "animpose" and rest ~= "" then
            -- Freeze the walk at a given time in its cycle. Two captures taken at two
            -- different times are the cleanest proof the sequence actually poses the
            -- legs differently: same camera, same world, only the animation differs.
            local t = tonumber(rest)
            local comp = puppetComp()
            if t then
                coop.animWatch = nil
                ExecuteInGameThread(function()
                    local inst = safe("animInst", function() return comp:GetAnimInstance() end)
                    local len = safe("animLen", function() return inst:GetLength() end)
                    safe("animStop", function() comp:Stop() end)
                    safe("animPose", function() inst:SetPosition(t, false) end)
                    log("cmd: animpose %.3f (length=%s)", t, tostring(len))
                end)
            else
                log("cmd: bad animpose '%s'", rest)
            end
        elseif cmd == "animplay" then
            applyPuppetAnim(CONFIG.puppetAnim)
        elseif cmd == "mats" then
            copyMaterials()
        end
    end
end

local function drivePuppet(pawn)
    local puppet = coop.puppet
    if not isValid(puppet) or not isValid(pawn) then return end

    if CONFIG.driveMode == "peer" then
        local target, yaw = readPeerState()
        if target then
            ExecuteInGameThread(function()
                local moved = safe("setLoc", function() return puppet:K2_SetActorLocation(target, false, {}, false) end)
                safe("setRot", function() puppet:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false) end)
                if coop.tick % 8 == 0 then
                    local here = safe("puppetLoc", function() return puppet:K2_GetActorLocation() end)
                    log("net: %s sees peer %s at %.0f %.0f %.0f -> puppet=%s moved=%s",
                        coop.id, peerId(), target.X, target.Y, target.Z,
                        here and string.format("%.0f %.0f %.0f", here.X, here.Y, here.Z) or "?", tostring(moved))
                end
            end)
            return
        end
        -- no peer yet: fall through to the orbit demo
    end

    if CONFIG.driveMode == "pose" then
        -- Park the puppet in front of the player and face it back at them, so a
        -- screenshot shows what the puppet actually looks like. Everything that touches
        -- the puppet happens on the game thread: driving it straight from the mod's own
        -- thread is what killed the game after a few minutes of orbit, with no crash
        -- report and no error in the log.
        ExecuteInGameThread(function()
            local ploc = safe("playerLoc", function() return pawn:K2_GetActorLocation() end)
            local fwd = safe("forward", function() return pawn:GetActorForwardVector() end)
            if not (ploc and fwd) then return end
            local tx = ploc.X + fwd.X * CONFIG.poseDistance
            local ty = ploc.Y + fwd.Y * CONFIG.poseDistance
            local tz = ploc.Z
            local moved = safe("setLoc", function()
                return puppet:K2_SetActorLocation(vec(tx, ty, tz), false, {}, false) end)
            local yaw = math.deg(math.atan(ploc.Y - ty, ploc.X - tx))
            safe("setRot", function() puppet:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false) end)
            if coop.tick % 8 == 0 then
                local here = safe("puppetLoc", function() return puppet:K2_GetActorLocation() end)
                log("pose: target=%.0f %.0f %.0f actual=%s moved=%s", tx, ty, tz,
                    here and string.format("%.0f %.0f %.0f", here.X, here.Y, here.Z) or "?", tostring(moved))
            end
        end)
        return
    end

    ExecuteInGameThread(function()
        local ploc = safe("playerLoc", function() return pawn:K2_GetActorLocation() end)
        if not ploc then return end

        local t = coop.tick * 0.5
        local radius, ang = 250.0, t * 0.9
        local target = vec(ploc.X + math.cos(ang) * radius, ploc.Y + math.sin(ang) * radius, ploc.Z)

        local moved = safe("setLoc", function() return puppet:K2_SetActorLocation(target, false, {}, false) end)
        local yaw = math.deg(math.atan(ploc.Y - target.Y, ploc.X - target.X))
        safe("setRot", function() puppet:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false) end)

        if coop.tick % 4 == 0 then
            local here = safe("puppetLoc", function() return puppet:K2_GetActorLocation() end)
            log("drive: target=%.0f %.0f %.0f actual=%s moved=%s", target.X, target.Y, target.Z,
                here and string.format("%.0f %.0f %.0f", here.X, here.Y, here.Z) or "?", tostring(moved))
        end
    end)
end

local function status()
    log("status: world=%s player=%s puppet=%s tick=%d tries=%d summonState=%s",
        nameOf(getWorld()), nameOf(getPlayerPawn()), nameOf(coop.puppet),
        coop.tick, coop.summonTries, tostring(coop.summonState))
end

local function debugCounts()
    safe("debug", function()
        local all = FindAllOf(puppetClassName())
        log("debug: %s count=%d", puppetClassName(), all and #all or -1)
    end)
end

RegisterConsoleCommandHandler("coop_status", function() status() end)
RegisterConsoleCommandHandler("coop_open", function() ExecuteInGameThread(openChapter1) end)
RegisterConsoleCommandHandler("coop_spawn", function() coop.summonState = nil end)
RegisterConsoleCommandHandler("coop_despawn", function() despawnPuppet() end)
RegisterConsoleCommandHandler("coop_debug", function() debugCounts() end)
RegisterConsoleCommandHandler("coop_diag", function() diagPuppet() end)
RegisterConsoleCommandHandler("coop_bones", function() listBones() end)

local function tick()
    coop.tick = coop.tick + 1

    local world = getWorld()
    if not isValid(world) then return end
    local worldName = nameOf(world)
    if worldName ~= coop.lastWorld then
        coop.lastWorld = worldName
        log("world = %s", worldName)
    end

    if string.find(worldName, "MainMenu", 1, true) then
        if CONFIG.autoOpenMap and not coop.openTried and coop.tick >= CONFIG.openDelayTicks then
            openChapter1()
        end
        return
    end

    local pawn = getPlayerPawn()
    if not isValid(pawn) then return end

    coop.gameplayTicks = coop.gameplayTicks + 1

    local pawnName = nameOf(pawn)
    if pawnName ~= coop.lastPawnName then
        coop.lastPawnName = pawnName
        log("playing: pawn=%s", pawnName)
        log("net: id=%s transport=%s dir=%s driveMode=%s", coop.id, CONFIG.transport, CONFIG.netDir, CONFIG.driveMode)
    end

    if CONFIG.transport == "file" then
        writeSelfState(pawn)
        pollCommands(pawn)
    end

    if isValid(coop.puppet) then
        coop.puppetTicks = coop.puppetTicks + 1
        if CONFIG.autoDrivePuppet and coop.puppetTicks >= CONFIG.driveStartTicks then
            if coop.puppetTicks == CONFIG.driveStartTicks then
                log("drive: starting after %.1f s parked", coop.puppetTicks * 0.5)
            end
            drivePuppet(pawn)
        end
        if coop.animWatch and coop.tick % 2 == 0 then
            animStatus("puppet", puppetComp())
        end
        return
    end

    if not CONFIG.autoSpawnPuppet then return end
    if coop.gameplayTicks < CONFIG.spawnDelayTicks then return end

    summonStep(pawn)
end

log("init PoppyCoop (open=%s spawn=%s dress=%s drive=%s)",
    tostring(CONFIG.autoOpenMap), tostring(CONFIG.autoSpawnPuppet),
    tostring(CONFIG.autoDressPuppet), tostring(CONFIG.autoDrivePuppet))
LoopAsync(500, function()
    safe("tick", tick)
    return false
end)
