# RS485A Half-Duplex Control

- Transceiver: SN65HVD11.
- Direction GPIO: `PA7 / RS485A_EN`.
- Receive: PA7 low, `/RE` enabled and `DE` disabled.
- Transmit: PA7 high, `/RE` disabled and `DE` enabled.
- UART: USART1, 115200-8-N-1.
- Schematic wiring requires USART1 TX/RX swap: PC4 receives from transceiver R,
  and PC5 transmits to transceiver D.

`rs485_half_duplex_transmit()` raises PA7 before calling the blocking HAL UART
transmit function. `HAL_UART_Transmit()` waits for the final transmission
complete flag, after which the wrapper returns PA7 low so the bus immediately
returns to receive mode. The receive wrapper always forces PA7 low first.

The module intentionally does not define an RS485 application frame. FPGA
payload forwarding must be added only after the host-side framing is frozen.

## Diagnostic application commands

The checked-in firmware receives ASCII command lines using the USART1
interrupt and a 128-byte ring buffer. Terminate each command with CR or LF.

```text
PING
STATUS
READ
HELP
```

- `PING` returns `OK PONG` and verifies both RS485 directions.
- `STATUS` reports FPGA connection state, firmware version, last SPI result,
  last frame metadata, UART errors and receive-ring overflows.
- `READ` returns the most recently received FPGA payload as hexadecimal.
- `HELP` lists the available diagnostic commands.

This command set is a board bring-up interface, not the final RS485 transport
protocol.

The application waits 1 ms after receiving a line terminator before enabling
the driver. This prevents a response from colliding with the LF byte of a CRLF
command or with a remote driver's turn-off interval.
