# FSK BER diagnostic protocol (schema 1, 2026-11-02)

This extension uses the existing FSK TX firmware and normal V2 DATA packets.
RX FPGA and RX MCU need the new diagnostic code. Default state is OFF after
reset. No hardware has been programmed by the implementation or validation
tools. A successful software test/build is not board or acoustic validation.

## Commands and transport

One PC, two independent serial ports, 115200 8-N-1. Commands end in LF.
Existing normal `READ` format remains `OK DATA <hex> time_valid=... timestamp_ms=...`;
it exposes the RX MCU's **latest cached frame**, not a historical frame drain.
Stop-and-wait prevents intentional test-frame pipelining; the host deduplicates
delivery by batch and full 32-bit sequence and verifies the exact expected
Payload before counting it as delivered. Repeated normal READs are observations,
not additional deliveries. The report's `duplicate_deliveries` counts these
repeated cached observations; the unchanged READ interface cannot distinguish
an on-air retransmission of identical contents from rereading the same cache.

| Command | Success | Meaning |
|---|---|---|
| `BER STATUS` | `OK BER STATUS <64 hex digits> crc=HHHH` | Coherent 32-byte FPGA status snapshot |
| `BER HEALTH` | `OK BER HEALTH <40 hex digits> crc=HHHH` | Read-only production register samples: BH01[4] + registers 0x00..0x0D[14] + zero[2] |
| `BER START` | `OK BER ACK` | Enable only when stopped, idle, empty, FSK chain available; reset session counters |
| `BER STOP` | `OK BER ACK` | Disable; active partial record may still be publishing; poll STATUS busy before final drain/CLEAR |
| `BER CLEAR` | `OK BER ACK` | Stopped/idle only; discard diagnostic queue, clear counters |
| `BER READ` | `OK BER RECORD <128 hex digits> crc=HHHH` | Read current 64-byte head without popping |
| `BER POP <uint32 decimal capture_id>` | `OK BER ACK` | Check current head ID, then POP only that diagnostic record |

READ/POP on an empty queue returns `OK BER EMPTY`. Errors use `ERR BER` followed
by COMMAND, ARG, CAPACITY, SPI, UNSUPPORTED, BUSY_OR_UNAVAILABLE, BUSY, RECORD,
ID or CONTROL. The MCU requires a 192-byte output buffer before executing BER
commands; current main uses its existing 384-byte response buffer. Main handles
commands and background normal FIFO service serially; no ISR executes SPI.

Hex transport CRC is CRC16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection,
no xorout), over the decoded 20, 32 or 64 bytes only. CRC is printed as four hex
digits, followed by CRLF. This CRC protects the MCU-to-PC response. FPGA SPI
has no wire CRC: the MCU seeks and reads the immutable head twice before READ
or POP, rejecting disagreement. Persistent identical corruption is not ruled
out by two reads. Schema/signature/field/CRC consistency are also checked by PC.

READ is retryable by seeking to offset zero each time; an incomplete SPI burst
may advance offset at the first clock of an unfinished byte. The host retries
only fully received responses failing diagnostic CRC or explicit `ERR BER SPI`
read responses. A serial timeout leaves reply identity ambiguous: abort, do not
resend SEND or send further ordinary commands on that session. A completely
received POP SPI error is resolved by a coherent status showing popped increased
exactly once; otherwise abort. No blind POP retry. Store diagnostic raw bytes
durably before POP. Cleanup sends best-effort TX STOP and RX BER STOP.

## Capture and register layout

SPI peripheral registers are documented in `rtl/spi/SPI_REGISTER_MAP.md` at
0x49..0x4F. Old register addresses and FW_VERSION are preserved. Capture is
passive: the production parser's registered sync_found arms a private fixed
328-bit capture starting at Header bit7. A simultaneous next bit is retained.
Header length and parser CRC failures do not shorten it. Timeout is 600000
clk_sys cycles without a bit (20 ms at 30 MHz). Lock loss, unavailable FSK chain
or STOP finalizes a partial observation. Fixed length is for this test only.
Header/length corruption can cause raw capture to cross physical frame boundaries;
these records cannot be assigned Payload alignment unless all identity checks pass.

The queue holds 8 independent 64-byte records, committed only after all bytes
publish. New records are dropped when full; old head never changes until POP.
Full, invalid SPI, STOP and all diagnostic controls have no output path into
production demodulator, CRC rejection, parser, normal FIFO, or receiver resets.

| Byte offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII `BR01` |
| 4 | 4 | capture_id LE32, session ordinal starting at 1 |
| 8 | 2 | received bit_count LE16, 0..328 |
| 10 | 1 | flags below |
| 11 | 1 | ceil(bit_count/8), 0..41 |
| 12 | 4 | sample_index LE32 at capture start, wrapping accepted-sample counter |
| 16 | 41 | raw Header[4] + elapsed10[3] + test Payload[32] + CRC16[2] |
| 57 | 7 | zero padding |

Flags: complete=0x01, timeout=0x02, lock_loss/chain unavailable=0x04, stopped=0x08,
header_crc8_ok=0x10, frame_crc16_ok=0x20, expected type 0x20 and length 32=0x40.
One termination flag per record. Partial bytes are valid bits on the left and
zeros on the right; unused raw bytes are zero. Header CRC8 covers raw[0:3],
CRC16 covers raw[0:39] (including CRC8 byte); raw[39:41] is BE transmitted CRC16.
CRC16 bad frames remain available here and **never enter the normal FIFO**.
The host recomputes CRCs, verifies flags/padding and rejects inconsistent records.

Status snapshot at offset 0x80 (latched on write of 0x80): `BS01`[4], state[1],
count[1], depth=8[1], record_size=64[1], started LE32, dropped-full LE32,
committed LE32, protocol_errors LE32, popped LE32, missed_sync LE32. State bits
are enabled=1, busy=2, ready=4, full=8, available=16. Counters saturate, except
sample_index wraps. Fresh START requires an empty queue. Busy sync events do
not restart captures and increment missed_sync, distinct from dropped-full.

## Test pattern and statistics

Payload bytes are BE batch[4] + BE sequence[4] + BE identity_crc32[4] + 20
deterministic bytes. identity_crc32 is Python zlib.crc32 of the first eight
bytes. Xorshift state starts `(batch ^ sequence ^ 0x9E3779B9) & 0xffffffff`;
for each remaining byte apply `x ^= x<<13; x ^= x>>17; x ^= x<<5` with uint32
truncation and use its low byte. Header sequence is `sequence & 255`.

Alignment requires 328 bits, valid Header CRC8, type=0x20, length=32, valid
identity CRC32, Header sequence agreement and exact identity in the attempted
batch ledger. Never match by nearest pattern, arrival order or timestamp.
Damaged identity and incomplete captures are retained and classified unaligned.
CRC is error detection with residual collision probability, not authentication.

- TX attempted is journalled before SEND. SEND OK means accepted only. TX must
  report FSK, fs=48000, no err/dmaerr/hde/hae, run initially zero, then PACKET
  run=1, then run=0 after expected duration. Duration is `(32+8*body_bytes)/100
  + 0.2` seconds; DATA body=41, TIME_BASE body=10. A 100 ms completion guard and
  final clean STATUS account for DMA rendering ahead of DAC. Missing transition,
  early/stuck run or transport errors mark the current attempt unresolved and
  abort. No SEND retries. Physical analog transmission still needs bench proof.
- A TIME_BASE is sent and confirmed at RX before enabling BER. It is setup,
  excluded from test denominators. Each DATA finishes/drains before next SEND.
- PER = `(confirmed completed TX - unique verified normal deliveries) / confirmed
  completed TX`. Unresolved transmissions are outside this denominator and
  reported separately; aborted runs are explicitly marked aborted. If an
  interruption leaves a completed TX's receive window unfinished, final PER is
  null and rx_windows_unfinished reports why: incomplete observation is not
  automatically counted as final packet loss.
- Payload BER = actual Hamming errors across all 256 Payload bits in each unique
  aligned complete capture / `(aligned completed captures * 256)`. Bad frame
  CRC is allowed. No captured frame and lost/partial bits are never imputed as
  bit errors. Zero denominators are JSON null.
- Comparison coverage = aligned completed captures / completed TX. Identity
  bytes passed validation, so BER is conditional and has selection bias. Report
  coverage, unaligned/partial records, missed sync, diagnostic drops and transport
  retries with BER; no extrapolation to uncaptured bits or preamble/sync BER.
- Effective throughput is verified delivered Payload bits / measured DATA trial
  elapsed time including serial command overhead and receive drain wait.
- Report delivered-without-capture, capture-without-delivery and completed without
  aligned capture independently. Missing diagnostic records are not proof of
  physical packet loss. BER HEALTH baseline/per-packet/final retains normal FPGA
  error flags and uint16 good/CRC counts (sequential register reads, no atomic
  latch; counters may saturate). RX STATUS baseline/final retains MCU serial
  overflow/errors. Sticky overflow flags are reported as flags, not counts; the
  unchanged normal FIFO has no exact overflow counter to invent.

## Execution and audit artifacts

The existing Windows Flutter host now contains a **BER 误码率** workspace and
uses the same TX/RX COM connections as communication, sweep and trace. It
implements the BER protocol in Dart and does not launch the Python CLI. Choose
two different ports and open both endpoints in the page. Begin with 3 frames,
amplitude 256 and a 2-second RX wait. Inspect-only status/head read does not
START, CLEAR or POP. Starting a trial deliberately STOPs and CLEARs the BER
diagnostic queue, establishes TIME_BASE, enables capture, then sends DATA
stop-and-wait. Do not run auto READ or other manual commands concurrently.
Window navigation, manual serial commands and auto READ are locked while the
trial is active. A timeout poisons both channels; close/reopen both before a new
trial. A stop request finishes status polling for any accepted SEND and leaves
an incomplete RX observation window out of final PER. Output defaults to
`exports/ber/ber_<timestamp>/raw.jsonl` and `report.json` relative to the
application working directory; the UI has open-folder/copy-path actions.

RX configuration preflight reads `ASK STATUS` before submitting a mode change.
`mode=FSK pending=0 error=0` proceeds without a redundant `MOD FSK` transaction.
An existing pending transaction is polled every 100 ms for at most 5 seconds;
after it settles, OOK is changed to FSK with a single MOD request and the same
bounded status polling. `pending=1 error=0` is accepted-but-deferred, not a
configuration rejection. `error=1` or invalid fields abort immediately. A 5-second
configuration timeout includes the last ASK response and a read-only FSK STATUS
reply (busy/sweep context); no setup/test SEND or BER CLEAR is issued before
successful preflight. A serial reply timeout still poisons the connection and
does not trigger command retransmission. This handshake correction applies to
both the Flutter host and the Python CLI.

Flutter also provides **双串口自检（不发包）**: five sequential TX/RX STATUS rounds,
400 ms between rounds, followed by read-only BER HEALTH. It does not issue SEND,
STOP, mode changes, CLEAR or POP. It therefore checks current serial command
responsiveness, not emission-time immunity or acoustic delivery. A serial timeout
reports the endpoint, command, operation phase and duration; ordinary commands
are not retried, both connections are invalidated, and manual reconnect is required.
Run self-check first after reconnect if a trial times out while TX is emitting.
The original 2-second response deadline is preserved; it is not bypassed to
declare successful transmission. The Windows serial library write-completion
boolean is checked instead of treating a false result as successful dispatch.
The TX firmware's `UART DIAG` is read-only and reports lifetime USART error and
receive-ring overflow counters, command-parse/line-length counters, the first 32
bytes of the last rejected printable command line as HEX, and DWT-measured maximum
`FskTx_RenderHalf` cycles vs the budget for one 115200-8-N-1 character. `dwt=0`
means the target did not provide the cycle counter; zero render cycles is then
unmeasured, not a pass. The timing scope is the render routine alone, not the
complete DMA ISR. These readings can distinguish ORE/ring/parser evidence, but a
zero UART error count cannot rule out host adapter/wiring or other races.
Additional fields: ore/fe/ne/pe count observations of those hardware error bits
in RX completion/error callbacks before rearming; rearmfail counts receive-IT
rearm failures, txerr counts response transmit
failures. Counters are uint32 boot-lifetime observations and may wrap; they are
not counts of lost bytes. `rearmfail` includes HAL_BUSY, which can also mean a
receive operation is already armed; it alone does not prove reception stopped.
Counters are observations, and they are
not atomically related to a particular failed command. `badlen` is the saturating
uint16 count of printable bytes observed on the rejected input line (before
backspace edits); `badcap` is the number of retained/parser-prefix bytes encoded
by `badhex`, at most 32. Non-printable bytes are filtered by the existing parser,
so this is not an oscilloscope or full binary wire capture. Long input retains
the legacy parser behavior and is additionally counted by lineovf. `schema=1`
identifies this diagnostic format, `opt=0/1` identifies unoptimized/optimized
compilation and hclk gives the cycle conversion clock. `renderlate` means only
that a measured render duration exceeded one character's computed budget, not
that an ORE definitely occurred. Normal STATUS format is unchanged.
The Flutter host requests UART DIAG after stopped/live self-checks and after the
TX cleanup STOP on a non-poisoned session; the snapshot is stored in
`tx_uart_diagnostics` in report.json. If an ERR COMMAND reply terminates a packet
poll, that reply itself does not desynchronize the text stream; cleanup can read
UART DIAG without retrying the rejected STATUS or SEND. The UI labels the data
`cmderr` (TX command rejected), not proof that a particular USART ORE occurred.

Flutter reports TIME_BASE setup separately from DATA accounting: setup_tx is
not_started/pending/complete/unresolved; setup_rx_confirmed tracks RX confirmation.
TIME_BASE's SEND ACK or a running TX STATUS is not completion evidence. If TX
STATUS times out during setup, setup_tx remains unresolved and DATA denominators
remain zero/null. Journals include command_error, failed_phase and command_failure;
empty serial polls are omitted, while all non-empty received chunks are retained.

From repository root (example ports only):

```powershell
python tools/ber/ber_test.py --tx COM9 --rx COM6 --count 100 --batch 0x12345678 --amp 256
python tools/ber/validate.py --host --rtl --target
python tools/ber/validate.py --quartus
```

CLI creates a unique trial folder under `_codex/ber_20261102` containing durable
`raw.jsonl` with command/raw receive chunks, normal/diagnostic observations and
per-attempt transitions, plus `report.json`. It never resets serial buffers per
command. Interrupt/error retains the partial ledger and sends best-effort STOP.
Use a new batch for each measurement session; no live hardware calls occur in
unit tests. The validation runner stages all artifacts in unique folders, uses
CubeIDE hard-float GCC, and never invokes the destructive legacy regression
script or a download/programmer. Hardware acceptance remains separate.

### BER command pacing correction (2026-11-16)

The automatic Flutter BER path and Python BER CLI now submit ASCII commands one
byte at a time with a requested 2 ms gap, keeping the port at 115200 8-N-1. This
accommodates the measured TX Debug O0 rendering interval (55,623 CPU cycles at
150 MHz) that can delay the lower-priority single-byte UART receiver. The old
burst STATUS path lost a terminator in a captured live TIME_BASE run, followed
by `STATUSSTOP` when cleanup appended STOP. This is a control transport change;
the data waveform, payload bytes, CRC rules and firmware are unchanged. Desktop
and USB scheduling are not a precise wire-timing guarantee; recheck target UART
counter deltas. `control_byte_gap_us=2000` identifies the corrected audit format.
Flutter/Python `serial_tx` events preserve the actual submitted byte sequence;
they establish driver submission, not target reception. Ordinary manual UI
commands keep their previous writer. SEND is still exactly once per attempt;
ACK is not completion, run/mode/DMA/HAL and final physical guard checks remain.

On an unresolved session only best-effort emergency stop is allowed. Before
STOP/BER STOP, the writer submits 160 backspaces (2 ms apart), a newline and
100 ms wait. Both current firmware line parsers accept backspace and bound their
input to <=160 bytes. This erases a retained command BEFORE adding a delimiter;
just prefixing newline could execute a pending SEND whose terminator was lost.
No ACK is trusted during this cleanup, and the session still requires reconnect.
This remains best effort under transport errors. A partial/ambiguous write aborts
without retries. Existing normal READ response semantics remain unchanged.

A new selfcheck clears old trial display state rather than showing a stale
TIME_BASE completion from a previous run. A TIME_BASE RX mismatch logs
`time_base_rx_check` and `time_base_unconfirmed`, expected/actual base_s and RX
health. It aborts before any DATA if a fresh matching TIME_BASE is unconfirmed.
Do not bypass this guard or treat an old received base as a new delivery.

### Independent serial STATUS check (2026-11-05)

`tools/ber/serial_check.py` bypasses Flutter and BER trial setup. Close Flutter
and other serial monitors first. It opens each specified port independently at
115200 8-N-1, sends only STATUS, and optionally TX UART DIAG after valid STATUS
responses. It never sends SEND/STOP or programs hardware. It does not explicitly
clear buffers between requests. Pyserial 3.5's Windows open path uses PurgeComm;
bytes from before opening the port are not preserved by this tool.
TX failure does not suppress the independent RX check. Each timeout terminates
requests on that port; late bytes are observed only, not attributed to a retry.
Raw HEX/byte representations, elapsed times, settings and results are saved in a
unique `serial_check_*` folder under `_codex/ber_20261102`. Opening a serial port
may affect adapter DTR/RTS even with explicit pre-open settings; defaults are off,
and `--dtr on`/`--rts on` allow an explicitly chosen setting (no automatic sweep).
No-byte timeout proves only that this PC did not receive bytes in the window,
not whether the MCU booted or received the command. Failed open/access denied is
not evidence of a firmware failure; release the port before testing.

As of 2026-11-16, the standalone Windows probe also records `windows_comm_error`
events and a `windows_driver` summary in report.json. A temporary, handle-filtered
observer captures the flags returned by pyserial's existing ClearCommError calls;
it makes no extra native calls or driver-setting changes. The observer is removed
when the port check ends. Use only in this sequential CLI, not as a GUI hook.
Each event includes flags/names and input/output queue sizes. `CE_OVERRUN=0x0002`
is distinct from `CE_RXOVER=0x0001`, STM32 ORE, and the MCU software ring overflow.
Repeated flag observations are NOT a count of lost characters and do not alone
identify a faulty adapter or driver. A detected driver error prevents subsequent
commands even if a syntactically valid reply was also recorded. Late bytes are
logged passively. Original timeouts/partial bytes remain in raw.jsonl. On other
platforms Windows observation is unavailable and normal raw serial checks remain.

```powershell
python C:/learning/short_trans/tools/ber/serial_check.py --list
python C:/learning/short_trans/tools/ber/serial_check.py --tx COM6 --rx COM29
python C:/learning/short_trans/tools/ber/serial_check.py --tx COM6 --rounds 5 --uart-diag
```


## Per-transmit-window stage evidence (schema 2, 2026-11-17)

The Flutter BER page now requires an RX FPGA reporting BER_SCHEMA=2 and the
matching RX MCU observer commands. Production FW_VERSION remains 0x14 (decimal
20); it is not a build identity. A capability rejection aborts before TIME_BASE
or DATA SEND. TX firmware and packet waveform are unchanged. Python's existing
BER CLI remains a legacy payload measurement path; it does not collect BO01.

The new `ber_observer` is passive. Its only outputs are diagnostic SPI bytes.
No counter, RAM, ARM/STOP/page command drives demodulator, symbol synchronizer,
parser, normal FIFO, reset, tuning, or existing trace controls. Parser and symbol
state outputs are combinational read-only taps, not new state transitions.

The host establishes TIME_BASE as before. Before each DATA SEND it issues one
`BER OBS ARM`, records the returned uint32 window ID, transmits exactly once,
finishes the existing receive wait/drain, then issues one `BER OBS STOP`.
STOP freezes all evidence. The host durably journals the summary and every event
page before allowing a new ARM to overwrite RAM. Evidence read/storage failure
aborts the trial before another SEND/ARM. A stopped/incomplete TX or receive
window is reported incomplete, never imputed as final packet loss. If serial
reply identity is unresolved, no ordinary evidence command is attempted; the
report explicitly marks evidence incomplete and emergency BER STOP freezes the
observer best-effort. A control ACK/CRC failure is never blindly retried.

### MCU commands

All commands use the existing paced 115200 8N1 text channel, LF terminated.
Binary hex replies retain CRC16/CCITT-FALSE over decoded bytes. The MCU requires
at least 256 bytes output capacity before executing any OBS command (main uses
384). Frozen summary and event pages are separately sought and read twice to
reject transient SPI disagreement; repeated identical corruption remains possible.

| Command | Reply | Meaning |
|---|---|---|
| `BER OBS INFO` | `OK BER OBS INFO <8hex> crc=HHHH` | BO01 capability, no state change |
| `BER OBS ARM` | `OK BER OBS ARM <8hex> crc=HHHH` | Fresh uint32 LE window ID; active/FSK-unavailable rejected |
| `BER OBS STOP` | `OK BER ACK` | Freeze active window; no receive-chain control |
| `BER OBS READ` | `OK BER OBS READ <192hex> crc=HHHH` | Frozen 96-byte summary |
| `BER OBS PAGE n` | `OK BER OBS PAGE <128hex> crc=HHHH` | Frozen 64-byte event page, n=0..15 |

BER STOP also freezes an active observer for cleanup. BER START/CLEAR do not
clear or rewrite the independent observation window. Old BR01/BS01/BH01 layouts
and legacy controls remain unchanged. MCU retains schema 1 support for legacy
commands, but refuses OBS commands on schema 1; the new Flutter trial deliberately
refuses to silently run without stage evidence.

### FPGA indirect map

No production addresses change. BER_CONTROL=0x4A adds exact values 0x10 ARM,
0x20 freeze and 0x80..0x8F select event page. BER_OFFSET=0x4D and BER_DATA=0x4E:
0..63 still BR01 head; 0x80..0x9F still latched BS01;
0xA0..0xFF now BO01 summary; 0x40..0x7F now selected observer page.
The last address in each region holds; seek before each read/retry. Writes of
0x80 to BER_OFFSET retain their original BS01 latch meaning, not page selection.
Unused event slots read zero without RAM initialization. Observer schema is 2.

### BO01 summary (96 bytes, little-endian)

0..3 BO01; 4..7 window ID; byte8 flags (active=1,frozen=2,chain_available=4,
events_overwritten=8); byte9 retained event count 0..32; byte10 next ring write
slot 0..31; byte11 event size 32; bytes12..15 elapsed clk_sys cycles.
Seventeen saturating uint32 counters at byte16, in order:

samples entering demod; FSK metrics; metrics above energy threshold; carrier
rises; preamble pulses; symbol-lock rises; sync pulses; header errors; length
errors; frame CRC errors; GOOD pulses; parser-busy lock/parse interruptions;
frame timeouts; symbol search timeouts; chain-unavailable cycles; recovered bits;
overwritten event records.

Bytes84..91 maximum 33-bit total energy as uint64. Bytes92..95 auxiliary sticky
flags: bit0 lock/parse interruption; bit1 lock pulse while not locked; bit2 chain
unavailable; bit3 I2S/CDC flag; bit4 clipping; bit5 parser-busy interruption;
bit6 header error; bit7 length error; bit8 CRC error; bit9 frame timeout; bit10
search timeout. Normal post-frame lock release may set auxiliary bit0 without a
failed packet; valid delivery takes precedence in classification.

### Event ring (32 records x 32 bytes)

Each record: uint32 elapsed cycles; uint32 event mask; uint64 33-bit total energy;
uint64 33-bit energy threshold; byte24 parser state; byte25 symbol state;
byte26 parser payload byte index; byte27 current hard decision (0/1); byte28
confidence; byte29 selected phase; byte30 signed two-bit timing correction stored
as 0..3; byte31 state flags. State flags bits0..7 are carrier, symbol lock,
parser busy, chain available, external error, above threshold, I2S flag, CDC flag.
Energy/threshold/phase/confidence are latest settled demod values at the event,
not a continuous waveform or analog voltage measurement.

Event mask bits0..21: carrier rise, carrier fall, lock rise, lock fall, preamble,
sync, header error, length error, CRC error, GOOD, lock/parse interruption,
frame timeout, search timeout, chain unavailable, external flag rise, clip rise,
window ARM, window end, header accepted, enter Payload, enter CRC, parser-state
change. Simultaneous events share one record. Parser state values:
0 search sync, 1 header, 2 Payload, 3 CRC-high, 4 CRC-low, 5 emit, 6 time field.
Symbol state: 0 carrier search, 1 preamble/phase search, 2 locked.
Payload byte index is parser-local progress; only interpret it in the matching
parser state, not as a verified count of correctly received bits.

Event cycles convert using clk_sys=30 MHz (cycles/30000 = milliseconds).
At full ring, next-write slot is the oldest record; the host reorders to time
order. Event overflow is explicit; counters retain the entire window even when
old event snapshots are overwritten. These counters and the ARM state include
any pre-existing carrier/lock during the window; counts need not equal packets.

### Interpretation and files

Classification identifies an observed stage range, not a proven physical cause.
All stage events belong to a host-designated transmit observation window, not
an authenticated RX packet. A false sync, interfering frame or noise may cause
events; use BR01 batch/sequence/identity and normal delivery for packet identity.
A missing stage is only a statement about this completed window. No-sync windows
still retain samples, metrics, above-threshold measurements, peak energy and
carrier/lock history. A GOOD without exact expected delivery is explicitly
ambiguous between other/stale frame identity and the readout chain.

The BER page adds a failed-window panel, optional successful windows, expandable
counts and timestamped events including parser/symbol state and Payload progress.
`raw.jsonl` stores ARM identity, raw summary/pages, decoded evidence and errors.
`report.json` stores stage_evidence/stage_diagnosis per attempt and a
failure_evidence list. `failure_evidence.json` separately exports that list.
Aborted/unfinished attempts remain visible. No unsynchronized/lost bits are
invented, and existing conditional Payload BER/PER/coverage formulas are unchanged.
