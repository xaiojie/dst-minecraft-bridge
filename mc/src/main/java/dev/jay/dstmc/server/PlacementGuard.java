package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
public final class PlacementGuard {
    public static boolean overlaps(Box a,Box b){return a.min().x()<b.max().x()&&a.max().x()>b.min().x()&&a.min().y()<b.max().y()&&a.max().y()>b.min().y()&&a.min().z()<b.max().z()&&a.max().z()>b.min().z();}
    public static Box box(Cell c){return new Box(new Vec3(c.x(),c.y(),c.z()),new Vec3(c.x()+1,c.y()+1,c.z()+1));}
    public static String reason(Cell cell,ActorRegistry actors,long now){
        if(!actors.fresh(now))return "原生生物状态尚未同步，请稍候";
        for(Body b:actors.snapshot().bodies())if(b.health()>0&&overlaps(box(cell),b.box()))return "这里有饥荒生物，无法放置方块";
        return "";
    }
}
