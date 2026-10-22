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
  if(failures>0)throw new AssertionError(failures+" exchange assertion(s) failed");
 }
}
