package dev.jay.dstmc.protocol;

import java.nio.file.*;
import java.util.Arrays;

public final class AtomicFilesTest {
    public static void run()throws Exception{
        var directory=Files.createTempDirectory("bridge-存储 spaces-");
        var file=directory.resolve("配对.bin");
        AtomicFiles.write(file,new byte[]{1,2,3});
        AtomicFiles.write(file,new byte[]{9,8});
        if(!Arrays.equals(Files.readAllBytes(file),new byte[]{9,8}))throw new AssertionError("atomic replacement did not persist");
        try(var children=Files.list(directory)){
            if(children.count()!=1)throw new AssertionError("pending atomic files leaked");
        }
        System.out.println("PASS atomic_record_replace_unicode_path_and_no_temp_leak");
    }
}
