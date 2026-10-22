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
  test("alpha_and_channel_order",()->{var b=ByteBuffer.wrap(new byte[]{(byte)255,0,0,(byte)128,0,0,(byte)255,0});FramePublisher.premultiplyRgba(b);check((b.get(0)&255)==128 && b.get(1)==0 && b.get(2)==0 && (b.get(3)&255)==128,"red premultiplied RGBA mismatch");check(b.get(4)==0&&b.get(5)==0&&b.get(6)==0&&b.get(7)==0,"transparent RGB not zero");});
  if(failures>0)throw new AssertionError(failures+" publisher assertion(s) failed");
 }
 public static void main(String[] args)throws Exception{run();}
}
