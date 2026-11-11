# XEL Lock Analysis: Optimized Locking Demo

Tools and results for the optimized locking demo in *No Fluff, Just Facts: AI Essentials for Data Professionals*.

The `Track_Lock_Usage` Extended Events session (`00 - XEvent Setup - Track_Lock_Usage.sql`) captured the same two UPDATE transactions against `dbo.Customer` in `AutoDealershipDemo` (`04 - 0 - Run_Track_Lock_Usage_XEvent.sql`) under three settings:

| Run | Settings | Source file |
|---|---|---|
| 1 | No optimized locking, no RCSI | `LockTracking_without_optimized_locking_1.xel` |
| 2 | Optimized locking, no RCSI | `LockTracking_with_XACT_no_RCSI_1.xel` |
| 3 | Optimized locking + RCSI | `LockTracking_with_XACT_RCSI.xel` |

## Files

| File | What it is |
|---|---|
| `xel_lock_parser.py` | Standalone Python reader for `.xel` files (standard library only) |
| `OptimizedLocking_XE_Results.xlsx` | Results workbook: Summary, Statement Metrics, Lock Detail, Escalations, Findings & Caveats |

## Running the parser

```powershell
python xel_lock_parser.py run1.xel run2.xel run3.xel --csv-dir .\out
```

It prints a per-statement summary (duration, rows, locks acquired, escalations). With `--csv-dir` it also writes:

- `<file>_events.csv`: one row per event, with lock fields decoded (resource type, mode, transaction id, resources, escalation counts)
- `<file>_statement_locks.csv`: lock counts per statement, resource type and mode
- `lock_summary.csv`: one row per UPDATE statement across all files

## How it was built

No `.xel` reader was available in the sandbox Claude worked in: no SQL Server, PowerShell, or .NET, and no network access to install XELite. So Claude reverse-engineered the binary format from the captured files:

- **Blocks:** metadata blocks (`0xFFFFFFFF` signature) define packages, events, fields and maps. Event blocks hold the records.
- **Event records:** 4-byte event key, then a timestamp in 100 ns ticks, a payload length, and fixed fields at the offsets given in the metadata.
- **Action records:** `0x03 <id> 0x10 <len> <data>` (sql_text, session_id, ...).

The parser was checked by pairing lock acquires with releases, and by matching row counts and logical reads in `sql_statement_completed`.

> This is a demo tool, not a supported reader. For real work, use `sys.fn_xe_file_target_read_file` or Microsoft's XELite library.

## Key results

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Update 1 (8–9 rows): locks acquired | 8,200 | 12,016 | **13** |
| Update 1: escalation | none | table X | none |
| Update 2 (4,824 rows): locks acquired | 20,403 | 20,399 | **4,829** |
| Update 2: escalation | table X | table X | none |

Optimized locking without RCSI gives you only TID locking: row locks are released early. Scans still take U locks, and both updates still escalated. With RCSI on, lock after qualification (LAQ) removes the scan locks and skip index locks (SIL) removes the row X locks. See the workbook's **Findings & Caveats** sheet for the open questions.

## References

- [Optimized locking – Microsoft Learn](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking)

---
*Last updated 2026-10-23 by Claude (model: claude-opus-5-5).*
