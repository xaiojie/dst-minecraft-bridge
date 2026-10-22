package dev.jay.dstmc.client;
import java.util.*;
public final class FixtureStartupTest {
    static void check(boolean value,String reason){if(!value)throw new AssertionError(reason);}
    public static void run(){
        // Break: property alone continues a real save or continuation runs before its backup succeeds.
        var calls=new ArrayList<String>();
        for(boolean enabled:List.of(false,true))for(String id:List.of("DST-MC-FirstPerson-Test","DST-MC-Test","other"))
            check(!FixtureStartup.continuePrepared(enabled,id,()->calls.add("backup"),()->calls.add("continue")),"unrelated save continued");
        check(!FixtureStartup.continuePrepared(false,"DST-MC-Frame-Fixture",()->calls.add("backup"),()->calls.add("continue")),"production behavior changed");
        check(calls.isEmpty(),"guarded actions ran");
        check(FixtureStartup.continuePrepared(true,"DST-MC-Frame-Fixture",()->calls.add("backup"),()->calls.add("continue")),"fixture not continued");
        check(calls.equals(List.of("backup","continue")),"backup must finish before continuation");
        calls.clear();
        try{FixtureStartup.continuePrepared(true,"DST-MC-Frame-Fixture",()->{throw new IllegalStateException("backup failed");},()->calls.add("continue"));throw new AssertionError("backup failure swallowed");}catch(IllegalStateException expected){}
        check(calls.isEmpty(),"continued without backup");
        System.out.println("PASS fixture_startup_dual_guard_and_backup_order");
    }
}
