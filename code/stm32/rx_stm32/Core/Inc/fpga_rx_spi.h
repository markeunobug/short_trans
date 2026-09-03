#ifndef FPGA_RX_SPI_H
#define FPGA_RX_SPI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FPGA_RX_SPI_DEVICE_ID             0xA7U
#define FPGA_RX_SPI_PROTOCOL_VERSION      0x10U
#define FPGA_RX_SPI_MAX_PAYLOAD           64U
#define FPGA_RX_SPI_SNAPSHOT_WORDS        1024U
#define FPGA_RX_SPI_SNAPSHOT_BYTES        4096U
#define FPGA_RX_SPI_DEFAULT_TIMEOUT_MS    100U

typedef enum {
    FPGA_RX_SPI_OK = 0,
    FPGA_RX_SPI_EMPTY,
    FPGA_RX_SPI_INVALID_ARGUMENT,
    FPGA_RX_SPI_IO_ERROR,
    FPGA_RX_SPI_BAD_DEVICE,
    FPGA_RX_SPI_BAD_STATE,
    FPGA_RX_SPI_PROTOCOL_ERROR,
    FPGA_RX_SPI_BUFFER_TOO_SMALL
} fpga_rx_spi_result_t;

typedef fpga_rx_spi_result_t (*fpga_rx_spi_transfer_fn)(
    void *context,
    const uint8_t *tx_data,
    uint8_t *rx_data,
    size_t length,
    uint32_t timeout_ms);

typedef void (*fpga_rx_spi_chip_select_fn)(void *context, bool selected);

typedef struct {
    fpga_rx_spi_transfer_fn transfer;
    fpga_rx_spi_chip_select_fn chip_select;
    void *context;
    uint32_t timeout_ms;
} fpga_rx_spi_bus_t;

typedef struct {
    fpga_rx_spi_bus_t bus;
    uint8_t frame_open;
    uint8_t frame_length;
    uint8_t frame_bytes_read;
} fpga_rx_spi_t;

typedef struct {
    uint8_t device_id;
    uint8_t firmware_version;
    uint8_t status0;
    uint8_t error_flags;
    uint8_t frame_count;
    uint16_t rx_fifo_level;
    uint16_t good_frame_count;
    uint16_t crc_error_count;
} fpga_rx_spi_status_t;

typedef struct {
    uint8_t version;
    uint8_t frame_type;
    uint8_t sequence;
    uint8_t payload_length;
} fpga_rx_spi_frame_meta_t;

typedef struct {
    int16_t soft_metric;
    uint8_t energy_1600;
    uint8_t energy_2000;
    uint8_t confidence;
} fpga_rx_spi_diagnostics_t;

typedef struct {
    uint8_t sample_shift;
    uint8_t energy_margin_q4_4;
    uint8_t confidence_threshold;
    uint16_t noise_offset;
} fpga_rx_spi_tuning_t;

enum {
    FPGA_RX_REG_DEVICE_ID = 0x00U,
    FPGA_RX_REG_FW_VERSION = 0x01U,
    FPGA_RX_REG_STATUS0 = 0x02U,
    FPGA_RX_REG_ERROR_FLAGS = 0x03U,
    FPGA_RX_REG_FRAME_COUNT = 0x04U,
    FPGA_RX_REG_HEAD_VERSION_TYPE = 0x05U,
    FPGA_RX_REG_HEAD_SEQUENCE = 0x06U,
    FPGA_RX_REG_HEAD_LENGTH = 0x07U,
    FPGA_RX_REG_RX_FIFO_LEVEL_L = 0x08U,
    FPGA_RX_REG_RX_FIFO_LEVEL_H = 0x09U,
    FPGA_RX_REG_GOOD_COUNT_L = 0x0AU,
    FPGA_RX_REG_GOOD_COUNT_H = 0x0BU,
    FPGA_RX_REG_CRC_ERROR_L = 0x0CU,
    FPGA_RX_REG_CRC_ERROR_H = 0x0DU,
    FPGA_RX_REG_CONTROL = 0x10U,
    FPGA_RX_REG_SAMPLE_SHIFT = 0x11U,
    FPGA_RX_REG_ENERGY_MARGIN = 0x12U,
    FPGA_RX_REG_CONF_THRESHOLD = 0x13U,
    FPGA_RX_REG_NOISE_OFFSET_L = 0x14U,
    FPGA_RX_REG_NOISE_OFFSET_H = 0x15U,
    FPGA_RX_REG_LAST_SOFT_L = 0x20U,
    FPGA_RX_REG_LAST_SOFT_H = 0x21U,
    FPGA_RX_REG_LAST_ENERGY_0 = 0x22U,
    FPGA_RX_REG_LAST_ENERGY_1 = 0x23U,
    FPGA_RX_REG_LAST_CONFIDENCE = 0x24U,
    FPGA_RX_REG_SNAPSHOT_COUNT_L = 0x30U,
    FPGA_RX_REG_SNAPSHOT_COUNT_H = 0x31U,
    FPGA_RX_REG_RX_DATA = 0x40U,
    FPGA_RX_REG_SNAPSHOT_DATA = 0x41U
};

enum {
    FPGA_RX_STATUS_ADC_READY = (1U << 7),
    FPGA_RX_STATUS_ADC_ERROR = (1U << 6),
    FPGA_RX_STATUS_CARRIER = (1U << 5),
    FPGA_RX_STATUS_SYMBOL_LOCK = (1U << 4),
    FPGA_RX_STATUS_FRAME_READY = (1U << 3),
    FPGA_RX_STATUS_SNAPSHOT_AVAILABLE = (1U << 2),
    FPGA_RX_STATUS_SNAPSHOT_BUSY = (1U << 1),
    FPGA_RX_STATUS_FRAME_INGRESS = (1U << 0)
};

enum {
    FPGA_RX_ERROR_I2C = (1U << 7),
    FPGA_RX_ERROR_I2S = (1U << 6),
    FPGA_RX_ERROR_CDC = (1U << 5),
    FPGA_RX_ERROR_FIFO_OVERFLOW = (1U << 4),
    FPGA_RX_ERROR_PROTOCOL = (1U << 3),
    FPGA_RX_ERROR_SPI_TRANSACTION = (1U << 2),
    FPGA_RX_ERROR_SNAPSHOT_EMPTY = (1U << 1)
};

enum {
    FPGA_RX_CONTROL_CLEAR_ERRORS = (1U << 0),
    FPGA_RX_CONTROL_ADC_REINIT = (1U << 1),
    FPGA_RX_CONTROL_SNAPSHOT_START = (1U << 2),
    FPGA_RX_CONTROL_POP_FRAME = (1U << 3),
    FPGA_RX_CONTROL_DROP_FRAME = (1U << 4)
};

fpga_rx_spi_result_t fpga_rx_spi_init(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_bus_t *bus);

fpga_rx_spi_result_t fpga_rx_spi_probe(
    fpga_rx_spi_t *device,
    uint8_t *firmware_version);

fpga_rx_spi_result_t fpga_rx_spi_read_registers(
    fpga_rx_spi_t *device,
    uint8_t address,
    uint8_t *data,
    size_t length);

fpga_rx_spi_result_t fpga_rx_spi_write_registers(
    fpga_rx_spi_t *device,
    uint8_t address,
    const uint8_t *data,
    size_t length);

fpga_rx_spi_result_t fpga_rx_spi_read_status(
    fpga_rx_spi_t *device,
    fpga_rx_spi_status_t *status);

fpga_rx_spi_result_t fpga_rx_spi_read_diagnostics(
    fpga_rx_spi_t *device,
    fpga_rx_spi_diagnostics_t *diagnostics);

fpga_rx_spi_result_t fpga_rx_spi_read_tuning(
    fpga_rx_spi_t *device,
    fpga_rx_spi_tuning_t *tuning);

fpga_rx_spi_result_t fpga_rx_spi_write_tuning(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_tuning_t *tuning);

fpga_rx_spi_result_t fpga_rx_spi_begin_frame(
    fpga_rx_spi_t *device,
    fpga_rx_spi_frame_meta_t *metadata);

fpga_rx_spi_result_t fpga_rx_spi_read_payload(
    fpga_rx_spi_t *device,
    uint8_t *data,
    size_t requested,
    size_t *bytes_read);

fpga_rx_spi_result_t fpga_rx_spi_pop_frame(fpga_rx_spi_t *device);
fpga_rx_spi_result_t fpga_rx_spi_drop_frame(fpga_rx_spi_t *device);

fpga_rx_spi_result_t fpga_rx_spi_clear_errors(fpga_rx_spi_t *device);
fpga_rx_spi_result_t fpga_rx_spi_adc_reinitialize(fpga_rx_spi_t *device);

fpga_rx_spi_result_t fpga_rx_spi_snapshot_start(fpga_rx_spi_t *device);
fpga_rx_spi_result_t fpga_rx_spi_snapshot_word_count(
    fpga_rx_spi_t *device,
    uint16_t *word_count);
fpga_rx_spi_result_t fpga_rx_spi_snapshot_ready(
    fpga_rx_spi_t *device,
    bool *ready,
    bool *busy);
fpga_rx_spi_result_t fpga_rx_spi_snapshot_read_bytes(
    fpga_rx_spi_t *device,
    uint8_t *data,
    size_t length);
fpga_rx_spi_result_t fpga_rx_spi_snapshot_read_all(
    fpga_rx_spi_t *device,
    int32_t samples[FPGA_RX_SPI_SNAPSHOT_WORDS]);

#if defined(FPGA_RX_SPI_ENABLE_STM32_HAL)
#include "stm32g4xx_hal.h"

typedef struct {
    SPI_HandleTypeDef *hspi;
    GPIO_TypeDef *nss_port;
    uint16_t nss_pin;
} fpga_rx_spi_hal_context_t;

fpga_rx_spi_result_t fpga_rx_spi_init_hal(
    fpga_rx_spi_t *device,
    fpga_rx_spi_hal_context_t *hal_context,
    SPI_HandleTypeDef *hspi,
    GPIO_TypeDef *nss_port,
    uint16_t nss_pin,
    uint32_t timeout_ms);
#endif

#ifdef __cplusplus
}
#endif

#endif
