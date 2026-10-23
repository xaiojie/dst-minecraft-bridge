package dev.jay.dstmc.client;

public final class WindowGeometryTest {
    private static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    private static void rejects(Runnable action){try{action.run();throw new AssertionError("invalid geometry accepted");}catch(IllegalArgumentException expected){}}
    public static void run(){
        // Break: treating a Retina/150% framebuffer size as a GLFW window size.
        var retina=new WindowGeometry(10,20,960,540,1920,1080,2,2);
        check(retina.windowWidth(2)==960&&retina.windowHeight(2)==540,"Retina size doubled");
        var scaled=new WindowGeometry(-1280,30,960,540,1440,810,1.5,1.5);
        check(scaled.windowWidth(1)==1440&&scaled.windowHeight(1)==810,"physical Windows window units lost");
        check(scaled.windowWidth(1.5)==960,"150% GLFW size incorrect");
        // Break: integer rounding at fractional per-axis scale rejects valid windows.
        var rounded=new WindowGeometry(0,0,641,359,962,539,1.5,1.5);
        check(rounded.windowWidth(1.5)==641&&rounded.windowHeight(1.5)==359,"rounded window dimensions incorrect");
        rejects(()->new WindowGeometry(0,0,960,540,1920,1080,1,1));
        rejects(()->new WindowGeometry(0,0,0,540,960,540,1,1));
        rejects(()->new WindowGeometry(0,0,960,540,960,540,Double.NaN,1));
        rejects(()->scaled.windowWidth(0));
        // Geometry is bootstrap data, not permission to suppress the MC window.
        var activation=new WindowActivation();var session=new Object();activation.session(session);
        check(!activation.active(session,100),"geometry alone grants activation");
        System.out.println("PASS window_geometry_fractional_dpi_and_no_activation");
    }
    public static void main(String[]args){run();}
}
