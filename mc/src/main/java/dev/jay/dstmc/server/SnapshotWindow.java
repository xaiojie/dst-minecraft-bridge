package dev.jay.dstmc.server;
import java.util.UUID;
/** A server-issued token bounds capture age without synchronizing process clocks.
 * Sampling must happen after receiving the token. Its age is therefore a
 * conservative upper bound on sample age, including dispatch and queue delay. */
public final class SnapshotWindow {
    private String ticket;
    private long issued;
    public String issue(long monotonicMillis) { issued=monotonicMillis;ticket=UUID.randomUUID().toString();return ticket; }
    public boolean accepts(String value,long monotonicMillis) {
        return ticket!=null && ticket.equals(value) && monotonicMillis>=issued && monotonicMillis-issued<=250;
    }
    public long issuedAt() { return issued; }
    public void clear() { ticket=null; }
}
