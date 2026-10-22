package dev.jay.dstmc;
import dev.jay.dstmc.protocol.ProtocolContractTest;
public final class ContractTests {
    public static void main(String[] args) throws Exception { ProtocolContractTest.run(args); dev.jay.dstmc.client.FramePublisherTest.run(); dev.jay.dstmc.server.WorldExchangeTest.run(); dev.jay.dstmc.client.FixtureStartupTest.run(); }
}
