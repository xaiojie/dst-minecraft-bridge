local actors=require('dstmc/actors')
local terrain=require('dstmc/terrain')
local collision=require('dstmc/collision')
local combat=require('dstmc/combat')
local world=require('dstmc/world')
local transform=require('dstmc/transform')
local M={};local session,sequence,terrain_at=nil,0,-100;local owner='MC';local snapshot_ticket
function M.Bind(s)snapshot_ticket=nil;session=s;sequence=0;terrain_at=-100;owner='MC';world.Bind(s);collision.Bind(s);combat.Bind(s)end
function M.Release()session=nil;world.Release();collision.Clear();combat.Release()end
function M.Owner(value)owner=value or 'MC' end
function M.Sample()
    sequence=sequence+1;local now=GetTimeRealSeconds();local sampled
    if now-terrain_at>=.25 then sampled=terrain.Sample(session);terrain_at=now end
    return {snapshot_ticket=snapshot_ticket,sequence=sequence,block_revision=collision.Revision(),actors=actors.Sample(session),terrain=sampled,results=combat.Results(),input_owner=owner},combat.Outgoing()
end
function M.Accept(reply,sent)
    if not transform.SameSession(session,reply)then return false end
    snapshot_ticket=reply.snapshot_ticket
    if reply.blocks then collision.Apply(reply.blocks)end
    if reply.player then world.ApplyPlayer(reply.player,session.epoch,owner);combat.Player(reply.player,owner)end
    for _,event in ipairs(reply.events or {})do combat.Apply(event)end
    combat.Acknowledge(reply.results);combat.AckResults(sent.results);return true
end
function M.Update()world.Update()end
return M
