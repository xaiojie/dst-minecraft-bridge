package dev.jay.dstmc.server;

/** JSON adapters consumed by Lua support only exactly representable unsigned integers. */
public final class HttpIntegers {
    public static long exact(long value){
        if(value<0 || value>9007199254740991L)throw new IllegalArgumentException("HTTP_UINT64_NOT_EXACT");
        return value;
    }
}
