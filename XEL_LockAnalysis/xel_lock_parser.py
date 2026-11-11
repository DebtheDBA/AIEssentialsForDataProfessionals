#!/usr/bin/env python3
"""
xel_lock_parser.py - Read SQL Server Extended Events (.xel) files without SQL Server,
PowerShell, or .NET, and summarize lock activity per statement.

Built for the "No Fluff, Just Facts: AI Essentials for Data Professionals" optimized
locking demo (Track_Lock_Usage XE session: lock_acquired, lock_released, lock_escalation,
sql_batch_starting/completed, sql_statement_starting/completed).

The .xel format is undocumented. This parser was reverse-engineered from the files
captured for the demo and verified against them (acquire/release pairs line up, and
row counts / logical reads match sql_statement_completed). Treat it as a demo tool,
not a supported reader. For production use sys.fn_xe_file_target_read_file or
the Microsoft.SqlServer.XEvent.XELite library.

Format notes (as observed):
  * File = sequence of blocks: [uint32 sig][uint16 ver][uint16 type][uint32 size]...
      sig 0xFFFFFFFF = metadata block (packages, events, fields, maps)
      sig 1..n       = event data block; records start at block offset 0x45
  * Event record : [4-byte event key][8 bytes][uint64 timestamp (100 ns ticks)]
                   [uint32 payload length][payload]  -> fixed fields at metadata offsets
  * Action record: [0x03][uint16 action id][0x10][uint32 length][data]
  * Records are separated by an 8-byte trailer 00 00 00 60 00 00 00 00
  * The 4-byte event key is the 4 bytes that precede the event name in metadata.

Usage:
  python xel_lock_parser.py file1.xel [file2.xel ...] [--csv-dir OUTDIR]

Prints a per-statement summary; with --csv-dir also writes
  <file>_events.csv           one row per event (lock fields decoded)
  <file>_statement_locks.csv  lock counts per statement / resource type / mode
  lock_summary.csv            one row per UPDATE statement across all files
Standard library only (Python 3.8+).
"""
import argparse
import collections
import csv
import os
import re
import struct

# ---------------------------------------------------------------- map values
# Taken from the lock_resource_type / lock_mode / lock_owner_type maps embedded in
# the files' metadata (SQL Server 2025).
RESOURCE_TYPE = {0: 'UNKNOWN', 1: 'NULL_RESOURCE', 2: 'DATABASE', 3: 'FILE', 4: 'UNUSED1',
                 5: 'OBJECT', 6: 'PAGE', 7: 'KEY', 8: 'EXTENT', 9: 'RID', 10: 'APPLICATION',
                 11: 'METADATA', 12: 'HOBT', 13: 'ALLOCATION_UNIT', 14: 'OIB',
                 15: 'ROWGROUP', 16: 'XACT'}
LOCK_MODE = {0: 'NL', 1: 'SCH_S', 2: 'SCH_M', 3: 'S', 4: 'U', 5: 'X', 6: 'IS', 7: 'IU',
             8: 'IX', 9: 'SIU', 10: 'SIX', 11: 'UIX', 12: 'BU', 13: 'RS_S', 14: 'RS_U',
             15: 'RI_NL', 16: 'RI_S', 17: 'RI_U', 18: 'RI_X', 19: 'RX_S', 20: 'RX_U',
             21: 'RX_X', 22: 'SCH_A', 23: 'SCH_C'}
OWNER_TYPE = {1: 'Transaction', 2: 'Cursor', 3: 'Session', 4: 'SharedXactWorkspace',
              5: 'ExclusiveXactWorkspace', 6: 'LockConflictNotificationObject',
              7: 'LockTableIterator', 8: 'Node', 9: 'LastLockInfoOwner'}
ESCALATION_CAUSE = {0: 'Lock threshold', 1: 'Memory threshold'}

EVENT_NAMES = ['lock_acquired', 'lock_released', 'lock_escalation',
               'sql_statement_starting', 'sql_statement_completed',
               'sql_batch_starting', 'sql_batch_completed']

# action ids observed in the data
ACTION_SQL_TEXT = 0x18
ACTION_SESSION_ID = 0x08

TRAILER = b'\x00\x00\x00\x60\x00\x00\x00\x00'
FIRST_RECORD_OFFSET = 0x45


def _blocks(data):
    off = 0x208                       # first block follows the file header
    while off + 16 <= len(data):
        sig, _ver, _typ, size = struct.unpack_from('<IHHI', data, off)
        if size == 0:
            break
        yield off, sig, size
        off += size


def _event_keys(data):
    """Map 4-byte event key -> event name, read from the metadata block."""
    keys = {}
    for off, sig, size in _blocks(data):
        if sig != 0xFFFFFFFF:
            continue
        block = data[off:off + size]
        for name in EVENT_NAMES:
            i = block.find((name + '\0').encode('utf-16le'))
            if i >= 4:
                keys[block[i - 4:i]] = name
    return keys


def _utf16(b):
    return b.decode('utf-16le', errors='replace').rstrip('\0') if b else ''


def read_events(path):
    """Yield raw events: dict(name, ts, payload, actions)."""
    with open(path, 'rb') as f:
        data = f.read()
    keys = _event_keys(data)
    if not keys:
        raise ValueError(f'{path}: no event metadata found - not an .xel file?')
    for boff, sig, size in _blocks(data):
        if sig == 0xFFFFFFFF:
            continue
        end = min(boff + size, len(data))
        off = boff + FIRST_RECORD_OFFSET
        cur, contiguous = None, False
        while off + 8 <= end:
            key = data[off:off + 4]
            if contiguous and cur is not None and key[0] == 0x03 and key[3] == 0x10:
                aid = struct.unpack_from('<H', data, off + 1)[0]
                ln = struct.unpack_from('<I', data, off + 4)[0]
                cur['actions'][aid] = data[off + 8:off + 8 + ln]
                off += 8 + ln
                continue
            if contiguous and data[off:off + 8] == TRAILER:
                off += 8
                continue
            if key in keys:
                if cur:
                    yield cur
                ts, ln = struct.unpack_from('<QI', data, off + 12)
                cur = {'name': keys[key], 'ts': ts,
                       'payload': data[off + 24:off + 24 + ln], 'actions': {}}
                off += 24 + ln
                contiguous = True
                continue
            off += 1                  # unused tail of a block
            contiguous = False
        if cur:
            yield cur


def decode(ev):
    """Turn a raw event into a flat dict of useful columns."""
    p, name = ev['payload'], ev['name']
    out = {'event': name, 'ts_100ns': ev['ts'],
           'session_id': None, 'sql_text': _utf16(ev['actions'].get(ACTION_SQL_TEXT))}
    sid = ev['actions'].get(ACTION_SESSION_ID)
    if sid and len(sid) == 2:
        out['session_id'] = struct.unpack('<H', sid)[0]
    if name.startswith('lock_'):
        rt, mode, owner = struct.unpack_from('<III', p, 0)
        out.update(resource_type=RESOURCE_TYPE.get(rt, rt), mode=LOCK_MODE.get(mode, mode),
                   owner_type=OWNER_TYPE.get(owner, owner),
                   transaction_id=struct.unpack_from('<q', p, 0x0C)[0],
                   database_id=struct.unpack_from('<I', p, 0x14)[0])
        r0, r1, r2 = struct.unpack_from('<III', p, 0x28)
        out.update(resource_0=r0, resource_1=r1, resource_2=r2)
        if name == 'lock_escalation':
            out.update(escalation_cause=ESCALATION_CAUSE.get(p[0x34], p[0x34]),
                       object_id=struct.unpack_from('<i', p, 0x35)[0],
                       hobt_id=struct.unpack_from('<Q', p, 0x39)[0],
                       escalated_lock_count=struct.unpack_from('<I', p, 0x41)[0],
                       hobt_lock_count=struct.unpack_from('<I', p, 0x45)[0])
        else:
            out.update(object_id=struct.unpack_from('<i', p, 0x34)[0],
                       associated_object_id=struct.unpack_from('<Q', p, 0x38)[0],
                       duration=struct.unpack_from('<Q', p, 0x40)[0])
    elif name == 'sql_statement_completed':
        (out['duration_us'], out['cpu_time_us'], _psr, out['physical_reads'],
         out['logical_reads'], out['writes'], _spills, out['row_count'],
         _lrc) = struct.unpack_from('<9Q', p, 0)
    if name in ('sql_statement_starting', 'sql_statement_completed'):
        runs = re.findall(rb'(?:[\x09\x0a\x0d\x20-\x7e]\x00){4,}', p)
        out['statement'] = ' '.join(' '.join(r.decode('utf-16le') for r in runs).split())
    return out


def analyze(path):
    """Return (events, statements). Each statement holds its metrics and lock counts.

    Lock events are attributed to the statement that is running (between
    sql_statement_starting and the next sql_statement_starting)."""
    events, statements, cur, batch_no = [], [], None, 0
    for raw in read_events(path):
        e = decode(raw)
        events.append(e)
        if e['event'] == 'sql_batch_starting':
            batch_no += 1
        if e['event'] == 'sql_statement_starting':
            cur = {'batch': batch_no, 'statement': e['statement'], 'start_ts': e['ts_100ns'],
                   'locks': collections.Counter(), 'escalations': []}
            statements.append(cur)
        elif e['event'] == 'sql_statement_completed' and cur:
            cur.update({k: e[k] for k in ('duration_us', 'cpu_time_us', 'logical_reads',
                                          'writes', 'row_count')})
        elif cur and e['event'] in ('lock_acquired', 'lock_released'):
            cur['locks'][(e['event'], e['resource_type'], e['mode'])] += 1
        elif cur and e['event'] == 'lock_escalation':
            cur['escalations'].append(e)
    return events, statements


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('files', nargs='+')
    ap.add_argument('--csv-dir')
    args = ap.parse_args()
    summary = []
    for path in args.files:
        events, statements = analyze(path)
        base = os.path.splitext(os.path.basename(path))[0]
        print(f'\n=== {base}: {len(events)} events')
        for s in statements:
            acq = sum(n for (ev, _, _), n in s['locks'].items() if ev == 'lock_acquired')
            first = s['statement'].split()[0].upper() if s['statement'] else '?'
            print(f"  batch {s['batch']} {first:<8} dur={s.get('duration_us', 0)/1000:8.1f} ms  "
                  f"rows={s.get('row_count', 0):<6} locks acquired={acq:<6} "
                  f"escalations={len(s['escalations'])}")
            if first == 'UPDATE':
                row = {'file': base, 'batch': s['batch'],
                       'duration_ms': round(s.get('duration_us', 0) / 1000, 1),
                       'cpu_ms': round(s.get('cpu_time_us', 0) / 1000, 1),
                       'logical_reads': s.get('logical_reads'), 'rows': s.get('row_count'),
                       'locks_acquired': acq, 'escalations': len(s['escalations'])}
                for (ev, rt, mode), n in s['locks'].items():
                    if ev == 'lock_acquired':
                        row[f'{rt}/{mode}'] = n
                summary.append(row)
        if args.csv_dir:
            os.makedirs(args.csv_dir, exist_ok=True)
            cols = sorted({k for e in events for k in e}, key=lambda c: (c != 'event', c))
            with open(os.path.join(args.csv_dir, f'{base}_events.csv'), 'w', newline='',
                      encoding='utf-8') as f:
                w = csv.DictWriter(f, fieldnames=cols)
                w.writeheader()
                w.writerows(events)
            with open(os.path.join(args.csv_dir, f'{base}_statement_locks.csv'), 'w',
                      newline='', encoding='utf-8') as f:
                w = csv.writer(f)
                w.writerow(['batch', 'statement', 'event', 'resource_type', 'mode', 'count'])
                for s in statements:
                    for (ev, rt, mode), n in sorted(s['locks'].items()):
                        w.writerow([s['batch'], s['statement'][:80], ev, rt, mode, n])
    if args.csv_dir and summary:
        cols = list(dict.fromkeys(k for r in summary for k in r))
        with open(os.path.join(args.csv_dir, 'lock_summary.csv'), 'w', newline='',
                  encoding='utf-8') as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(summary)


if __name__ == '__main__':
    main()
