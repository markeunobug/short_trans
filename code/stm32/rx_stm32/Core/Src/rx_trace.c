#include "rx_trace.h"
#include "rx_command_text.h"
#include <stdio.h>
#include <string.h>

#define TRACE_BLOCK_MAX 192U
static size_t text(uint8_t *out, size_t cap, const char *message)
{
    size_t n = strlen(message);
    if (n > cap) return 0;
    memcpy(out, message, n);
    return n;
}
static uint16_t u16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static void put16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
}
uint16_t rx_trace_crc16(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xffffU;
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)((uint16_t)data[i] << 8);
        for (unsigned j = 0; j < 8; ++j)
            crc = (uint16_t)((crc & 0x8000U) ? ((uint32_t)crc << 1) ^ 0x1021U : (uint32_t)crc << 1);
    }
    return crc;
}
static size_t encode(const uint8_t *data, size_t length, uint8_t *out)
{
    size_t used = 2, code_at = 1;
    uint8_t code = 1;
    out[0] = 0;
    for (size_t i = 0; i < length; ++i) {
        if (data[i] == 0) {
            out[code_at] = code; code_at = used++; code = 1;
        } else {
            out[used++] = data[i];
            if (++code == 0xffU) {
                out[code_at] = code; code_at = used++; code = 1;
            }
        }
    }
    out[code_at] = code; out[used++] = 0;
    return used;
}
size_t rx_trace_command(fpga_rx_spi_t *device, const char *command,
                        uint8_t *output, size_t capacity)
{
    uint8_t probe[2], status[9], config[3], control;
    uint32_t args[3];
    uint8_t packet[12U + TRACE_BLOCK_MAX];
    size_t length;
    int formatted;
    if (command == NULL || output == NULL || capacity < 256U) return 0;
    if (strncmp(command, "TRACE ", 6) != 0) return 0;
    if (fpga_rx_spi_probe(device, &probe[0]) != FPGA_RX_SPI_OK)
        return text(output, capacity, "ERR TRACE SPI\r\n");
    if ((probe[0] != 0x13U) && (probe[0] != 0x14U))
        return text(output, capacity, "ERR TRACE UNSUPPORTED\r\n");
    if (fpga_rx_spi_read_registers(device, 0x32U, &probe[1], 1) != FPGA_RX_SPI_OK)
        return text(output, capacity, "ERR TRACE SPI\r\n");
    if (probe[1] != 0xd1U)
        return text(output, capacity, "ERR TRACE UNSUPPORTED\r\n");
    if (fpga_rx_spi_read_registers(device, 0x37U, status, sizeof status) != FPGA_RX_SPI_OK)
        return text(output, capacity, "ERR TRACE SPI\r\n");
    if (strcmp(command, "TRACE STATUS") == 0) {
        formatted = snprintf((char *)output, capacity,
            "OK TRACE status=%u id=%u count=%u trigger=%u depth=512\r\n",
            status[0], u16(status+5), u16(status+1), u16(status+7));
        return (formatted > 0 && (size_t)formatted < capacity) ? (size_t)formatted : 0;
    }
    if (strncmp(command, "TRACE ARM ", 10) == 0) {
        if (!rx_command_parse_u32_fields(command+10, args, 2) ||
            args[0] == 0 || args[0] > 127 || args[1] > 511 || (status[0] & 1U))
            return text(output, capacity, "ERR TRACE ARG_OR_BUSY\r\n");
        config[0] = (uint8_t)args[0]; put16(config+1, (uint16_t)args[1]);
        if (fpga_rx_spi_write_registers(device, 0x34U, config, 3) != FPGA_RX_SPI_OK)
            return text(output, capacity, "ERR TRACE SPI\r\n");
        control = 1;
    } else if (strcmp(command, "TRACE TRIGGER") == 0) {
        if (!(status[0] & 1U)) return text(output, capacity, "ERR TRACE NOT_ARMED\r\n");
        control = 2;
    } else if (strcmp(command, "TRACE STOP") == 0) {
        control = 4;
    } else if (strncmp(command, "TRACE READ ", 11) == 0) {
        if (!rx_command_parse_u32_fields(command+11, args, 3) ||
            !(status[0] & 4U) || args[0] != u16(status+5) ||
            args[2] == 0 || args[2] > TRACE_BLOCK_MAX ||
            args[1] > 24640U || args[1] + args[2] > 64U + (uint32_t)u16(status+1)*48U)
            return text(output, capacity, "ERR TRACE RANGE_OR_ID\r\n");
        put16(config, (uint16_t)args[1]);
        if (fpga_rx_spi_write_registers(device, 0x3aU, config, 2) != FPGA_RX_SPI_OK)
            return text(output, capacity, "ERR TRACE SPI\r\n");
        memcpy(packet, "DTB1", 4);
        put16(packet+4, (uint16_t)args[0]); put16(packet+6, (uint16_t)args[1]);
        put16(packet+8, (uint16_t)args[2]);
        if (fpga_rx_spi_read_registers(device, FPGA_RX_REG_TRACE_DATA, packet+10, args[2]) != FPGA_RX_SPI_OK)
            return text(output, capacity, "ERR TRACE SPI\r\n");
        length = 10U + args[2];
        put16(packet+length, rx_trace_crc16(packet, length));
        return encode(packet, length+2U, output);
    } else return text(output, capacity, "ERR TRACE COMMAND\r\n");
    if (fpga_rx_spi_write_registers(device, 0x33U, &control, 1) != FPGA_RX_SPI_OK)
        return text(output, capacity, "ERR TRACE SPI\r\n");
    if (control == 1) {
        if (fpga_rx_spi_read_registers(device, 0x37U, status, 1) != FPGA_RX_SPI_OK)
            return text(output, capacity, "ERR TRACE SPI\r\n");
        /* A post=0 event can freeze before this readback completes. */
        if (!(status[0] & 5U) || (status[0] & 8U))
            return text(output, capacity, "ERR TRACE UNAVAILABLE\r\n");
    }
    return text(output, capacity, "OK TRACE ACK\r\n");
}
