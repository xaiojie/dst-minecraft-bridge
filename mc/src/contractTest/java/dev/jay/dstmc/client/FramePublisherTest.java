package dev.jay.dstmc.client;
import java.nio.*;import java.nio.channels.*;import java.nio.file.*;import java.util.*;
import dev.jay.dstmc.protocol.*;import static dev.jay.dstmc.protocol.BridgeTypes.*;
public final class FramePublisherTest {
 static final PairKey PAIR=new PairKey(new UUID(0,1),"surface",new UUID(0,2),"dst_mc_bridge:stage","ground");
 static final UUID EPOCH=new UUID(0,3);
 static final float[] I={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
 static final Pose POSE=new Pose(Space.MC,new Vec3(0,65.62,0),new Vec3(0,0,1),new Vec3(0,1,0),I,I);
 static FramePublisher publisher() throws Exception {var p=new FramePublisher(Files.createTempDirectory("publisher"),PAIR,EPOCH,new WorldTransform(new Vec3(0,0,0),new Vec3(0,64,0)));p.resize(1,1);return p;}
 static ByteBuffer rgba(){return ByteBuffer.wrap(new byte[]{(byte)255,0,0,(byte)128});}
 static ByteBuffer depth(){return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(0,.5f);}
 static void completed(FramePublisher p,long g){p.world(g,POSE,rgba(),depth());p.hud(g,rgba());}
 static void check(boolean b,String s){if(!b)throw new AssertionError(s);}
 static int readNative(Path helper,FramePublisher p,FrameKey key)throws Exception{
  var command=new ArrayList<String>();if(System.getProperty("os.name").startsWith("Mac"))command.addAll(List.of("/usr/bin/arch","-x86_64"));command.addAll(List.of(helper.toString(),p.path().toString(),HexFormat.of().formatHex(pairHash(key.pair())),key.epoch().toString().replace("-",""),Long.toUnsignedString(key.id())));return new ProcessBuilder(command).inheritIO().start().waitFor();
 }
 interface Test{void run()throws Exception;}
 static int failures;
 static void test(String name,Test test){try{test.run();System.out.println("PASS "+name);}catch(Throwable e){failures++;System.out.println("FAIL "+name+": "+e);}}
 public static void run() throws Exception {
  // Break: acknowledge a frame even though every mapped slot is leased.
  test("leased_slot_not_overwritten",()->{try(var p=publisher()){
   completed(p,p.generation());check(p.publishCompleted().isPresent(),"first completed frame missing");
   check(p.path()!=null,"published frame has no mapping");
   try(var ch=FileChannel.open(p.path(),StandardOpenOption.READ,StandardOpenOption.WRITE)){
    var m=ch.map(FileChannel.MapMode.READ_WRITE,0,ch.size());m.order(ByteOrder.LITTLE_ENDIAN);int stride=(int)m.getLong(32);
    for(int s=0;s<3;s++)m.putLong(4096+s*stride+8,99);
    byte[] before=new byte[m.capacity()];m.duplicate().get(before);completed(p,p.generation());
    check(p.publishCompleted().isEmpty(),"leased frame acknowledged");byte[] after=new byte[m.capacity()];m.duplicate().get(after);check(Arrays.equals(before,after),"leased bytes changed");
   }
  }});
  // Break: expose world before HUD GPU readback completed.
  test("partial_readback_not_published",()->{try(var p=publisher()){p.world(p.generation(),POSE,rgba(),depth());check(p.publishCompleted().isEmpty(),"partial GPU readback published");p.hud(p.generation(),rgba());check(p.publishCompleted().isPresent(),"complete readback missing");check(p.publishCompleted().isEmpty(),"same readback replayed");}});
  // Break: delayed callbacks after resize contaminate next generation.
  test("resize_discards_pending_readback",()->{try(var p=publisher()){long old=p.generation();p.world(old,POSE,rgba(),depth());p.resize(2,1);p.hud(old,rgba());check(p.publishCompleted().isEmpty(),"stale resize callback published");check(p.generation()!=old,"generation unchanged");}});
  // Break: native-endian packed integers swap red/blue or leave straight alpha.
  test("alpha_and_channel_order",()->{
   Path helper;
   if(System.getProperty("os.name").startsWith("Windows")){
    helper=Path.of(System.getenv().getOrDefault("DSTMC_RGBA_READER","../native/build-windows/Release/publisher_rgba_reader.exe")).toAbsolutePath();
    if(!Files.isRegularFile(helper))helper=Path.of("../native/build-windows/publisher_rgba_reader.exe").toAbsolutePath();
    check(Files.isRegularFile(helper),"build Windows CMake publisher_rgba_reader before Java checks");
   }else{
    helper=Files.createTempDirectory("publisher-native").resolve("rgba-reader");
    var compile=new ArrayList<String>(List.of("clang++","-std=c++17","-Wall","-Wextra","-Werror","-O2","-I../native/include","src/contractTest/cpp/publisher_rgba_reader.cpp","-o",helper.toString()));
    if(System.getProperty("os.name").startsWith("Mac")){compile.add(1,"-arch");compile.add(2,"x86_64");}
    check(new ProcessBuilder(compile).inheritIO().start().waitFor()==0,"native reader compile failed");
   }
   try(var p=publisher()){
    // Input is already premultiplied, as real GL blend output is. Do not call
    // the conversion helper here: the producer must preserve these exact bytes.
    var world=ByteBuffer.wrap(new byte[]{(byte)128,0,0,(byte)128});
    var depth=ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(0,.25f);
    var hud=ByteBuffer.wrap(new byte[]{0,0,64,64});
    p.world(p.generation(),POSE,world,depth);p.hud(p.generation(),hud);
    var key=p.publishCompleted().orElseThrow();
    check(readNative(helper,p,key)==0,"native published channels/depth/HUD mismatch");
    // Negative control: prove the real reader's assertions catch red/blue swaps.
    p.world(p.generation(),POSE,ByteBuffer.wrap(new byte[]{0,0,(byte)128,(byte)128}),depth);p.hud(p.generation(),hud);
    check(readNative(helper,p,p.publishCompleted().orElseThrow())==7,"swapped world RGBA escaped native assertions");
   }
  });
  if(failures>0)throw new AssertionError(failures+" publisher assertion(s) failed");
 }
 public static void main(String[] args)throws Exception{run();}
}
