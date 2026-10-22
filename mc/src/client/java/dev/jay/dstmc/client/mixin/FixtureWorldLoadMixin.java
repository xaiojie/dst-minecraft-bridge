package dev.jay.dstmc.client.mixin;

import dev.jay.dstmc.client.FixtureStartup;
import net.minecraft.client.gui.screens.worldselection.WorldOpenFlows;
import net.minecraft.world.level.storage.LevelStorageSource;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Dev fixture only: take the official backup, then the official world-load continuation. */
@Mixin(WorldOpenFlows.class)
public abstract class FixtureWorldLoadMixin {
    @Inject(method="askForBackup",at=@At("HEAD"),cancellable=true)
    private void loadPreparedFixture(LevelStorageSource.LevelStorageAccess save,boolean customized,Runnable continuation,Runnable cancel,CallbackInfo ci){
        if(FixtureStartup.continuePrepared(Boolean.getBoolean("dstmc.frameFixture"),save.getLevelId(),()->{
            var log=org.slf4j.LoggerFactory.getLogger("dstmc-fixture");
            log.info("Fixture backup gate: level={}, customized={}",save.getLevelId(),customized);
            try{log.info("Fixture backup completed: {} bytes",save.makeWorldBackup());}
            catch(java.io.IOException e){throw new java.io.UncheckedIOException("Fixture backup required before loading",e);}
        },continuation))ci.cancel();
    }
}
