package dev.jay.dstmc.protocol;
import java.nio.file.*;
import java.nio.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.math.BigDecimal;
import java.math.BigInteger;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
public final class ProtocolContractTest {
    public static final PairKey PAIR = new PairKey(UUID.fromString("11111111-1111-1111-1111-111111111111"), "Master", UUID.fromString("22222222-2222-2222-2222-222222222222"), "minecraft:overworld", "ground");
    public static final UUID EPOCH = UUID.fromString("33333333-3333-3333-3333-333333333333");
    private static int failures;
    public static void check(boolean b, String message) { if (!b) throw new AssertionError(message); }
    private static void test(String name, Throwing body) {
        try { body.run(); System.out.println("PASS " + name); }
        catch (Exception | AssertionError e) { failures++; System.out.println("FAIL " + name + ": " + e); }
    }
    @FunctionalInterface private interface Throwing { void run() throws Exception; }
    public static Pose pose() {
        float[] identity={1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        return new Pose(Space.MC,new Vec3(6.5,66,3),new Vec3(0,0,-1),new Vec3(0,1,0),identity,identity);
    }
    public static void exportFrame(Path path) throws Exception {
        Files.deleteIfExists(path);
        try(var writer=FrameLayout.create(path,2,2)) {
            var color=ByteBuffer.wrap(new byte[]{10,20,30,(byte)255, 11,21,31,(byte)255, 12,22,32,(byte)255, 13,23,33,(byte)255});
            var depth=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN); for(int i=0;i<4;i++) depth.putFloat(0.25f); depth.flip();
            check(writer.publish(new FrameKey(PAIR,EPOCH,42),new WorldTransform(new Vec3(100,0,-50),new Vec3(0,64,0)),pose(),2,2,color,depth,ByteBuffer.allocate(16)), "writer did not publish complete frame");
        }
    }
    private static void await(Path path) throws Exception {
        long deadline=System.nanoTime()+10_000_000_000L;
        while(!Files.exists(path)) { if(System.nanoTime()>deadline) throw new AssertionError("timeout waiting for "+path); Thread.sleep(1); }
    }
    private static boolean publishSolid(FrameLayout writer,long id) {
        byte[] pixels=new byte[16]; Arrays.fill(pixels,(byte)id);
        var depth=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN); for(int i=0;i<4;i++)depth.putFloat((float)id/1024f);depth.flip();
        return writer.publish(new FrameKey(PAIR,EPOCH,id),new WorldTransform(new Vec3(100,0,-50),new Vec3(0,64,0)),pose(),2,2,ByteBuffer.wrap(pixels),depth,ByteBuffer.wrap(pixels));
    }
    private static void sharedWriter(Path dir) throws Exception {
        check(System.getProperty("os.arch").equals("aarch64"), "cross-architecture writer must be ARM64");
        try(var writer=FrameLayout.create(dir.resolve("shared.bin"),2,2)) {
            for(long id=100;id<=102;id++)check(publishSolid(writer,id), "initial publication failed");
            Files.writeString(dir.resolve("ready"),"ARM64 writer ready"); await(dir.resolve("all-leased"));
            check(!publishSolid(writer,103), "overwrote a leased slot");Files.writeString(dir.resolve("blocked"),"all slots protected");
            await(dir.resolve("released"));check(publishSolid(writer,103), "released slot not reusable");
            Files.writeString(dir.resolve("reused"),"released slot reused");await(dir.resolve("stress-go"));
            for(long id=104;id<304;id++) {
                check(publishSolid(writer,id), "publication unexpectedly blocked");await(dir.resolve("ack-"+id));
            }
            System.out.println("Java " + System.getProperty("os.arch") + " shared writer: PASS (leased slot backpressure + 200 concurrent publications)");
        }
    }
    public static void run(String[] args) throws Exception {
        if(args.length==2 && args[0].equals("--shared-writer")) { sharedWriter(Path.of(args[1]));return; }
        // Break caught: using absolute positions instead of fixed paired origins.
        test("coordinate_roundtrip", () -> {
            var transform = new WorldTransform(new Vec3(100,0,-50), new Vec3(0,64,0));
            var input = new Vec3(106.5,2,-47);
            check(transform.toMc(input).equals(new Vec3(6.5,66,3)), "expected MC (6.5,66,3), got " + transform.toMc(input));
            check(transform.toDst(transform.toMc(input)).equals(input), "roundtrip changed position");
        });
        // Break caught: recalibrating the same persisted pair at restart.
        test("restart_keeps_origin", () -> {
            Path dir = Files.createTempDirectory("pairing-contract");
            var original = new PairingStore(dir).loadOrCreate(PAIR, new Vec3(100,0,-50), new Vec3(0,64,0));
            var reopened = new PairingStore(dir).loadOrCreate(PAIR, new Vec3(0,0,0), new Vec3(999,0,0));
            check(original.equals(reopened), "restart changed persisted origin");
        });
        // Break: a saved mode is forgotten, or direction conversion incorrectly includes translation.
        test("reflected_pair_store_and_direction_roundtrip", () -> {
            Path dir=Files.createTempDirectory("reflected-pair");
            var t=new PairingStore(dir).loadOrCreate(PAIR,new Vec3(100,2,-50),new Vec3(5,64,9),WorldTransform.AxisMode.REFLECT_X);
            check(t.toMc(new Vec3(106,5,-47)).equals(new Vec3(-1,67,12)),"reflected nonzero origins incorrect");
            check(t.directionToMc(new Vec3(2,3,-4)).equals(new Vec3(-2,3,-4)),"direction used translation or wrong axis");
            check(t.directionToDst(new Vec3(-2,3,-4)).equals(new Vec3(2,3,-4)),"direction inverse changed vector");
            check(new PairingStore(dir).loadOrCreate(PAIR,new Vec3(0,0,0),new Vec3(0,0,0),WorldTransform.AxisMode.REFLECT_X).equals(t),"saved reflected origins replaced");
            Path file=dir.resolve(HexFormat.of().formatHex(pairHash(PAIR))+".pair"); byte[] before=Files.readAllBytes(file);
            boolean rejected=false;try{new PairingStore(dir).loadOrCreate(PAIR,new Vec3(0,0,0),new Vec3(0,0,0));}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected && Arrays.equals(before,Files.readAllBytes(file)),"mode mismatch migrated pair record");
        });
        test("legacy_pair_record_stays_identity", () -> {
            Path dir=Files.createTempDirectory("legacy-pair"); Path file=dir.resolve(HexFormat.of().formatHex(pairHash(PAIR))+".pair");
            try(var out=new java.io.DataOutputStream(Files.newOutputStream(file))){out.writeInt(0x44535032);out.writeUTF(canonicalPair(PAIR));for(double n:new double[]{100,0,-50,0,64,0})out.writeDouble(n);}
            byte[] before=Files.readAllBytes(file);
            check(new PairingStore(dir).loadOrCreate(PAIR,new Vec3(0,0,0),new Vec3(0,0,0)).toMc(new Vec3(106,2,-47)).equals(new Vec3(6,66,3)),"legacy pair changed basis");
            boolean rejected=false;try{new PairingStore(dir).loadOrCreate(PAIR,new Vec3(0,0,0),new Vec3(0,0,0),WorldTransform.AxisMode.REFLECT_X);}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected && Arrays.equals(before,Files.readAllBytes(file)),"legacy record silently migrated");
        });
        test("malformed_pair_records_fail_closed", () -> {
            for(int corrupt=0;corrupt<4;corrupt++) {
                Path dir=Files.createTempDirectory("bad-pair"); Path file=dir.resolve(HexFormat.of().formatHex(pairHash(PAIR))+".pair");
                try(var out=new java.io.DataOutputStream(Files.newOutputStream(file))){out.writeInt(corrupt==0?0x44535034:0x44535033);out.writeUTF(canonicalPair(PAIR));for(double n:new double[]{corrupt==1?Double.NaN:100,0,-50,0,64,0})out.writeDouble(n);out.writeUTF(corrupt==2?"REFLECT_Y":"REFLECT_X");if(corrupt==3)out.writeByte(1);}
                byte[] before=Files.readAllBytes(file);boolean rejected=false;
                try{new PairingStore(dir).loadOrCreate(PAIR,new Vec3(0,0,0),new Vec3(0,0,0),WorldTransform.AxisMode.REFLECT_X);}catch(RuntimeException expected){rejected=true;}
                check(rejected && Arrays.equals(before,Files.readAllBytes(file)),"malformed record overwritten or accepted");
            }
        });
        // Break caught: accepting damage from an old handshake/world.
        test("foreign_epoch_rejected", () -> {
            var ledger = new RequestLedger(Files.createTempDirectory("ledger-epoch"), PAIR, EPOCH);
            var old = new Command(UUID.randomUUID(), PAIR, UUID.randomUUID(), "damage", Map.of());
            check(ledger.receive(old).status() == Status.REJECTED, "old epoch was accepted");
            var foreign = new PairKey(UUID.randomUUID(), "Master", PAIR.mc_world(), PAIR.mc_dimension(), PAIR.region());
            check(ledger.receive(new Command(old.id(),foreign,EPOCH,"damage",Map.of())).status() == Status.REJECTED, "foreign pair was accepted");
            check(ledger.receive(new Command(old.id(),PAIR,EPOCH,"damage",Map.of())).status() == Status.PENDING, "rejection poisoned current command id");
        });
        // Break caught: acknowledging receipt as application or replaying uncertain work.
        test("receipt_is_not_application", () -> {
            Path dir = Files.createTempDirectory("ledger-restart");
            var command = new Command(UUID.randomUUID(),PAIR,EPOCH,"damage",Map.of("amount",5));
            var ledger = new RequestLedger(dir,PAIR,EPOCH);
            check(ledger.receive(command).status() == Status.PENDING, "receipt must be PENDING");
            check(ledger.receive(command).status() == Status.PENDING, "duplicate should keep one pending item");
            check(ledger.pollPending().orElseThrow().equals(command), "new command must schedule once");
            check(ledger.pollPending().isEmpty(), "duplicate scheduled twice");
            ledger.close();
            var reopened = new RequestLedger(dir,PAIR,EPOCH);
            check(reopened.receive(command).status() == Status.UNRESOLVED, "restart replayed pending item");
            check(reopened.pollPending().isEmpty(), "unresolved work was replayed");
        });
        test("applied_survives_restart", () -> {
            Path dir = Files.createTempDirectory("ledger-applied");
            var command = new Command(UUID.randomUUID(),PAIR,EPOCH,"damage",Map.of());
            var ledger = new RequestLedger(dir,PAIR,EPOCH);
            ledger.receive(command);
            check(ledger.receive(command).status() == Status.PENDING, "must await game thread");
            ledger.finish(command.id(),new CommandResult(command.id(),Status.APPLIED,"game-thread confirmed"));
            ledger.close();
            try(var reopened=new RequestLedger(dir,PAIR,EPOCH)) {
                check(reopened.receive(command).status() == Status.APPLIED, "lost confirmed application");
                check(reopened.receive(command).reason().equals("game-thread confirmed"), "lost application evidence");
            }
        });
        // Break caught: two live journals schedule one persistent command twice.
        test("exclusive_ledger_owner", () -> {
            Path dir=Files.createTempDirectory("ledger-exclusive");
            try(var owner=new RequestLedger(dir,PAIR,EPOCH)) {
                boolean rejected=false;
                try(var duplicate=new RequestLedger(dir,PAIR,EPOCH)) { /* must fail to acquire ownership */ }
                catch(IllegalStateException expected) { rejected=true; }
                check(rejected,"two live ledgers acquired the same pair journal");
            }
            try(var reopened=new RequestLedger(dir,PAIR,EPOCH)) {
                check(reopened.pollPending().isEmpty(),"empty reopened journal scheduled work");
            }
        });
        test("reused_id_and_terminal_mutation_rejected", () -> {
            Path dir=Files.createTempDirectory("ledger-id");
            var id=UUID.randomUUID();var original=new Command(id,PAIR,EPOCH,"damage",Map.of("amount",5));
            try(var ledger=new RequestLedger(dir,PAIR,EPOCH)) {
                ledger.receive(original);
                check(ledger.receive(new Command(id,PAIR,EPOCH,"damage",Map.of("amount",6))).status()==Status.REJECTED,"reused id changed parameters");
                check(BridgeTypes.json(ledger.pollPending().orElseThrow().payload().get("amount")).equals("5"),"changed payload entered queue");
                var applied=new CommandResult(id,Status.APPLIED,"confirmed");ledger.finish(id,applied);ledger.finish(id,applied);
                boolean rejected=false;try { ledger.finish(id,new CommandResult(id,Status.REJECTED,"rewrite")); } catch(IllegalStateException expected) { rejected=true; }
                check(rejected,"terminal state was overwritten");
            }
            try(var nextEpoch=new RequestLedger(dir,PAIR,UUID.randomUUID())) {
                check(nextEpoch.receive(original).status()==Status.REJECTED,"old epoch command accepted after restart");
                check(nextEpoch.pollPending().isEmpty(),"old epoch work replayed");
            }
        });
        // Break caught: caller mutation changes a queued effect after its fingerprint was persisted.
        test("mutable_number_snapshot_matches_receipt", () -> {
            Path dir=Files.createTempDirectory("ledger-number-snapshot");
            var id=UUID.randomUUID();
            var amount=new AtomicInteger(5);
            var nestedAmount=new AtomicInteger(7);
            var command=new Command(id,PAIR,EPOCH,"damage",Map.of("amount",amount,"nested",List.of(Map.of("amount",nestedAmount))));
            try(var ledger=new RequestLedger(dir,PAIR,EPOCH)) {
                check(ledger.receive(command).status()==Status.PENDING,"initial command was not received");
                amount.set(99);
                nestedAmount.set(101);
                var queued=ledger.pollPending().orElseThrow();
                check(BridgeTypes.json(queued.payload()).equals("{\"amount\":5,\"nested\":[{\"amount\":7}]}"),"queued command changed after receipt: "+BridgeTypes.json(queued.payload()));
                var duplicate=new Command(id,PAIR,EPOCH,"damage",Map.of("amount",5,"nested",List.of(Map.of("amount",7))));
                check(ledger.receive(duplicate).status()==Status.PENDING,"persisted identity no longer matches queued effect");
                check(ledger.pollPending().isEmpty(),"equivalent numeric retry queued twice");
            }
        });
        // Break caught: passing exact decimal/integer values through double loses range or precision.
        test("exact_finite_json_numbers_preserved", () -> {
            var huge=new BigInteger("9007199254740993123456789012345678901234567890");
            var exact=new BigDecimal("0.123456789012345678901234567890123456789");
            var outOfDoubleRange=new BigDecimal("1e309");
            var command=new Command(UUID.randomUUID(),PAIR,EPOCH,"numbers",Map.of("huge",huge,"exact",exact,"large",outOfDoubleRange));
            String payload=BridgeTypes.json(command.payload());
            check(payload.contains("\"huge\":9007199254740993123456789012345678901234567890"),"integer precision changed");
            check(payload.contains("\"exact\":0.123456789012345678901234567890123456789"),"decimal precision changed");
            check(new BigDecimal(BridgeTypes.json(command.payload().get("large"))).compareTo(outOfDoubleRange)==0,"finite large decimal changed");
            for(Number invalid:List.of(Double.NaN,Double.POSITIVE_INFINITY,Double.NEGATIVE_INFINITY,Float.NaN,Float.POSITIVE_INFINITY)) {
                boolean rejected=false;
                try { new Command(UUID.randomUUID(),PAIR,EPOCH,"invalid",Map.of("amount",invalid)); }
                catch(IllegalArgumentException expected) { rejected=true; }
                check(rejected,"non-finite floating-point value accepted");
            }
        });
        test("reflected_shared_frame_metadata", () -> {
            Path file=Files.createTempDirectory("reflected-frame").resolve("frame.bin");
            var t=new WorldTransform(new Vec3(100,2,-50),new Vec3(5,64,9),WorldTransform.AxisMode.REFLECT_X);
            try(var w=FrameLayout.create(file,2,2)){
                check(w.publish(new FrameKey(PAIR,EPOCH,1),t,pose(),2,2,ByteBuffer.allocate(16),ByteBuffer.allocate(16),ByteBuffer.allocate(16)),"reflected frame missing");
            }
            var b=ByteBuffer.wrap(Files.readAllBytes(file)).order(ByteOrder.LITTLE_ENDIAN);
            check(b.getDouble(4096+128)==100 && b.getDouble(4096+152)==5 && b.getDouble(4096+176)==-1 && b.getDouble(4096+208)==1 && b.getDouble(4096+240)==1,"binary reflection/origin ABI incorrect");
        });
        test("mapping_rejects_transform_changes_within_epoch", () -> {
            Path file=Files.createTempDirectory("fixed-frame-transform").resolve("frame.bin");
            var t=new WorldTransform(new Vec3(100,0,-50),new Vec3(0,64,0));
            try(var w=FrameLayout.create(file,2,2)){
                check(w.publish(new FrameKey(PAIR,EPOCH,1),t,pose(),2,2,ByteBuffer.allocate(16),ByteBuffer.allocate(16),ByteBuffer.allocate(16)),"initial frame missing");
                byte[] before=Files.readAllBytes(file);boolean rejected=false;
                try{w.publish(new FrameKey(PAIR,EPOCH,2),new WorldTransform(t.dstOrigin(),t.mcOrigin(),WorldTransform.AxisMode.REFLECT_X),pose(),2,2,ByteBuffer.allocate(16),ByteBuffer.allocate(16),ByteBuffer.allocate(16));}catch(IllegalArgumentException expected){rejected=true;}
                check(rejected && Arrays.equals(before,Files.readAllBytes(file)),"same mapping published changed calibration");
            }
        });
        // Break caught: publication acknowledged without writing a complete mapped frame.
        test("java_exports_binary_frame", () -> { Path p=Files.createTempDirectory("frame-export").resolve("frame.bin"); exportFrame(p); check(Files.size(p)>4096, "missing fixed header and slots"); });
        if (failures != 0) throw new AssertionError(failures + " contract assertion(s) failed");
        Path fixtures=Path.of("../protocol/fixtures"); Files.createDirectories(fixtures); exportFrame(fixtures.resolve("frame-v2.bin"));
        System.out.println("Java " + System.getProperty("os.arch") + " exported frame-v2.bin");
    }
}
