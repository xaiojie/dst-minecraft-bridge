package dev.jay.dstmc.client;
/** Input edges survive an in-flight HTTP poll and revision-conflict retries. */
public final class InputSwitch {
    private Boolean desired;
    public void press(boolean owner){desired=!(desired==null?owner:desired);}
    public Boolean desired(){return desired;}
    public void confirmed(boolean owner){if(desired!=null&&desired==owner)desired=null;}
    public void reset(){desired=null;}
}
