package dev.jay.dstmc.protocol;
import java.io.*;
import java.nio.file.*;
import java.nio.channels.*;
import java.util.*;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
/** Exclusive live ledger owner per directory/pair. Restart never schedules uncertain side effects. */
public final class RequestLedger implements AutoCloseable {
    private final Path directory;
    private final PairKey pair;
    private final UUID epoch;
    private FileChannel ownership;
    private boolean closed;
    private final Map<UUID,Entry> entries=new HashMap<>();
    private final ArrayDeque<Command> pending=new ArrayDeque<>();
    private record Entry(UUID epoch,String fingerprint,CommandResult result) {}
    public RequestLedger(Path directory, PairKey pair, UUID epoch) {
        this.directory=directory.resolve(HexFormat.of().formatHex(pairHash(pair))); this.pair=pair; this.epoch=Objects.requireNonNull(epoch);
        try {
            Files.createDirectories(this.directory);
            ownership=FileChannel.open(this.directory.resolve(".ledger.lock"),StandardOpenOption.CREATE,StandardOpenOption.WRITE);
            try { if(ownership.tryLock()==null) throw new IllegalStateException("pair ledger already owned"); }
            catch(OverlappingFileLockException e) { throw new IllegalStateException("pair ledger already owned",e); }
            try(var files=Files.newDirectoryStream(this.directory,"*.request")) {
                for(Path file:files) {
                    Entry entry; UUID id;
                    try(var in=new DataInputStream(Files.newInputStream(file))) {
                        if(in.readInt()!=0x44534c32 || !in.readUTF().equals(canonicalPair(pair))) throw new IOException("ledger pair mismatch");
                        id=UUID.fromString(in.readUTF()); var oldEpoch=UUID.fromString(in.readUTF()); var fingerprint=in.readUTF();
                        var status=Status.valueOf(in.readUTF()); var reason=in.readUTF();
                        if(in.read()!=-1 || !file.getFileName().toString().equals(id+".request")) throw new IOException("malformed ledger record");
                        if(status==Status.PENDING) { status=Status.UNRESOLVED; reason="restart before confirmed application; reconcile before any retry"; }
                        entry=new Entry(oldEpoch,fingerprint,new CommandResult(id,status,reason));
                    }
                    entries.put(id,entry); persist(id,entry);
                }
            }
        } catch(IOException | RuntimeException e) {
            if(ownership!=null) try { ownership.close(); } catch(IOException cleanup) { e.addSuppressed(cleanup); }
            if(e instanceof IOException io) throw new UncheckedIOException(io);
            throw (RuntimeException)e;
        }
    }
    public synchronized CommandResult receive(Command command) {
        requireOpen();
        if (!pair.equals(command.pair()) || !epoch.equals(command.epoch())) {
            return new CommandResult(command.id(), Status.REJECTED, "foreign pair or epoch");
        }
        String fingerprint=HexFormat.of().formatHex(sha256(json(command.kind())+":"+json(command.payload())));
        Entry existing=entries.get(command.id());
        if(existing!=null) {
            if (!existing.epoch.equals(command.epoch()) || !existing.fingerprint.equals(fingerprint)) {
                return new CommandResult(command.id(), Status.REJECTED, "command id reused with different epoch or parameters");
            }
            return existing.result;
        }
        var result = new CommandResult(command.id(), Status.PENDING, "received; awaiting game thread");
        var entry = new Entry(epoch, fingerprint, result);
        persist(command.id(), entry);
        entries.put(command.id(), entry);
        pending.add(command);
        return result;
    }
    /** Only the game-thread consumer calls this. A duplicate HTTP receipt never requeues. */
    public synchronized Optional<Command> pollPending() {
        requireOpen();
        return Optional.ofNullable(pending.poll());
    }
    public synchronized void finish(UUID id,CommandResult result) {
        requireOpen();
        Entry old=entries.get(id);
        if (old == null || !id.equals(result.id()) || !old.epoch.equals(epoch)) {
            throw new IllegalArgumentException("unknown or foreign command");
        }
        if (result.status() == Status.PENDING) {
            throw new IllegalArgumentException("finish requires final result");
        }
        if (old.result.status() != Status.PENDING && old.result.status() != Status.UNRESOLVED) {
            if (!old.result.equals(result)) {
                throw new IllegalStateException("terminal result is immutable");
            }
            return;
        }
        var entry = new Entry(old.epoch, old.fingerprint, result);
        persist(id, entry);
        entries.put(id, entry);
        pending.removeIf(command -> command.id().equals(id));
    }
    private void requireOpen() { if(closed) throw new IllegalStateException("closed ledger"); }
    @Override public synchronized void close() {
        if(!closed) {
            closed=true;pending.clear();
            try { ownership.close(); } catch(IOException e) { throw new UncheckedIOException(e); }
        }
    }
    private void persist(UUID id,Entry entry) {
        try {
            var bytes=new ByteArrayOutputStream();
            try(var out=new DataOutputStream(bytes)) {
                out.writeInt(0x44534c32); out.writeUTF(canonicalPair(pair));out.writeUTF(id.toString());out.writeUTF(entry.epoch.toString());out.writeUTF(entry.fingerprint);out.writeUTF(entry.result.status().name());out.writeUTF(entry.result.reason());
            }
            PairingStore.atomicWrite(directory.resolve(id+".request"),bytes.toByteArray());
        } catch(IOException e) { throw new UncheckedIOException(e); }
    }
}
