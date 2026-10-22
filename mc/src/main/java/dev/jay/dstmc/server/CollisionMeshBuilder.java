package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import java.util.*;
/** Full cubes only. Cull shared faces across chunk boundaries, outward winding. */
public final class CollisionMeshBuilder {
    private static final int[][] DIR={{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}};
    private static final int[][][] FACE={{{0,0,0},{0,0,1},{0,1,1},{0,1,0}},{{1,0,1},{1,0,0},{1,1,0},{1,1,1}},{{0,0,1},{0,0,0},{1,0,0},{1,0,1}},{{0,1,0},{0,1,1},{1,1,1},{1,1,0}},{{1,0,0},{0,0,0},{0,1,0},{1,1,0}},{{0,0,1},{1,0,1},{1,1,1},{0,1,1}}};
    public static float[] build(Collection<Cell> cells){
        Set<Cell> solid=new HashSet<>(cells);var out=new ArrayList<Float>();
        for(Cell c:solid)for(int f=0;f<6;f++){int[] d=DIR[f];if(solid.contains(new Cell(c.x()+d[0],c.y()+d[1],c.z()+d[2])))continue;
            for(int v:new int[]{0,1,2,0,2,3}){int[] p=FACE[f][v];out.add((float)(c.x()+p[0]));out.add((float)(c.y()+p[1]));out.add((float)(c.z()+p[2]));}}
        float[] result=new float[out.size()];for(int i=0;i<result.length;i++)result[i]=out.get(i);return result;
    }
    public static boolean blocksGround(Cell c,double ground){return c.y()<ground+1.8&&c.y()+1>ground;}
}
