#include "rx_ber.h"
#include "rx_command_text.h"
#include <string.h>

#define BER_ID 0x49U
#define BER_CONTROL 0x4AU
#define BER_OFFSET 0x4DU
#define BER_SCHEMA 0x4FU
#define BER_RECORD_SIZE 64U
#define BER_STATUS_SIZE 32U

uint16_t rx_ber_crc16(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xFFFFU;
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)((uint16_t)data[i] << 8);
        for (unsigned j = 0; j < 8; ++j)
            crc = (uint16_t)((crc & 0x8000U) ? ((uint32_t)crc << 1) ^ 0x1021U : (uint32_t)crc << 1);
    }
    return crc;
}
static size_t reply(uint8_t *out, size_t cap, const char *s)
{
    size_t n = strlen(s);
    if (n >= cap) return 0;
    memcpy(out, s, n + 1U);
    return n;
}
static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static fpga_rx_spi_result_t seek_read(fpga_rx_spi_t *dev, uint8_t offset,
                                     uint8_t *out, size_t n)
{
    fpga_rx_spi_result_t result = fpga_rx_spi_write_registers(dev, BER_OFFSET, &offset, 1U);
    if (result != FPGA_RX_SPI_OK) return result;
    return fpga_rx_spi_read_registers(dev, FPGA_RX_REG_BER_DATA, out, n);
}
static int read_status(fpga_rx_spi_t *dev, uint8_t *status)
{
    return seek_read(dev, 0x80U, status, BER_STATUS_SIZE) == FPGA_RX_SPI_OK &&
           memcmp(status, "BS01", 4U) == 0 && status[6] == 8U && status[7] == 64U &&
           status[5] <= 8U;
}
static size_t hex_reply(uint8_t *out, size_t cap, const char *prefix,
                        const uint8_t *data, size_t n)
{
    static const char digits[] = "0123456789ABCDEF";
    size_t used = strlen(prefix);
    uint16_t crc = rx_ber_crc16(data, n);
    if (used + n * 2U + 12U >= cap) return 0;
    memcpy(out, prefix, used);
    for (size_t i = 0; i < n; ++i) {
        out[used++] = (uint8_t)digits[data[i] >> 4];
        out[used++] = (uint8_t)digits[data[i] & 15U];
    }
    memcpy(out + used, " crc=", 5U); used += 5U;
    for (unsigned i = 0; i < 4; ++i)
        out[used++] = (uint8_t)digits[(crc >> (12U - i * 4U)) & 15U];
    out[used++] = '\r'; out[used++] = '\n'; out[used] = 0;
    return used;
}
/* Schema 2 observer controls never address production demod/FIFO registers.
 * Frozen snapshots are independently sought/read twice; SPI has no wire CRC. */
static size_t observer_command(fpga_rx_spi_t *dev, const char *command,
                               uint8_t *out, size_t capacity)
{
    uint8_t data[96], verify[96], value;
    uint32_t page;
    if (strcmp(command, "BER OBS INFO") == 0)
        return hex_reply(out, capacity, "OK BER OBS INFO ", (const uint8_t *)"BO01", 4U);
    if (strncmp(command, "BER OBS PAGE ", 13U) == 0) {
        if (!rx_command_parse_u32_fields(command + 13U, &page, 1U) || page > 15U)
            return reply(out, capacity, "ERR BER ARG\r\n");
    } else if (strcmp(command, "BER OBS ARM") != 0 &&
               strcmp(command, "BER OBS STOP") != 0 &&
               strcmp(command, "BER OBS READ") != 0) {
        return reply(out, capacity, "ERR BER COMMAND\r\n");
    }
    if (seek_read(dev, 0xA0U, data, 16U) != FPGA_RX_SPI_OK ||
        memcmp(data, "BO01", 4U) != 0)
        return reply(out, capacity, "ERR BER SPI\r\n");
    if (strcmp(command, "BER OBS ARM") == 0) {
        uint32_t before = get32(data + 4U);
        if (fpga_rx_spi_read_registers(dev, 0x4BU, &value, 1U) != FPGA_RX_SPI_OK)
            return reply(out, capacity, "ERR BER SPI\r\n");
        if ((data[8] & 1U) != 0U || (value & 16U) == 0U)
            return reply(out, capacity, "ERR BER OBS BUSY\r\n");
        value = 0x10U;
        if (fpga_rx_spi_write_registers(dev, BER_CONTROL, &value, 1U) != FPGA_RX_SPI_OK ||
            seek_read(dev, 0xA0U, data, 16U) != FPGA_RX_SPI_OK)
            return reply(out, capacity, "ERR BER SPI\r\n");
        if ((data[8] & 1U) == 0U || get32(data + 4U) != before + 1U)
            return reply(out, capacity, "ERR BER OBS CONTROL\r\n");
        return hex_reply(out, capacity, "OK BER OBS ARM ", data + 4U, 4U);
    }
    if (strcmp(command, "BER OBS STOP") == 0) {
        if ((data[8] & 1U) == 0U)
            return reply(out, capacity, "ERR BER OBS BUSY\r\n");
        value = 0x20U;
        if (fpga_rx_spi_write_registers(dev, BER_CONTROL, &value, 1U) != FPGA_RX_SPI_OK ||
            seek_read(dev, 0xA0U, data, 16U) != FPGA_RX_SPI_OK)
            return reply(out, capacity, "ERR BER SPI\r\n");
        return reply(out, capacity, (data[8] & 3U) == 2U ?
                     "OK BER ACK\r\n" : "ERR BER OBS CONTROL\r\n");
    }
    if ((data[8] & 3U) != 2U)
        return reply(out, capacity, "ERR BER OBS BUSY\r\n");
    if (strcmp(command, "BER OBS READ") == 0) {
        if (seek_read(dev, 0xA0U, data, sizeof data) != FPGA_RX_SPI_OK ||
            seek_read(dev, 0xA0U, verify, sizeof verify) != FPGA_RX_SPI_OK ||
            memcmp(data, verify, sizeof data) != 0)
            return reply(out, capacity, "ERR BER SPI\r\n");
        return hex_reply(out, capacity, "OK BER OBS READ ", data, sizeof data);
    }
    if (strncmp(command, "BER OBS PAGE ", 13U) != 0 ||
        !rx_command_parse_u32_fields(command + 13U, &page, 1U) || page > 15U)
        return reply(out, capacity, "ERR BER ARG\r\n");
    value = (uint8_t)(0x80U + page);
    if (fpga_rx_spi_write_registers(dev, BER_CONTROL, &value, 1U) != FPGA_RX_SPI_OK ||
        seek_read(dev, 0x40U, data, 64U) != FPGA_RX_SPI_OK ||
        seek_read(dev, 0x40U, verify, 64U) != FPGA_RX_SPI_OK ||
        memcmp(data, verify, 64U) != 0)
        return reply(out, capacity, "ERR BER SPI\r\n");
    return hex_reply(out, capacity, "OK BER OBS PAGE ", data, 64U);
}
size_t rx_ber_command(fpga_rx_spi_t *dev, const char *command,
                      uint8_t *out, size_t capacity)
{
    uint8_t status[BER_STATUS_SIZE], record[BER_RECORD_SIZE], verify[BER_RECORD_SIZE], id, schema, control;
    uint32_t requested_id = 0U;
    uint32_t before_popped;
    int is_pop, is_observer;
    if (command == NULL || out == NULL || capacity == 0U) return 0;
    if (strcmp(command, "BER") != 0 && strncmp(command, "BER ", 4U) != 0) return 0;
    is_observer = strncmp(command, "BER OBS ", 8U) == 0;
    /* Never execute controls unless their complete reply can fit. */
    if (capacity < (is_observer ? 256U : 192U)) return reply(out, capacity, "ERR BER CAPACITY\r\n");
    is_pop = strncmp(command, "BER POP ", 8U) == 0;
    if (strcmp(command, "BER STATUS") != 0 && strcmp(command, "BER READ") != 0 &&
        strcmp(command, "BER HEALTH") != 0 &&
        strcmp(command, "BER START") != 0 && strcmp(command, "BER STOP") != 0 &&
        strcmp(command, "BER CLEAR") != 0 && !is_pop && !is_observer)
        return reply(out, capacity, "ERR BER COMMAND\r\n");
    if (is_pop && !rx_command_parse_u32_fields(command + 8U, &requested_id, 1U))
        return reply(out, capacity, "ERR BER ARG\r\n");
    /* A positive peripheral signature, not a changed production FW_VERSION. */
    if (fpga_rx_spi_read_registers(dev, BER_ID, &id, 1U) != FPGA_RX_SPI_OK ||
        fpga_rx_spi_read_registers(dev, BER_SCHEMA, &schema, 1U) != FPGA_RX_SPI_OK)
        return reply(out, capacity, "ERR BER SPI\r\n");
    if (id != 0xB1U || (schema != 1U && schema != 2U) || (is_observer && schema != 2U))
        return reply(out, capacity, "ERR BER UNSUPPORTED\r\n");
    if (is_observer) return observer_command(dev, command, out, capacity);
    if (strcmp(command, "BER HEALTH") == 0) {
        /* Read-only production diagnostics; no frame open/read/pop side effect.
         * These changing counters are sequential samples, not an atomic latch. */
        memset(record, 0, 20U);
        memcpy(record, "BH01", 4U);
        if (fpga_rx_spi_read_registers(dev, 0U, record + 4U, 14U) != FPGA_RX_SPI_OK)
            return reply(out, capacity, "ERR BER SPI\r\n");
        return hex_reply(out, capacity, "OK BER HEALTH ", record, 20U);
    }
    if (!read_status(dev, status)) return reply(out, capacity, "ERR BER SPI\r\n");
    before_popped = get32(status + 24U);
    if (strcmp(command, "BER STATUS") == 0)
        return hex_reply(out, capacity, "OK BER STATUS ", status, sizeof status);
    if (strcmp(command, "BER READ") == 0 || is_pop) {
        if (status[5] == 0U) return reply(out, capacity, "OK BER EMPTY\r\n");
        if (seek_read(dev, 0U, record, sizeof record) != FPGA_RX_SPI_OK)
            return reply(out, capacity, "ERR BER SPI\r\n");
        /* SPI has no wire CRC. Head is immutable until explicit POP, so a
         * second independently sought read detects transient bus corruption. */
        if (seek_read(dev, 0U, verify, sizeof verify) != FPGA_RX_SPI_OK ||
            memcmp(record, verify, sizeof record) != 0)
            return reply(out, capacity, "ERR BER SPI\r\n");
        if (memcmp(record, "BR01", 4U) != 0)
            return reply(out, capacity, "ERR BER RECORD\r\n");
        if (!is_pop) return hex_reply(out, capacity, "OK BER RECORD ", record, sizeof record);
        if (get32(record + 4U) != requested_id)
            return reply(out, capacity, "ERR BER ID\r\n");
        control = 8U;
    } else if (strcmp(command, "BER START") == 0) {
        if ((status[4] & 3U) != 0U || status[5] != 0U || (status[4] & 16U) == 0U)
            return reply(out, capacity, "ERR BER BUSY_OR_UNAVAILABLE\r\n");
        control = 1U;
    } else if (strcmp(command, "BER CLEAR") == 0) {
        if ((status[4] & 3U) != 0U) return reply(out, capacity, "ERR BER BUSY\r\n");
        control = 4U;
    } else control = 2U;
    if (fpga_rx_spi_write_registers(dev, BER_CONTROL, &control, 1U) != FPGA_RX_SPI_OK)
        return reply(out, capacity, "ERR BER SPI\r\n");
    if (!read_status(dev, status)) return reply(out, capacity, "ERR BER SPI\r\n");
    if ((control == 1U && (status[4] & 1U) == 0U) ||
        (control == 2U && (status[4] & 1U) != 0U) ||
        (control == 4U && ((status[4] & 3U) != 0U || status[5] != 0U)) ||
        (control == 8U && (before_popped == UINT32_MAX ||
                          get32(status + 24U) != before_popped + 1U)))
        return reply(out, capacity, "ERR BER CONTROL\r\n");
    return reply(out, capacity, "OK BER ACK\r\n");
}
