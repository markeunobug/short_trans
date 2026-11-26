#ifndef RX_BER_H
#define RX_BER_H
#include "fpga_rx_spi.h"
/* Nonzero only for BER commands. All replies are complete ASCII lines.
 * READ is seekable/non-destructive. POP requires an explicit capture ID. */
size_t rx_ber_command(fpga_rx_spi_t *device, const char *command,
                      uint8_t *output, size_t capacity);
uint16_t rx_ber_crc16(const uint8_t *data, size_t length);
#endif
