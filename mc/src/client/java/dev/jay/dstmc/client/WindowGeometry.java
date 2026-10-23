package dev.jay.dstmc.client;

/** Native client rectangle. Coordinates use the same desktop units as GLFW. */
public record WindowGeometry(int x,int y,int logicalWidth,int logicalHeight,
                             int physicalWidth,int physicalHeight,double scaleX,double scaleY) {
    public WindowGeometry {
        if(logicalWidth<=0||logicalHeight<=0||physicalWidth<=0||physicalHeight<=0||physicalWidth>1920||physicalHeight>1080
            ||!Double.isFinite(scaleX)||!Double.isFinite(scaleY)||scaleX<=0||scaleY<=0
            ||Math.abs(physicalWidth-logicalWidth*scaleX)>1||Math.abs(physicalHeight-logicalHeight*scaleY)>1)
            throw new IllegalArgumentException("inconsistent native render size");
    }
    private static int units(int pixels,double framebufferScale){
        if(!Double.isFinite(framebufferScale)||framebufferScale<=0)throw new IllegalArgumentException("invalid framebuffer scale");
        return Math.max(1,(int)Math.round(pixels/framebufferScale));
    }
    public int windowWidth(double framebufferScale){return units(physicalWidth,framebufferScale);}
    public int windowHeight(double framebufferScale){return units(physicalHeight,framebufferScale);}
}
