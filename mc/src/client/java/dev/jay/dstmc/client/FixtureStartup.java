package dev.jay.dstmc.client;

/** Bounded dev fixture loading policy; normal saves keep Minecraft's backup prompt. */
public final class FixtureStartup {
    public static boolean continuePrepared(boolean enabled,String levelId,Runnable backup,Runnable continuation){
        if(!enabled || !"DST-MC-Frame-Fixture".equals(levelId))return false;
        backup.run();
        continuation.run();
        return true;
    }
}
