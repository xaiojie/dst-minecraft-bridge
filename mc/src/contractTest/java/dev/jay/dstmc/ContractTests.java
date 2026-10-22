package dev.jay.dstmc;
import dev.jay.dstmc.protocol.ProtocolContractTest;
public final class ContractTests {
    public static void main(String[] args) throws Exception { ProtocolContractTest.run(args); if(args.length==2 && args[0].equals("--shared-writer"))return; dev.jay.dstmc.client.FramePublisherTest.run(); dev.jay.dstmc.server.WorldExchangeTest.run(); dev.jay.dstmc.client.FixtureStartupTest.run(); }
}
