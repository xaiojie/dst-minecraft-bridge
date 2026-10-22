-- Throwaway two-game feasibility experiment. Enable only in a NEW local test world.
local G = GLOBAL
local json = G.require("json")
local ENDPOINT = "http://127.0.0.1:39379/exchange"
local session = "dst-probe-" .. G.tostring(G.math.random(10000000, 99999999))
local target, started, inflight, connected, sent_test = nil, false, false, false, false
local command_sequence = 0
local pending, applied, reports = {}, {}, {}

local function log(message)
    G.print("DST_MC_PROBE " .. message)
end

local function queue_tnt()
    if target == nil or not target:IsValid() then return end
    command_sequence = command_sequence + 1
    local x, _, z = target.Transform:GetWorldPosition()
    local command = { id = session .. ":" .. command_sequence, type = "tnt", x = x, z = z }
    pending = { command }
    log("requesting real MC TNT " .. json.encode(command))
end
G.DSTMCProbeTNT = queue_tnt

local function apply_events(state)
    if target == nil or not target:IsValid() then return end
    for _, event in G.ipairs(state.explosions or {}) do
        if not applied[event.id] then
            applied[event.id] = true
            local tx, _, tz = target.Transform:GetWorldPosition()
            local dx, dz = tx - event.dst_x, tz - event.dst_z
            if dx * dx + dz * dz <= 9 then
                local before = target.components.health.currenthealth
                target.components.health:DoDelta(-100, false, "minecraft_tnt")
                local after = target.components.health.currenthealth
                G.table.insert(reports, { event_id = event.id, before = before, after = after })
                local fx = G.SpawnPrefab("explode_small")
                if fx ~= nil then fx.Transform:SetPosition(tx, 0, tz) end
                log("REAL_MC_EXPLOSION_APPLIED " .. json.encode(reports[#reports]))
            end
        end
    end
end

local function exchange()
    if inflight or G.TheWorld == nil or not G.TheWorld.ismastersim then return end
    local player = G.AllPlayers ~= nil and G.AllPlayers[1] or nil
    if player == nil or not player:IsValid() then return end
    local x, _, z = player.Transform:GetWorldPosition()
    local body = {
        session = session, x = x, z = z, commands = pending,
        damage_reports = reports,
        target_health = target ~= nil and target:IsValid() and target.components.health.currenthealth or -1,
    }
    inflight = true
    G.TheSim:QueryServer(ENDPOINT, function(result, success, code)
        inflight = false
        if not success or code ~= 200 then
            if connected then log("connection lost; waiting for MC") end
            connected = false
            return
        end
        local ok, state = G.pcall(json.decode, result)
        if not ok or state == nil or not state.world_loaded then return end
        if not connected then log("connected to real Minecraft session=" .. G.tostring(state.session)) end
        connected = true
        apply_events(state)
        if not sent_test and state.anchored then
            sent_test = true
            queue_tnt()
        end
    end, "POST", json.encode(body))
end

AddPlayerPostInit(function(player)
    player:DoTaskInTime(3, function()
        if started or G.TheWorld == nil or not G.TheWorld.ismastersim then return end
        started = true
        local x, _, z = player.Transform:GetWorldPosition()
        target = G.SpawnPrefab("pigman")
        if target == nil then log("could not create disposable test target"); return end
        target.Transform:SetPosition(x + 6, 0, z)
        target:AddTag("dst_mc_probe_target")
        target.persists = false
        target.components.health:SetMaxHealth(1000)
        target.components.health:SetCurrentHealth(1000)
        if target.brain ~= nil then target.brain:Stop() end
        if target.components.locomotor ~= nil then target.components.locomotor:Stop() end
        target.AnimState:SetMultColour(0.4, 0.8, 1, 1)
        log("started temporary experiment; target at " .. (x + 6) .. "," .. z .. " hp=1000")
        G.TheWorld:DoPeriodicTask(0.2, exchange)
    end)
end)
