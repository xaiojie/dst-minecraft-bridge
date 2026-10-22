#!/usr/bin/env python3
"""Collect fresh same-run evidence; never promote missing/manual checks to PASS."""
import argparse
from datetime import datetime,timezone
import json
from pathlib import Path
import time
import urllib.request
import uuid
CHECKS=('continuous_camera','hand_hud','tree_creature_occlusion','place_block_obstacle_remove_passage','tnt','bidirectional_damage','save_restore','climbing','recovery','performance')
def stamp():return datetime.now(timezone.utc).isoformat()
def empty_report(run_id,pair,epoch):
    return {'run_id':run_id,'pair':pair,'epoch':epoch,'observed_at':stamp(),'checks':[{'name':name,'result':'NOT_VERIFIED','evidence':[]}for name in CHECKS]}
def frame_metrics(events):
    frames=[e for e in events if e.get('event')=='compose' and e.get('status')==0]
    if len(frames)<2:return {'duration_s':0,'unique_frame_fps':0,'composites':len(frames)}
    duration=(frames[-1]['t']-frames[0]['t'])/1000
    ids={e['frame']for e in frames}
    return {'duration_s':duration,'unique_frame_fps':max(0,len(ids)-1)/duration if duration>0 else 0,'composites':len(frames),'unique_frames':len(ids)}
def apply_observations(report,observation):
    if any(observation.get(k)!=report[k] for k in ('run_id','pair','epoch')):raise ValueError('observation is not from this pairing and run')
    for value in observation.get('checks',[]):
        target=next((v for v in report['checks']if v['name']==value['name']),None)
        if target is None or value.get('result')not in ('PASS','FAIL','NOT_VERIFIED'):raise ValueError('invalid check')
        if value['result']=='PASS' and not value.get('evidence'):raise ValueError('PASS requires evidence')
        target.update(value)
    return report

def main():
    p=argparse.ArgumentParser();p.add_argument('--seconds',type=float,default=60);p.add_argument('--out',type=Path,required=True);p.add_argument('--native-log',type=Path);p.add_argument('--observations',type=Path);args=p.parse_args()
    args.out.mkdir(parents=True,exist_ok=False);samples=[];events=[];run_id=str(uuid.uuid4());report=empty_report(run_id,None,None)
    cursor=args.native_log.stat().st_size if args.native_log and args.native_log.exists()else 0
    deadline=time.monotonic()+args.seconds;start=time.monotonic()
    print(json.dumps({'run_id':run_id,'out':str(args.out.resolve())}),flush=True)
    try:
        while time.monotonic()<deadline:
            with urllib.request.urlopen('http://127.0.0.1:39379/v2/status',timeout=1)as response:status=json.load(response)
            if status.get('protocol')!=2 or status.get('status')!='PAIRED':raise ValueError('fresh paired server required')
            if samples and (status['run_id']!=samples[0]['run_id'] or status['epoch']!=samples[0]['epoch']):raise ValueError('session changed during sample')
            status['elapsed']=time.monotonic()-start;samples.append(status);report['pair']=status['pair'];report['epoch']=status['epoch']
            time.sleep(.1)
        if args.native_log:
            with args.native_log.open()as f:
                f.seek(cursor)
                for line in f:
                    try:events.append(json.loads(line))
                    except ValueError:pass
        metrics=frame_metrics(events);report['metrics']=metrics
        if len(samples)>1:
            duration=samples[-1]['elapsed']-samples[0]['elapsed'];metrics['server_tick_hz']=(samples[-1]['heartbeat']-samples[0]['heartbeat'])/duration
        if metrics['duration_s']>=59 and metrics['unique_frame_fps']>=30 and 19<=metrics.get('server_tick_hz',0)<=21:
            report['checks'][-1].update(result='PASS',evidence=['native-events.jsonl','status-samples.json'])
        if args.observations:apply_observations(report,json.loads(args.observations.read_text()))
    except Exception as error:report['error']=str(error)
    finally:
        (args.out/'status-samples.json').write_text(json.dumps(samples,indent=2)+'\n');(args.out/'native-events.jsonl').write_text(''.join(json.dumps(e)+'\n'for e in events));(args.out/'result.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 1 if report.get('error') else 0
if __name__=='__main__':raise SystemExit(main())
