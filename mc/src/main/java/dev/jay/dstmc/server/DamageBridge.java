package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import dev.jay.dstmc.protocol.RequestLedger;
import java.nio.file.Path;
import java.util.*;
import java.util.function.Function;
/** Write-ahead durable receipt. Interrupted side effects are UNRESOLVED, never replayed. */
public final class DamageBridge implements AutoCloseable {
    private final RequestLedger ledger;
    public DamageBridge(Path directory,PairKey pair,UUID epoch){ledger=new RequestLedger(directory,pair,epoch);}
    public CommandResult apply(DamageEvent e,Space expected,Function<DamageEvent,String> effect){
        if(e.source()!=expected||!Double.isFinite(e.amount())||e.amount()<=0||e.amount()>10000||e.target()==null||e.position()==null)return new CommandResult(e.id(),Status.REJECTED,"invalid damage source/amount/target");
        var payload=Map.<String,Object>of("target",e.target().toString(),"source",e.source().name(),"x",e.position().x(),"y",e.position().y(),"z",e.position().z(),"amount",e.amount(),"kind",e.kind());
        var receipt=ledger.receive(new Command(e.id(),e.pair(),e.epoch(),"damage",payload));
        if(receipt.status()!=Status.PENDING)return receipt;
        // Only newly received requests are queued. Drain once on the game thread.
        var pending=ledger.pollPending();if(pending.isEmpty())return receipt;
        CommandResult result;
        try{String reason=effect.apply(e);result=new CommandResult(e.id(),reason.isEmpty()?Status.APPLIED:Status.REJECTED,reason);}
        catch(RuntimeException error){result=new CommandResult(e.id(),Status.UNRESOLVED,"effect interrupted; reconcile: "+error.getClass().getSimpleName());}
        ledger.finish(e.id(),result);return result;
    }
    public void close(){ledger.close();}
}
