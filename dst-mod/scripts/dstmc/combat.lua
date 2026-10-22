local json=require('json')
local identity=require('components/dstmcidentity')
local transform=require('dstmc/transform')
local actors=require('dstmc/actors')
local M={};local session,storage_key;local ledger,results,outgoing={},{},{};local ready=false;local writing=false;local queue={};local generation=0
local hooked,oldmodifier,player_id,forwarding;local enabled=true
local function result(event,status,reason)return {id=event.id,status=status,reason=reason or ''}end
local function fingerprint(e)
    local p=e.position or {};return table.concat({e.type or '',e.epoch or '',e.target or '',e.source or '',tostring(e.amount),e.kind or '',tostring(p.x),tostring(p.y),tostring(p.z)},'|')
end
local function applyeffect(e)
    if e.type=='damage' then
        if e.source~='MC' or type(e.amount)~='number' or e.amount<=0 or e.amount>10000 then return 'REJECTED','invalid damage' end
        local target=actors.Find(e.target);if not target or not target.components.health or target.components.health:IsDead() then return 'REJECTED','target missing/dead' end
        -- MC hit detection has already checked a real body, projectile or explosion.
        forwarding=true
        local ok,err=pcall(function()if target.components.combat then target.components.combat:GetAttacked(ThePlayer,e.amount*10)else target.components.health:DoDelta(-e.amount*10,false,'mc_bridge',false,ThePlayer)end end)
        forwarding=false
        if not ok then return 'UNRESOLVED',tostring(err)end
        return 'APPLIED',''
    elseif e.type=='explosion' then
        -- Damage already comes from real MC explosion hits on proxies. This event
        -- supplies native effects/workable destruction only, avoiding double damage.
        local p=e.position;if not p or e.radius~=4 then return 'REJECTED','invalid explosion' end
        local fx=SpawnPrefab and SpawnPrefab('explosivepowder_explosion');if fx then fx.Transform:SetPosition(p.x,p.y,p.z)end
        if TheSim.FindEntities then for _,target in ipairs(TheSim:FindEntities(p.x,p.y,p.z,e.radius,nil,{'INLIMBO','FX','CLASSIFIED','dstmc_bridge'}))do
            if target~=ThePlayer and target.components.workable and target.components.workable:CanBeWorked() then target.components.workable:Destroy(ThePlayer)end
        end end
        return 'APPLIED',''
    end
    return 'REJECTED','unknown event'
end
local pump
pump=function()
    if not ready or writing or not session or #queue==0 then return end
    local e=table.remove(queue,1)
    local previous=ledger[e.id]
    if previous then
        if previous.fingerprint~=fingerprint(e)then results[e.id]=result(e,'REJECTED','event id reused')
        else results[e.id]=result(e,previous.status=='PENDING' and 'UNRESOLVED' or previous.status,previous.reason)end
        pump();return
    end
    local token=generation;writing=true
    local entry={fingerprint=fingerprint(e),epoch=e.epoch,status='PENDING'};ledger[e.id]=entry
    -- Receipt must be durable BEFORE side effects. Any crash leaves PENDING/UNRESOLVED.
    TheSim:SetPersistentString(storage_key,json.encode(ledger),false,function(saved)
        if token~=generation then return end
        if not saved then ledger[e.id]=nil;writing=false;results[e.id]=result(e,'REJECTED','ledger write failed');pump();return end
        local status,reason=applyeffect(e);entry.status=status;entry.reason=reason
        TheSim:SetPersistentString(storage_key,json.encode(ledger),false,function(committed)
            if token~=generation then return end
            if not committed then entry.status='UNRESOLVED';entry.reason='effect executed but commit failed; reconcile' end
            results[e.id]=result(e,entry.status,entry.reason);writing=false;pump()
        end)
    end)
end
function M.Release()
    generation=generation+1;ready=false;session=nil;queue={};writing=false
    if hooked and hooked.deltamodifierfn==M.Modifier then hooked.deltamodifierfn=oldmodifier end
    hooked=nil;oldmodifier=nil;player_id=nil
end
function M.Bind(s)
    M.Release();session=s;ledger,results,outgoing={},{},{};local token=generation
    storage_key='dstmc_damage_'..s.pair.dst_world..'_'..s.pair.mc_world..'_'..s.pair.dst_shard
    TheSim:GetPersistentString(storage_key,function(ok,data)
        if token~=generation then return end
        if ok and data and data~='' then local parsed,value=pcall(json.decode,data);if not parsed or type(value)~='table' then return end;ledger=value end
        for _,entry in pairs(ledger)do if entry.status=='PENDING'then entry.status='UNRESOLVED';entry.reason='restart before confirmation'end end
        ready=true;pump()
    end)
end
function M.Apply(e)
    if not transform.SameSession(session,e) then return false end
    local existing=ledger[e.id]
    if existing then
        if existing.fingerprint~=fingerprint(e)then results[e.id]=result(e,'REJECTED','event id reused')
        elseif existing.status~='PENDING'then results[e.id]=result(e,existing.status,existing.reason)end
        return true
    end
    for _,pending in ipairs(queue)do if pending.id==e.id then return true end end
    if #queue>=4096 then return false end
    queue[#queue+1]=e;pump();return true
end
function M.Results()local r={};for _,v in pairs(results)do r[#r+1]=v end;return r end
function M.AckResults(sent)for _,v in ipairs(sent or {})do results[v.id]=nil end end
function M.Outgoing()local r={};for _,v in pairs(outgoing)do r[#r+1]=v end;return r end
function M.Acknowledge(values)for _,v in ipairs(values or {})do if v.status~='PENDING'then outgoing[v.id]=nil end end end
function M.Modifier(inst,amount,overtime,cause,ignore,afflicter,absorb)
    if oldmodifier then amount=oldmodifier(inst,amount,overtime,cause,ignore,afflicter,absorb)end
    if session and enabled and player_id and not forwarding and amount<0 then
        -- Preserve native absorption and per-hit limits, but prevent the shadow
        -- player from independently dying before MC acknowledges the injury.
        if hooked.maxdamagetakenperhit then amount=math.max(amount,hooked.maxdamagetakenperhit)end
        local x,y,z=inst.Transform:GetWorldPosition()
        if afflicter and afflicter.Transform then local _,ay,_=afflicter.Transform:GetWorldPosition();if math.abs(y-ay)>3 and not afflicter:HasTag('projectile')then return 0 end end
        local id=identity.NewUUID();outgoing[id]={id=id,pair=session.pair,epoch=session.epoch,source='DST',target=player_id,position={x=x,y=y,z=z},amount=-amount,kind=cause or 'native'}
        return 0
    end
    return amount
end
function M.Player(player,owner)
    if not ThePlayer or not player then return end
    enabled=owner~='DST';player_id=player.id
    local health=ThePlayer.components.health;if not health then return end
    if hooked~=health then if hooked and hooked.deltamodifierfn==M.Modifier then hooked.deltamodifierfn=oldmodifier end;hooked=health;oldmodifier=health.deltamodifierfn;health.deltamodifierfn=M.Modifier end
    if enabled and player.max_health>0 then
        if player.alive and ThePlayer:HasTag('playerghost')then ThePlayer:PushEvent('respawnfromghost',{source=ThePlayer})end
        health:SetPercent(math.max(0,math.min(1,player.health/player.max_health)))
    end
end
return M
