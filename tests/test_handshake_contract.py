"""Cross-language handshake contract: the body connection.lua really emits must be
accepted by the real Java WorldExchange gate, and the Java gate must stay strict.

The regressions these tests cover are real handoff defects:
  * dst-mod/scripts/dstmc/connection.lua sent mc_origin={.5,64,.5} while Java accepts only (0,64,0);
  * it also sent region="first-person-test" while Java accepts only "ground".
Both ends are checked, so a "fix" that loosens Java's world identity fails here too.
"""
import json
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
from tools.platform_support import find_java
JAVA = find_java()
JAVAC = JAVA.with_name('javac'+JAVA.suffix)
EXCHANGE = ROOT / 'mc/src/main/java/dev/jay/dstmc/server/WorldExchange.java'
CONNECTION = ROOT / 'dst-mod/scripts/dstmc/connection.lua'

try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime = None
try:
    import jsonschema
except ImportError:
    jsonschema = None


def java_contract():
    """The single acceptance gate in Java, read from source instead of restated here."""
    text = EXCHANGE.read_text()
    gate = re.search(
        r'pair\.region\(\)\.equals\("([^"]+)"\).*?mcOrigin\.equals\(new Vec3\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)\)',
        text, re.S)
    if gate is None:
        raise AssertionError('WorldExchange handshake gate not found; contract test needs updating')
    dimension = re.search(r'pair\.mc_dimension\(\)\.equals\("([^"]+)"\)', text)
    return dict(region=gate.group(1),
                mc_origin=tuple(float(gate.group(i)) for i in (2, 3, 4)),
                mc_dimension=dimension.group(1))


def sha_request_keys():
    """POST /v2/handshake accepts an EXACT key set (additionalProperties:false)."""
    text = (ROOT / 'mc/src/main/java/dev/jay/dstmc/server/BridgeServer.java').read_text()
    call = re.search(r'requireKeys\(input,((?:\s*"[^"]+"\s*,?)+)\)', text)
    return {key for key in re.findall(r'"([^"]+)"', call.group(1))}


def plain(value):
    if hasattr(value, 'items'):
        return {plain(k): plain(v) for k, v in value.items()}
    return value


@unittest.skipUnless(LuaRuntime, 'Lua behavioral checks require lupa (isolated test environment)')
def lua_handshake():
    """Drive the real connection.lua handshake against a stubbed sim, return the POST body."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
        clock=1;requests={};print=function()end
        function GetTimeRealSeconds() return clock end
        package.preload['json']=function() return {encode=function(v)return v end,decode=function(v)return v end} end
        package.preload['dstmc/gameplay']=function()return {Update=function()end}end
        package.preload['dstmc/mailbox']=function()return {Active=function()return false end,Poll=function()end}end
        package.preload['dstmc/world']=function() return {
            LocalWorld=function()return {world_uuid='11111111-2222-4333-8444-555555555555',shard='Master'}end,
            Origin=function()return {x=12.5,y=0,z=-8.25}end} end
        package.preload['components/dstmcidentity']=function()return {NewUUID=function()return 'e0e0e0e0-0000-4000-8000-000000000000' end}end
        package.preload['dstmc/camera']=function()return {Install=function()end,Release=function()end,Key=function()return nil end,ApplyLease=function()return true end}end
        TheSim={QueryServer=function(self,url,cb,method,body)table.insert(requests,{url=url,cb=cb,method=method,body=body})end}
    """)
    lua.globals().connection = lua.execute(CONNECTION.read_text())
    lua.execute("connection.Start(true);connection.Update()")
    lua.execute("assert(#requests==1);assert(requests[1].url:find('/v2/status'));"
                "requests[1].cb({protocol=2,fixture=false,mc_world='99999999-8888-4777-8666-555555555555'},true,200)")
    lua.execute("assert(#requests==2);assert(requests[2].url:find('/v2/handshake'));assert(requests[2].method=='POST')")
    return plain(lua.eval('requests[2].body'))


class HandshakePayloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract = java_contract()
        cls.body = lua_handshake()

    def test_lua_payload_uses_java_region_and_mc_origin(self):
        pair = self.body['pair']
        self.assertEqual(pair['region'], self.contract['region'],
                         'connection.lua region must be the region Java accepts')
        self.assertEqual(pair['mc_dimension'], self.contract['mc_dimension'])
        candidate = self.body['mc_origin']
        self.assertEqual((candidate['x'], candidate['y'], candidate['z']), self.contract['mc_origin'],
                         'connection.lua mc_origin must be the origin Java accepts')
        # The DST origin is the live player position; it is stored by Java on first pairing.
        self.assertEqual((self.body['dst_origin']['x'], self.body['dst_origin']['y'], self.body['dst_origin']['z']),
                         (12.5, 0.0, -8.25))

    def test_lua_payload_is_a_valid_handshake_request(self):
        # Exact key set: Java rejects extra fields, so a well-meant extra "axes" would 400.
        self.assertEqual(set(self.body), sha_request_keys())
        json.dumps(self.body)  # everything the Lua encoder receives must be JSON-representable
        if jsonschema is None:
            self.skipTest('jsonschema not installed')
        schema = json.loads((ROOT / 'protocol/http-v2.schema.json').read_text())
        jsonschema.validate(self.body, {'$defs': schema['$defs'], '$ref': '#/$defs/HandshakeRequest'})

    def test_java_accepts_the_real_lua_payload_and_stays_strict(self):
        """Compile the real gate and feed it the values extracted from the Lua source."""
        if not JAVAC.exists():
            self.skipTest('JDK 21 unavailable')
        pair = self.body['pair']
        harness = f"""
package dev.jay.dstmc.harness;
import dev.jay.dstmc.protocol.*;
import dev.jay.dstmc.server.WorldExchange;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import java.nio.file.*;
import java.util.*;
public class HandshakeContractCheck {{
    public static void main(String[] args) throws Exception {{
        Path save = Files.createTempDirectory("dstmc-handshake-");
        var exchange = new WorldExchange(save);
        UUID dstWorld = UUID.fromString(args[0]);
        String shard = args[1], mcDimension = args[2], region = args[3];
        UUID epoch = UUID.fromString(args[4]);
        Vec3 dst = new Vec3(Double.parseDouble(args[5]), Double.parseDouble(args[6]), Double.parseDouble(args[7]));
        Vec3 mc = new Vec3(Double.parseDouble(args[8]), Double.parseDouble(args[9]), Double.parseDouble(args[10]));
        var pair = new PairKey(dstWorld, shard, exchange.mcWorld(), mcDimension, region);
        var result = exchange.handshake(pair, epoch, dst, mc);
        if (!result.reason().isEmpty())
            throw new AssertionError("real_lua_payload_rejected reason=" + result.reason()
                + " region=" + region + " mc_origin=" + mc);
        if (result.transform().axisMode() != WorldTransform.AxisMode.REFLECT_X)
            throw new AssertionError("first_binding_must_persist_reflected_axes");
        // Negative control: the identity-axes legacy binding must still be refused, and a
        // drifted region/precision must not sneak through a loosened gate.
        Path legacy = Files.createTempDirectory("dstmc-handshake-legacy-");
        var other = new WorldExchange(legacy);
        var mismatched = other.handshake(new PairKey(dstWorld, shard, other.mcWorld(), mcDimension, "first-person-test"),
                                         epoch, dst, mc);
        if (!mismatched.reason().equals("WORLD_MISMATCH"))
            throw new AssertionError("loosened_region_gate reason=" + mismatched.reason());
        var offset = other.handshake(new PairKey(dstWorld, shard, other.mcWorld(), mcDimension, region),
                                     epoch, dst, new Vec3(0.5, 64, 0.5));
        if (!offset.reason().equals("WORLD_MISMATCH"))
            throw new AssertionError("half_block_mc_origin_accepted reason=" + offset.reason());
        System.out.println("PASS accepted_reflected_binding region=" + region + " mc_origin_strict");
    }}
}}
"""
        sources = [EXCHANGE,
                   ROOT / 'mc/src/main/java/dev/jay/dstmc/protocol/BridgeTypes.java',
                   ROOT / 'mc/src/main/java/dev/jay/dstmc/protocol/WorldTransform.java',
                   ROOT / 'mc/src/main/java/dev/jay/dstmc/protocol/AtomicFiles.java']
        with tempfile.TemporaryDirectory(prefix='dstmc-handshake-check-') as temp:
            check = pathlib.Path(temp) / 'HandshakeContractCheck.java'
            check.write_text(harness)
            subprocess.run([str(JAVAC), '-d', temp, *map(str, sources), str(check)],
                           check=True, capture_output=True, text=True)
            args = [pair['dst_world'], pair['dst_shard'], pair['mc_dimension'], pair['region'],
                    self.body['epoch'],
                    str(self.body['dst_origin']['x']), str(self.body['dst_origin']['y']), str(self.body['dst_origin']['z']),
                    str(self.body['mc_origin']['x']), str(self.body['mc_origin']['y']), str(self.body['mc_origin']['z'])]
            result = subprocess.run([str(JAVA), '-cp', temp,
                                     'dev.jay.dstmc.harness.HandshakeContractCheck', *map(str, args)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS accepted_reflected_binding', result.stdout)


if __name__ == '__main__':
    unittest.main()
