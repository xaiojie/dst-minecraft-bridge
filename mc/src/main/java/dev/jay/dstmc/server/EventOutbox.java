package dev.jay.dstmc.server;
import com.google.gson.*;
import java.nio.file.*;
import java.io.*;
import java.util.*;
/** Retries only within this epoch; a restart archives pending operations for reconciliation. */
public final class EventOutbox {
    private final Path path;private final LinkedHashMap<String,JsonObject> pending=new LinkedHashMap<>();
    private static final Gson JSON=new Gson();
    public EventOutbox(Path path){this.path=path;try{Files.createDirectories(path.getParent());if(Files.exists(path))Files.move(path,path.resolveSibling(path.getFileName()+".unresolved-"+UUID.randomUUID()),StandardCopyOption.ATOMIC_MOVE);}catch(IOException e){throw new UncheckedIOException(e);}}
    public void add(JsonObject event){if(pending.size()>=4096)throw new IllegalStateException("outbox full; reconnect/reconcile");pending.putIfAbsent(event.get("id").getAsString(),event.deepCopy());persist();}
    public List<JsonObject> values(){return List.copyOf(pending.values());}
    public void acknowledge(JsonArray results){boolean changed=false;for(var r:results){JsonObject v=r.getAsJsonObject();String status=v.get("status").getAsString();if(Set.of("APPLIED","REJECTED","UNRESOLVED").contains(status)){JsonObject removed=pending.remove(v.get("id").getAsString());if(removed!=null){recordResult(removed,v);changed=true;}}}if(changed)persist();}
    private void recordResult(JsonObject event,JsonObject result){try{Files.writeString(path.resolveSibling(path.getFileName()+".results.jsonl"),JSON.toJson(Map.of("event",event,"result",result))+"\n",StandardOpenOption.CREATE,StandardOpenOption.APPEND);}catch(IOException e){throw new UncheckedIOException(e);}}
    private void persist(){try{Path temp=Files.createTempFile(path.getParent(),"outbox-",".tmp");try{Files.writeString(temp,JSON.toJson(pending.values()));Files.move(temp,path,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(temp);}}catch(IOException e){throw new UncheckedIOException(e);}}
}
