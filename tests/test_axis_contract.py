"""Pure schema contracts; no listeners, game processes, or saves."""
import copy
import json
from pathlib import Path
import unittest
from jsonschema import Draft202012Validator
ROOT=Path(__file__).resolve().parents[1]
SCHEMA=json.loads((ROOT/'protocol/http-v2.schema.json').read_text())
HANDSHAKE=json.loads((ROOT/'protocol/fixtures/http-v2.json').read_text())['handshake']

class AxisSchemaTests(unittest.TestCase):
    def validator(self,name):
        return Draft202012Validator({'$ref':'#/$defs/'+name,'$defs':SCHEMA['$defs']})
    def status(self):
        return dict(protocol=2,status='PAIRED',pair=HANDSHAKE['pair'],epoch=HANDSHAKE['epoch'],mc_world=HANDSHAKE['pair']['mc_world'],run_id=HANDSHAKE['epoch'],pid=1,started_at_ms=0,heartbeat=1,peer_last_seen_ms=0,fixture=True,stage_ready=True,frame_path=None,generation=None,latest_frame=None,width=None,height=None,dst_origin=HANDSHAKE['dst_origin'],mc_origin=HANDSHAKE['mc_origin'],axes=[-1,0,0,0,1,0,0,0,1])
    def test_paired_transform_required_even_before_stream(self):
        v=self.validator('StatusResponse');good=self.status();v.validate(good)
        for key in ('dst_origin','mc_origin','axes'):
            for remove in (False,True):
                bad=copy.deepcopy(good)
                if remove:del bad[key]
                else:bad[key]=None
                self.assertFalse(v.is_valid(bad),key)
        unpaired=good|dict(status='UNPAIRED',pair=None,epoch=None,dst_origin=None,mc_origin=None,axes=None)
        v.validate(unpaired)
    def test_only_two_calibrated_bases(self):
        v=self.validator('HandshakeResponse');response=HANDSHAKE|dict(frame_path='/tmp/frame',axes=[1,0,0,0,1,0,0,0,1])
        v.validate(response);v.validate(response|dict(axes=[-1,0,0,0,1,0,0,0,1]))
        for axes in ([1,0,0,0,-1,0,0,0,1],[2,0,0,0,1,0,0,0,1],[-1,.1,0,0,1,0,0,0,1],[-1,0,0,0,1,0,0,0],[-1,False,0,0,1,0,0,0,1]):
            self.assertFalse(v.is_valid(response|dict(axes=axes)))
