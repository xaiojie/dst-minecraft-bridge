package dev.jay.dstmc.server;
import java.nio.file.*;import java.util.*;import static dev.jay.dstmc.protocol.BridgeTypes.*;
public final class WorldExchangeTest {
 static void check(boolean b,String s){if(!b)throw new AssertionError(s);}
 public static void main(String[] args)throws Exception{run();}
 public static void run()throws Exception{
  int failures=0;
  // Break: Lua binary64 silently rounds a uint64 above its exact integer range.
  try{
   check(HttpIntegers.exact(0)==0 && HttpIntegers.exact(9007199254740991L)==9007199254740991L,"safe integer boundary rejected");
   for(long value:new long[]{-1,9007199254740992L,Long.MAX_VALUE}){
    boolean refused=false;try{HttpIntegers.exact(value);}catch(IllegalArgumentException expected){refused=true;}
    check(refused,"unsafe HTTP integer accepted: "+value);
   }
   System.out.println("PASS http_uint64_requires_exact_lua_integer");
  }catch(AssertionError e){failures++;System.out.println("FAIL http_uint64_requires_exact_lua_integer: "+e);}
  // Break: a dev VM property alone labels a manually selected final/original save as disposable.
  try{
   check(WorldExchange.frameFixture(Path.of("run/saves/DST-MC-Frame-Fixture/."),true),"fixture dual guard rejected");
   check(!WorldExchange.frameFixture(Path.of("run/saves/DST-MC-Frame-Fixture"),false),"production fixture enabled");
   check(!WorldExchange.frameFixture(Path.of("run/saves/DST-MC-FirstPerson-Test"),false),"normal final save rejected");
   for(String name:List.of("DST-MC-FirstPerson-Test","DST-MC-Test","other")){
    boolean refused=false;try{WorldExchange.frameFixture(Path.of("run/saves",name),true);}catch(IllegalArgumentException expected){refused=true;}
    check(refused,"fixture property accepted wrong save: "+name);
   }
   System.out.println("PASS fixture_requires_property_and_exact_save");
  }catch(AssertionError e){failures++;System.out.println("FAIL fixture_requires_property_and_exact_save: "+e);}
  // Break: opening the same copy regenerates identity and allows a different DST world.
  try{Path path=Files.createTempDirectory("exchange");var first=new WorldExchange(path);var id=first.mcWorld();check(id.equals(new WorldExchange(path).mcWorld()),"world UUID not persistent");System.out.println("PASS world_identity_persisted");}catch(AssertionError e){failures++;System.out.println("FAIL world_identity_persisted: "+e);}
  try{Path path=Files.createTempDirectory("exchange");var first=new WorldExchange(path);UUID dst=UUID.randomUUID();var a=first.handshake(dst,"surface",new Vec3(10,0,-20));var b=new WorldExchange(path).handshake(dst,"surface",new Vec3(99,0,99));check(a.transform().dstOrigin().equals(b.transform().dstOrigin()),"original anchor replaced");System.out.println("PASS pairing_keeps_original_anchor");}catch(AssertionError e){failures++;System.out.println("FAIL pairing_keeps_original_anchor: "+e);}
  try{Path path=Files.createTempDirectory("exchange");var first=new WorldExchange(path);first.handshake(UUID.randomUUID(),"surface",new Vec3(0,0,0));var b=new WorldExchange(path).handshake(UUID.randomUUID(),"surface",new Vec3(0,0,0));check("WORLD_MISMATCH".equals(b.reason()),"different DST world accepted");System.out.println("PASS different_dst_world_rejected");}catch(AssertionError e){failures++;System.out.println("FAIL different_dst_world_rejected: "+e);}
  // Break: production calibration remains translation-only or silently migrates a saved identity binding.
  try {
   Path path=Files.createTempDirectory("reflected-exchange"); var first=new WorldExchange(path); UUID dst=UUID.randomUUID();
   var a=first.handshake(dst,"surface",new Vec3(100,2,-50));
   check(a.transform().toMc(new Vec3(106,5,-47)).equals(new Vec3(-6,67,3)),"production +X must reflect about saved origins");
   check(a.transform().toDst(new Vec3(-6,67,3)).equals(new Vec3(106,5,-47)),"reflected inverse changed position");
   var axes=a.transform().axes(); axes[0]=99;
   check(a.transform().axes()[0]==-1,"mutable returned axes changed binding");
   var b=new WorldExchange(path).handshake(dst,"surface",new Vec3(999,0,999));
   check(a.transform().equals(b.transform()),"restart changed origins or axes");
   System.out.println("PASS production_reflection_persists");
  } catch(AssertionError e){failures++;System.out.println("FAIL production_reflection_persists: "+e);}
  try {
   Path path=Files.createTempDirectory("legacy-exchange"); var first=new WorldExchange(path); UUID dst=UUID.randomUUID();
   Path binding=path.resolve("dst-mc-bridge/binding.bin");
   try(var out=new java.io.DataOutputStream(Files.newOutputStream(binding))){out.writeInt(0x444D4232);out.writeUTF(dst.toString());out.writeUTF("surface");out.writeDouble(100);out.writeDouble(2);out.writeDouble(-50);}
   byte[] before=Files.readAllBytes(binding); var reopened=new WorldExchange(path);
   var result=reopened.handshake(dst,"surface",new Vec3(999,0,999));
   check("TRANSFORM_MISMATCH".equals(result.reason()),"legacy identity binding activated for reflected stage");
   check(reopened.active()==null && Arrays.equals(before,Files.readAllBytes(binding)),"rejected binding activated or mutated");
   System.out.println("PASS legacy_production_binding_rejected_without_mutation");
  }catch(AssertionError e){failures++;System.out.println("FAIL legacy_production_binding_rejected_without_mutation: "+e);}
  try {
   for(int corrupt=0;corrupt<5;corrupt++) {
    Path path=Files.createTempDirectory("bad-binding");new WorldExchange(path);Path binding=path.resolve("dst-mc-bridge/binding.bin");
    try(var out=new java.io.DataOutputStream(Files.newOutputStream(binding))){out.writeInt(corrupt==0?0x444D4234:0x444D4233);out.writeUTF(UUID.randomUUID().toString());out.writeUTF("surface");for(double n:new double[]{corrupt==1?Double.NaN:100,2,-50,corrupt==4?1:0,64,0})out.writeDouble(n);out.writeUTF(corrupt==2?"REFLECT_Z":"REFLECT_X");if(corrupt==3)out.writeByte(1);}
    byte[] before=Files.readAllBytes(binding);boolean rejected=false;
    try{new WorldExchange(path);}catch(RuntimeException expected){rejected=true;}
    check(rejected && Arrays.equals(before,Files.readAllBytes(binding)),"invalid binding accepted or replaced");
   }
   System.out.println("PASS malformed_world_binding_rejected_without_mutation");
  }catch(AssertionError e){failures++;System.out.println("FAIL malformed_world_binding_rejected_without_mutation: "+e);}
  if(failures>0)throw new AssertionError(failures+" exchange assertion(s) failed");
 }
}
