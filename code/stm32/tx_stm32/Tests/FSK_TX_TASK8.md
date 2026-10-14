# STM32 PA4 2FSK Test Transmitter

## Runtime

- Output: `PA4 / DAC1_OUT1`
- DAC trigger: TIM4 update at exactly 48 kHz
- DMA: circular, 960 samples split into two 480-sample halves
- DMA width: 16-bit memory samples, 32-bit DAC peripheral writes
- Bit mapping: `0 = 1.7 kHz`, `1 = 1.9 kHz`
- Symbol duration: 10 ms at 100 bit/s
- Idle DAC code: 2048
- Default amplitude: 256 DAC codes; valid range is 0 to 2047

`FskTx_Init()` recalculates TIM4 from the live APB1 timer clock. With the
current 150 MHz clock tree it uses PSC=4 and ARR=624. The checked-in `.ioc`,
generated initialization and runtime validation all use circular DAC DMA so
the half/full callbacks continuously refill one 10 ms symbol per half-buffer.

## UART Commands

USART1 remains 115200-8-N-1. Commands are ASCII lines terminated by CR or LF.
The board interface is half-duplex RS485A: PA7 is low while receiving and high
only while transmitting a command response. USART1 TX/RX swap is enabled to
match the board wiring (PC4 receives from transceiver R, PC5 drives D). The
firmware is silent after reset and responds only after a command is received.
A 1 ms turnaround guard is applied after the command terminator before PA7 is
raised, allowing a remote transmitter to finish CRLF and release the bus.

```text
HELP
AMP 256
PAYLOAD 010203A5
PAYLOAD -
META 1 0 7
MODE SILENCE
MODE TONE1700
MODE TONE1900
MODE ALT
MODE PRBS
MODE PACKET
SEND
STOP
STATUS
```

`AMP`, `PAYLOAD`, `META`, and `MODE` update configuration. `SEND` starts the
selected mode. Tone, alternating, and PRBS modes continue until `STOP`.
PACKET is one shot and includes 100 ms midpoint output before and after the
air frame.

PACKET uses the searched and frozen 16-bit sync word `0x06B7`, shared with the
RX FPGA protocol implementation.

When no UART adapter is available, `build_fsk_tx.ps1` can create a temporary
bench image which starts a waveform immediately after reset:

```powershell
.\Tests\build_fsk_tx.ps1 -BootMode Alt -KeepBuildDirectory
```

`BootMode` accepts `None`, `Tone1700`, `Tone1900`, or `Alt`. The default is
`None`, so production behavior remains UART-controlled and starts at midpoint.

## Packet Body

The air frame is MSB first:

```text
0xAAAA | sync word | 4-byte header | 0..64-byte payload | CRC16 high | CRC16 low
```

Header byte 0 is `(version << 4) | frame_type`, byte 1 is sequence, byte 2 is
payload length, and byte 3 is CRC-8/ATM over bytes 0 to 2. CRC-16/CCITT-FALSE
covers the complete four-byte header and payload.

## Bench Checks Still Required

1. Confirm TIM4 DAC updates at 48.000 kSPS.
2. Confirm `TONE1700` and `TONE1900` frequencies on PA4.
3. Confirm ALT changes frequency every 10 ms without a midpoint or phase step.
4. Sweep amplitude from a low value while checking receiver ADC clipping.
5. Verify 0, 16, 32, and 64-byte packet timing and received payload equality
   using the frozen `0x06B7` sync word.
