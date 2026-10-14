#ifndef RX_TRACE_H
#define RX_TRACE_H
#include "fpga_rx_spi.h"
/* Zero means not a TRACE command. Otherwise output is a complete ASCII line
 * or zero-delimited COBS binary response, ready for a single RS485 transfer. */
size_t rx_trace_command(fpga_rx_spi_t *device, const char *command,
                        uint8_t *output, size_t capacity);
uint16_t rx_trace_crc16(const uint8_t *data, size_t length);
#endif
