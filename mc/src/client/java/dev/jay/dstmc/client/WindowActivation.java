package dev.jay.dstmc.client;

/** Client-thread activation proof; no game or window calls. */
final class WindowActivation {
    record Ticket(Object session, long generation, long deadline) {}
    private Object session;
    private long generation, validUntil;
    boolean session(Object value) {
        if (session == value) return false;
        session = value;
        generation++;
        validUntil = 0;
        return true;
    }
    Ticket dispatch(long now) { return new Ticket(session, generation, now + 200_000_000L); }
    boolean accept(Ticket ticket, long now) {
        if (session == null || ticket.session() != session || ticket.generation() != generation
                || now >= ticket.deadline()) return false;
        validUntil = ticket.deadline();
        return true;
    }
    boolean active(Object current, long now) { return current != null && current == session && now < validUntil; }
    void invalidate() { validUntil = 0; }
}
