package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import java.nio.file.*;
import java.util.*;
public final class GameplayContractTest {
    static void check(boolean value,String name){if(!value)throw new AssertionError(name);System.out.println("PASS "+name);}
    public static void run() throws Exception {
        var input=new dev.jay.dstmc.client.InputSwitch();input.press(true);check(Boolean.FALSE.equals(input.desired()),"F8_edge_survives_inflight_poll");input.confirmed(true);check(Boolean.FALSE.equals(input.desired()),"poll_does_not_drop_queued_owner");input.confirmed(false);check(input.desired()==null,"owner_ack_consumes_intent");
        Path dir=Files.createTempDirectory("dstmc-gameplay-");
        var stream=new BlockStream(dir.resolve("blocks.bin"),2);
        var left=new Cell(-17,64,-1);var right=new Cell(-16,64,-1);
        stream.set(left,"minecraft:stone");stream.set(right,"minecraft:dirt");
        long at=stream.revision();stream.set(right,"minecraft:air");stream.set(new Cell(16,65,0),"minecraft:stone");
        check(stream.since(0).needs_snapshot(),"gap_requests_snapshot");
        check(stream.since(at).changes().size()==2,"delta_crosses_negative_chunk_boundary");
        check(new BlockStream(dir.resolve("blocks.bin"),2).snapshot().changes().size()==2,"blocks_survive_store_restart");
        check(new BlockStream(dir.resolve("blocks.bin"),2).touched().contains(right),"removed_block_tombstone_survives_for_chunk_reconciliation");
        long before=stream.revision();stream.set(left,"minecraft:stone");check(before==stream.revision(),"duplicate_delta_idempotent");
        var window=new SnapshotWindow();String ticket=window.issue(100);
        check(window.accepts(ticket,200),"fresh_capture_ticket_accepted");
        check(!window.accepts(ticket,351),"delayed_snapshot_not_refreshed_on_arrival");
        String replacement=window.issue(400);check(!window.accepts(ticket,410)&&window.accepts(replacement,410),"previous_request_ticket_rejected");
        window.clear();check(!window.accepts(replacement,410),"disconnected_capture_ticket_rejected");
        var registry=new ActorRegistry();UUID target=UUID.randomUUID();
        registry.update(new ActorSnapshot(1,List.of(new Body(target,new Box(new Vec3(-17,64,-1),new Vec3(-16,66,0)),1000,1000,1))),100);
        check(!PlacementGuard.reason(left,registry,120).isEmpty(),"actor_overlap_rejects_place");
        check(PlacementGuard.reason(new Cell(-16,64,-1),registry,120).isEmpty(),"touching_boundary_is_not_overlap");
        check(!PlacementGuard.reason(new Cell(0,64,0),registry,351).isEmpty(),"stale_actor_snapshot_rejects_place");
        var cubes=List.of(left,right);float[] mesh=CollisionMeshBuilder.build(cubes);
        check(mesh.length==180,"touching_cubes_have_no_internal_wall");
        boolean internal=false;for(int i=0;i<mesh.length;i+=9)if(mesh[i]==-16&&mesh[i+3]==-16&&mesh[i+6]==-16)internal=true;
        check(!internal,"negative_chunk_seam_has_no_internal_face");
        check(CollisionMeshBuilder.build(List.of()).length==0,"remove_restores_passage");
        check(!CollisionMeshBuilder.blocksGround(new Cell(0,67,0),64),"floating_cube_does_not_block_ground_agent");
        Map<Long,Boolean> forced=new HashMap<>();forced.put(9L,true);
        var leases=new ChunkLeaseManager(k->forced.getOrDefault(k,false),(k,v)->forced.put(k,v));
        UUID a=UUID.randomUUID(),b=UUID.randomUUID();leases.acquire(1,a);leases.acquire(1,b);leases.release(a);
        check(forced.get(1L)&&leases.count(1)==1,"two_tnt_share_chunk_lease");leases.release(b);check(!forced.get(1L),"last_tnt_releases_owned_chunk");
        leases.acquire(9,a);leases.release(a);check(forced.get(9L),"preexisting_forced_chunk_preserved");
        var pair=new PairKey(UUID.randomUUID(),"Master",UUID.randomUUID(),"dst_mc_bridge:stage","ground");UUID epoch=UUID.randomUUID();double[] hp={1000};
        var e=new DamageEvent(UUID.randomUUID(),pair,epoch,Space.MC,target,new Vec3(0,64,0),10,"melee");
        try(var damage=new DamageBridge(dir.resolve("damage"),pair,epoch)){
            check(damage.apply(e,Space.MC,x->{hp[0]-=x.amount()*10;return "";}).status()==Status.APPLIED,"damage_applied");
            damage.apply(e,Space.MC,x->{hp[0]-=100;return "";});check(hp[0]==900,"damage_retry_applied_once");
            check(damage.apply(e,Space.DST,x->{throw new AssertionError();}).status()==Status.REJECTED,"echo_not_forwarded");
            var old=new DamageEvent(UUID.randomUUID(),pair,UUID.randomUUID(),Space.MC,target,e.position(),10,"melee");
            check(damage.apply(old,Space.MC,x->{throw new AssertionError();}).status()==Status.REJECTED,"old_world_damage_rejected");
        }
        try(var damage=new DamageBridge(dir.resolve("damage"),pair,epoch)){
            damage.apply(e,Space.MC,x->{throw new AssertionError("replayed");});check(hp[0]==900,"applied_damage_not_replayed_on_restart");
        }
    }
}
