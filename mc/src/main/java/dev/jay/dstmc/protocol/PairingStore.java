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
        return loadOrCreate(pair,dstOrigin,mcOrigin,WorldTransform.AxisMode.IDENTITY);
    }
    public synchronized WorldTransform loadOrCreate(PairKey pair, Vec3 dstOrigin, Vec3 mcOrigin, WorldTransform.AxisMode mode) {
        java.util.Objects.requireNonNull(mode);
        try {
            Files.createDirectories(directory);
            Path file=directory.resolve(HexFormat.of().formatHex(pairHash(pair))+".pair");
            // Lock a stable separate inode so atomic record replacement cannot bypass the lock.
            try(var channel=FileChannel.open(directory.resolve(".pairing.lock"), StandardOpenOption.CREATE,StandardOpenOption.WRITE); var ignored=channel.lock()) {
                if(Files.exists(file)) {
                    try(var in=new DataInputStream(Files.newInputStream(file))) {
                        int version=in.readInt();
                        if((version!=0x44535032 && version!=0x44535033) || !in.readUTF().equals(canonicalPair(pair))) throw new IOException("pair identity mismatch");
                        Vec3 savedDst=readVec(in),savedMc=readVec(in);
                        var savedMode=version==0x44535032?WorldTransform.AxisMode.IDENTITY:WorldTransform.AxisMode.valueOf(in.readUTF());
                        var result=new WorldTransform(savedDst,savedMc,savedMode);
                        if(in.read()!=-1) throw new IOException("extra pairing bytes");
                        if(savedMode!=mode) throw new IllegalArgumentException("TRANSFORM_MISMATCH");
                        return result;
                    }
                }
                var transform=new WorldTransform(dstOrigin,mcOrigin,mode);
                var bytes=new ByteArrayOutputStream();
                try(var out=new DataOutputStream(bytes)) { out.writeInt(0x44535033); out.writeUTF(canonicalPair(pair)); writeVec(out,dstOrigin); writeVec(out,mcOrigin); out.writeUTF(mode.name()); }
                atomicWrite(file,bytes.toByteArray()); return transform;
            }
        } catch(IOException e) { throw new UncheckedIOException(e); }
    }
    private static Vec3 readVec(DataInputStream in) throws IOException { return new Vec3(in.readDouble(),in.readDouble(),in.readDouble()); }
    private static void writeVec(DataOutputStream out,Vec3 p) throws IOException { out.writeDouble(p.x());out.writeDouble(p.y());out.writeDouble(p.z()); }
    static void atomicWrite(Path file,byte[] data) throws IOException {
        AtomicFiles.write(file,data);
    }
}
