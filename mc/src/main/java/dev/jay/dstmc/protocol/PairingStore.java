package dev.jay.dstmc.protocol;
import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.HexFormat;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
/** Atomic, forced records; malformed state fails closed instead of silently recalibrating. */
public final class PairingStore {
    private final Path directory;
    public PairingStore(Path directory) { this.directory=directory; }
    public synchronized WorldTransform loadOrCreate(PairKey pair, Vec3 dstOrigin, Vec3 mcOrigin) {
        try {
            Files.createDirectories(directory);
            Path file=directory.resolve(HexFormat.of().formatHex(pairHash(pair))+".pair");
            // Lock a stable separate inode so atomic record replacement cannot bypass the lock.
            try(var channel=FileChannel.open(directory.resolve(".pairing.lock"), StandardOpenOption.CREATE,StandardOpenOption.WRITE); var ignored=channel.lock()) {
                if(Files.exists(file)) {
                    try(var in=new DataInputStream(Files.newInputStream(file))) {
                        if(in.readInt()!=0x44535032 || !in.readUTF().equals(canonicalPair(pair))) throw new IOException("pair identity mismatch");
                        var result=new WorldTransform(readVec(in),readVec(in));
                        if(in.read()!=-1) throw new IOException("extra pairing bytes");
                        return result;
                    }
                }
                var transform=new WorldTransform(dstOrigin,mcOrigin);
                var bytes=new ByteArrayOutputStream();
                try(var out=new DataOutputStream(bytes)) { out.writeInt(0x44535032); out.writeUTF(canonicalPair(pair)); writeVec(out,dstOrigin); writeVec(out,mcOrigin); }
                atomicWrite(file,bytes.toByteArray()); return transform;
            }
        } catch(IOException e) { throw new UncheckedIOException(e); }
    }
    private static Vec3 readVec(DataInputStream in) throws IOException { return new Vec3(in.readDouble(),in.readDouble(),in.readDouble()); }
    private static void writeVec(DataOutputStream out,Vec3 p) throws IOException { out.writeDouble(p.x());out.writeDouble(p.y());out.writeDouble(p.z()); }
    static void atomicWrite(Path file,byte[] data) throws IOException {
        Path tmp=Files.createTempFile(file.getParent(),".pending-",".tmp");
        try {
            try(var channel=FileChannel.open(tmp,StandardOpenOption.WRITE)) { var b=java.nio.ByteBuffer.wrap(data); while(b.hasRemaining()) channel.write(b); channel.force(true); }
            Files.move(tmp,file,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
            try(var parent=FileChannel.open(file.getParent(),StandardOpenOption.READ)) { parent.force(true); }
        } finally { Files.deleteIfExists(tmp); }
    }
}
