"""Acceptance checks against a real running Minecraft, never a mock server."""
import json
import time
import unittest
import urllib.request

class LiveBridgeTest(unittest.TestCase):
    def test_simulation_continues_while_dst_is_connected(self):
        with urllib.request.urlopen('http://127.0.0.1:39379/status', timeout=3) as r:
            before = json.load(r)
        self.assertLess(before['dst_age_ms'], 2500, 'DST is not sending live state')
        time.sleep(1)
        with urllib.request.urlopen('http://127.0.0.1:39379/status', timeout=3) as r:
            after = json.load(r)
        self.assertGreater(after['movement_samples'], before['movement_samples'], 'Minecraft simulation paused while DST was still connected')

    def test_real_minecraft_world_and_mod_are_running(self):
        try:
            with urllib.request.urlopen('http://127.0.0.1:39379/status', timeout=3) as r:
                state = json.load(r)
        except OSError as e:
            self.fail('The Minecraft bridge is not running: ' + str(e))
        self.assertEqual(state['protocol'], 1)
        self.assertTrue(state['world_loaded'], 'Minecraft has not entered a world')
        self.assertGreater(state['players'], 0, 'No real Minecraft player is in the world')

    def test_dst_received_an_actual_minecraft_explosion_once(self):
        state = None
        for attempt in range(30):
            try:
                with urllib.request.urlopen('http://127.0.0.1:39379/status', timeout=3) as r:
                    state = json.load(r)
            except OSError as e:
                self.fail('The Minecraft bridge is not running: ' + str(e))
            reports = state.get('dst', {}).get('damage_reports', [])
            if reports:
                break
            if attempt == 0 and not state.get('dst'):
                self.fail('No real DST world has exchanged state with Minecraft')
            time.sleep(1)
        self.assertTrue(reports, 'No native DST health change was reported')
        first = reports[0]
        self.assertEqual(first['before'] - first['after'], 100)
        self.assertIn(first['event_id'], {e['id'] for e in state['explosions']})
        self.assertEqual(len(reports), len({r['event_id'] for r in reports}), 'One MC explosion was applied more than once')

if __name__ == '__main__':
    unittest.main()
