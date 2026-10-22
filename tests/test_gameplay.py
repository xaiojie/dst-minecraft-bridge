"""Behavioral Lua contracts with only game-engine boundaries replaced by fixtures."""
import pathlib
import unittest
from lupa import LuaRuntime
ROOT=pathlib.Path(__file__).resolve().parents[1]
class GameplayTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('package.path=... .. "/dst-mod/scripts/?.lua;" .. package.path',str(ROOT))
        self.lua.execute('''
          clock=1; function GetTimeRealSeconds()return clock end
          function Class(fn)local c={};c.__index=c;return setmetatable(c,{__call=function(_,...)local o=setmetatable({},c);fn(o,...);return o end})end
          TheShard={GetShardId=function()return 'Master'end}
          created={};walls={};COLLISION={OBSTACLES=1,CHARACTERS=2,GIANTS=4,ITEMS=8,FLYERS=16}
          TheWorld={Pathfinder={AddWall=function(_,x,y,z)walls[x..':'..z]=true end,RemoveWall=function(_,x,y,z)walls[x..':'..z]=nil end}}
          function CreateEntity()
            local e={entity={},Transform={},Physics={},components={},valid=true};e.entity.AddTransform=function()end;e.entity.AddPhysics=function()return e.Physics end
            e.AddTag=function()end;e.Transform.SetPosition=function(_,x,y,z)e.pos={x=x,y=y,z=z}end
            e.Physics.SetTriangleMesh=function(_,v)e.mesh=v end;e.Physics.SetActive=function(_,v)e.active=v end
            for _,n in ipairs({'SetMass','SetCollisionGroup','SetCollisionMask','SetFriction','SetDontRemoveOnSleep'})do e.Physics[n]=function()end end
            e.Remove=function()e.valid=false end;e.IsValid=function()return e.valid end;table.insert(created,e);return e
          end
          session={epoch='epoch',pair={dst_world='world',mc_world='mc',dst_shard='Master',mc_dimension='dst_mc_bridge:stage',region='ground'},mc_origin={x=0,y=64,z=0},dst_origin={x=100,y=0,z=-50},axes={-1,0,0,0,1,0,0,0,1}}
        ''')
    def test_place_wall_remove_and_gap(self):
        self.lua.execute('''
          local collision=require('dstmc/collision');collision.Bind(session)
          assert(collision.Apply({full=true,revision=1,changes={{cell={x=-17,y=64,z=0},state='minecraft:stone'},{cell={x=-16,y=64,z=0},state='minecraft:stone'}}}))
          local vertices=0;for _,e in ipairs(created)do if e.valid then vertices=vertices+#e.mesh end end
          assert(vertices==180,'shared face across negative chunk boundary must be removed')
          assert(next(walls)~=nil)
          assert(not collision.Apply({full=false,from=0,revision=2,changes={}}),'gap must request snapshot')
          assert(collision.Apply({full=true,revision=2,changes={}}));assert(next(walls)==nil)
          for _,e in ipairs(created)do assert(not e.valid,'removal must destroy old physics')end
          assert(collision.Apply({full=false,from=2,revision=3,changes={{cell={x=0,y=67,z=0},state='minecraft:stone'}}}))
          assert(next(walls)==nil,'floating cube cannot block ground navigation')
          collision.Clear();for _,e in ipairs(created)do assert(not e.valid)end
        ''')
    def test_identity_survives_save_and_load(self):
        self.lua.execute('''local Identity=require('components/dstmcidentity');local a=Identity({});local data=a:OnSave();local b=Identity({});b:OnLoad(data);assert(a.world_uuid==b.world_uuid)''')
    def test_damage_durable_retry_and_old_session(self):
        self.lua.execute('''
          storage={};package.preload['json']=function()return {encode=function(x)return x end,decode=function(x)return x end}end
          TheSim={GetPersistentString=function(_,k,cb)cb(storage[k]~=nil,storage[k])end,SetPersistentString=function(_,k,v,encode,cb)storage[k]=v;cb(true)end}
          hp=1000;target={components={health={currenthealth=1000,IsDead=function()return false end},combat={GetAttacked=function(_,attacker,n)hp=hp-n end}},IsValid=function()return true end}
          package.preload['dstmc/actors']=function()return {Find=function(id)return id=='target' and target or nil end}end
          local combat=require('dstmc/combat');combat.Bind(session)
          local event={id='one',type='damage',pair=session.pair,epoch=session.epoch,source='MC',target='target',position={x=0,y=64,z=0},amount=10,kind='melee'}
          combat.Apply(event);combat.Apply(event);assert(hp==900)
          local results=combat.Results();assert(#results==1 and results[1].status=='APPLIED')
          combat.Release();combat.Bind(session);combat.Apply(event);assert(hp==900,'restart must not replay applied')
          event.id='two';event.epoch='old';combat.Apply(event);assert(hp==900,'foreign epoch must not mutate')
        ''')
    def test_controller_returns_to_its_previous_state(self):
        self.lua.execute('''
          local state=true;local moved=0
          ThePlayer={components={playercontroller={IsEnabled=function()return state end,Enable=function(_,v)state=v end},locomotor={Stop=function()end}},Physics={Stop=function()end,Teleport=function()moved=moved+1 end},IsValid=function()return true end}
          local world=require('dstmc/world');world.Bind(session)
          assert(not world.ApplyPlayer({position={x=1,y=0,z=2}},'old','MC'));assert(moved==0 and state)
          assert(world.ApplyPlayer({position={x=1,y=0,z=2}},session.epoch,'MC'));assert(not state and moved==1)
          world.Release();assert(state);world.Update();assert(moved==1)
          state=false;world.Bind(session);world.ApplyPlayer({position={x=1,y=0,z=2}},session.epoch,'MC');world.Release();assert(not state,'restore disabled controller without enabling it')
        ''')

    def test_damage_waits_for_durable_receipt_and_uncertain_restart_does_not_replay(self):
        self.lua.execute('''
          package.preload['json']=function()return {encode=function(x)return x end,decode=function(x)return x end}end
          local function copy(t)if type(t)~='table'then return t end;local r={};for k,v in pairs(t)do r[k]=copy(v)end;return r end
          storage={};writes={}
          TheSim={GetPersistentString=function(_,k,cb)cb(storage[k]~=nil,storage[k])end,SetPersistentString=function(_,k,v,encode,cb)local snapshot=copy(v);writes[#writes+1]=function()storage[k]=snapshot;cb(true)end end}
          hp=1000;target={components={health={IsDead=function()return false end},combat={GetAttacked=function(_,attacker,n)hp=hp-n end}},IsValid=function()return true end}
          package.preload['dstmc/actors']=function()return {Find=function()return target end}end
          local combat=require('dstmc/combat');combat.Bind(session)
          local e={id='durable',type='damage',pair=session.pair,epoch=session.epoch,source='MC',target='target',position={x=0,y=64,z=0},amount=10,kind='melee'}
          combat.Apply(e);assert(hp==1000 and #writes==1,'no side effect before durable receipt')
          writes[1]();assert(hp==900 and #writes==2)
          -- Crash before the completion write: disk contains only PENDING.
          combat.Release();combat.Bind(session);combat.Apply(e)
          assert(hp==900 and combat.Results()[1].status=='UNRESOLVED','uncertain event must never replay')
        ''')

    def test_shadow_hit_forwarded_once_and_modifier_restored(self):
        self.lua.execute('''
          package.preload['json']=function()return {encode=function(x)return x end,decode=function(x)return x end}end
          TheSim={GetPersistentString=function(_,k,cb)cb(false,'')end,SetPersistentString=function(_,k,v,encode,cb)cb(true)end}
          local original=function(_,amount)return amount*.5 end
          local health={deltamodifierfn=original,SetPercent=function(_,v)ratio=v end}
          ThePlayer={components={health=health},Transform={GetWorldPosition=function()return 1,0,2 end},HasTag=function()return false end}
          local combat=require('dstmc/combat');combat.Bind(session);combat.Player({id='mc-player',health=10,max_health=20,alive=true},'MC')
          assert(ratio==.5)
          assert(health.deltamodifierfn(ThePlayer,-20,false,'attack',false,nil,false)==0,'shadow health must wait for MC authority')
          local out=combat.Outgoing();assert(#out==1 and out[1].amount==10 and out[1].source=='DST')
          combat.Acknowledge({{id=out[1].id,status='APPLIED'}});assert(#combat.Outgoing()==0)
          combat.Release();assert(health.deltamodifierfn==original,'restore previous health hook')
        ''')
