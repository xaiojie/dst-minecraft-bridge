package dev.jay.dstmc.protocol;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.*;

/** Force file data before atomic replacement; POSIX also permits directory fsync. */
public final class AtomicFiles {
    private AtomicFiles(){}
    public static void write(Path path,byte[] data)throws IOException{
        Path temporary=Files.createTempFile(path.getParent(),".pending-",".tmp");
        try{
            try(var channel=FileChannel.open(temporary,StandardOpenOption.WRITE)){
                var bytes=ByteBuffer.wrap(data);while(bytes.hasRemaining())channel.write(bytes);channel.force(true);
            }
            Files.move(temporary,path,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
            // Windows does not expose directories as Java FileChannels. File
            // force and atomic rename remain mandatory on that filesystem.
            if(path.getFileSystem().supportedFileAttributeViews().contains("posix"))
                try(var directory=FileChannel.open(path.getParent(),StandardOpenOption.READ)){directory.force(true);}
        }finally{Files.deleteIfExists(temporary);}
    }
}
