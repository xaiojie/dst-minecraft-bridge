local G=GLOBAL
AddPrefabPostInit("world",function(inst)
    if inst.ismastersim and not inst:HasTag("cave") and not G.TheNet:IsDedicated() then inst:AddComponent("dstmcidentity") end
end)
AddPlayerPostInit(function(player)
    player:DoTaskInTime(0,function()
        if player~=G.ThePlayer or not G.require("dstmc/world").LocalWorld() then return end
        local connection=G.require("dstmc/connection")
        connection.Start(GetModConfigData("connect"))
        G.rawset(G,"DSTMCFirstPersonCalibrate",function() return G.require("dstmc/camera").Calibrate() end)
        G.rawset(G,"DSTMCFirstPersonRelease",connection.Release)
        player:ListenForEvent("onremove",connection.Release)
        G.print("DSTMC_GATE_READY calibration available; connect="..G.tostring(GetModConfigData("connect")))
    end)
end)
