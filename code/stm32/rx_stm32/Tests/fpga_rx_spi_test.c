#include "fpga_rx_spi.h"

#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            (void)fprintf(stderr, "FAIL:%d: %s\n", __LINE__, #condition);      \
            return 1;                                                           \
        }                                                                       \
    } while (0)

typedef struct {
    uint8_t registers[128];
    uint8_t selected;
    uint8_t fail_next_transfer;
    uint8_t payload[FPGA_RX_SPI_MAX_PAYLOAD];
    uint8_t payload_length;
    uint8_t payload_offset;
    int32_t snapshot[FPGA_RX_SPI_SNAPSHOT_WORDS];
    uint16_t snapshot_words;
    uint16_t snapshot_byte_offset;
    size_t snapshot_data_bytes_read;
    unsigned select_count;
    unsigned deselect_count;
    unsigned adc_reinit_count;
    uint8_t bump_generation_once;
} mock_fpga_t;

static void mock_update_dynamic_registers(mock_fpga_t *mock)
{
    uint16_t fifo_level = (uint16_t)(mock->payload_length - mock->payload_offset);

    mock->registers[FPGA_RX_REG_FRAME_COUNT] =
        (mock->payload_length != 0U ||
         mock->registers[FPGA_RX_REG_HEAD_LENGTH] == 0U) ?
        mock->registers[FPGA_RX_REG_FRAME_COUNT] : 0U;
    mock->registers[FPGA_RX_REG_RX_FIFO_LEVEL_L] = (uint8_t)fifo_level;
    mock->registers[FPGA_RX_REG_RX_FIFO_LEVEL_H] =
        (uint8_t)((fifo_level >> 8) & 0x01U);
    mock->registers[FPGA_RX_REG_SNAPSHOT_COUNT_L] =
        (uint8_t)mock->snapshot_words;
    mock->registers[FPGA_RX_REG_SNAPSHOT_COUNT_H] =
        (uint8_t)((mock->snapshot_words >> 8) & 0x07U);

    if (mock->snapshot_words != 0U) {
        mock->registers[FPGA_RX_REG_STATUS0] |=
            FPGA_RX_STATUS_SNAPSHOT_AVAILABLE;
    } else {
        mock->registers[FPGA_RX_REG_STATUS0] &=
            (uint8_t)~FPGA_RX_STATUS_SNAPSHOT_AVAILABLE;
    }
}

static void mock_control_write(mock_fpga_t *mock, uint8_t value)
{
    if ((value & FPGA_RX_CONTROL_CLEAR_ERRORS) != 0U) {
        mock->registers[FPGA_RX_REG_ERROR_FLAGS] = 0U;
    }
    if ((value & FPGA_RX_CONTROL_ADC_REINIT) != 0U) {
        ++mock->adc_reinit_count;
    }
    if ((value & FPGA_RX_CONTROL_SNAPSHOT_START) != 0U) {
        size_t index;
        for (index = 0U; index < FPGA_RX_SPI_SNAPSHOT_WORDS; ++index) {
            mock->snapshot[index] = (int32_t)(0x80000000UL + (uint32_t)index);
        }
        mock->snapshot_words = FPGA_RX_SPI_SNAPSHOT_WORDS;
        mock->snapshot_byte_offset = 0U;
        mock->snapshot_data_bytes_read = 0U;
    }
    if ((value & FPGA_RX_CONTROL_POP_FRAME) != 0U) {
        if ((mock->registers[FPGA_RX_REG_FRAME_COUNT] != 0U) &&
            (mock->payload_offset == mock->payload_length)) {
            mock->registers[FPGA_RX_REG_FRAME_COUNT] = 0U;
            mock->registers[FPGA_RX_REG_STATUS0] &=
                (uint8_t)~FPGA_RX_STATUS_FRAME_READY;
        } else {
            mock->registers[FPGA_RX_REG_ERROR_FLAGS] |= FPGA_RX_ERROR_PROTOCOL;
        }
    }
    if ((value & FPGA_RX_CONTROL_DROP_FRAME) != 0U) {
        if (mock->registers[FPGA_RX_REG_FRAME_COUNT] != 0U) {
            mock->payload_offset = mock->payload_length;
            mock->registers[FPGA_RX_REG_FRAME_COUNT] = 0U;
            mock->registers[FPGA_RX_REG_STATUS0] &=
                (uint8_t)~FPGA_RX_STATUS_FRAME_READY;
        } else {
            mock->registers[FPGA_RX_REG_ERROR_FLAGS] |= FPGA_RX_ERROR_PROTOCOL;
        }
    }
}

static uint32_t mock_u32_le(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] |
           ((uint32_t)bytes[1] << 8U) |
           ((uint32_t)bytes[2] << 16U) |
           ((uint32_t)bytes[3] << 24U);
}

static void mock_ask_control_write(mock_fpga_t *mock, uint8_t value)
{
    uint32_t low = mock_u32_le(&mock->registers[FPGA_RX_REG_ASK_LOW_SHADOW_0]);
    uint32_t high = mock_u32_le(&mock->registers[FPGA_RX_REG_ASK_HIGH_SHADOW_0]);
    uint8_t mode = mock->registers[FPGA_RX_REG_RX_MODE_SHADOW];

    if ((value & FPGA_RX_ASK_CONFIG_CLEAR_ERROR) != 0U) {
        mock->registers[FPGA_RX_REG_ASK_CONFIG_STATUS] &=
            (uint8_t)~FPGA_RX_ASK_STATUS_ERROR;
    }
    if ((value & FPGA_RX_ASK_CONFIG_COMMIT) != 0U) {
        if ((mock->registers[FPGA_RX_REG_ASK_CONFIG_STATUS] &
             FPGA_RX_ASK_STATUS_PENDING) != 0U ||
            ((mode != (uint8_t)FPGA_RX_SPI_MODE_FSK) &&
             (mode != (uint8_t)FPGA_RX_SPI_MODE_OOK)) || (low >= high)) {
            mock->registers[FPGA_RX_REG_ASK_CONFIG_STATUS] |=
                FPGA_RX_ASK_STATUS_ERROR;
        } else {
            (void)memcpy(&mock->registers[FPGA_RX_REG_ASK_LOW_ACTIVE_0],
                         &mock->registers[FPGA_RX_REG_ASK_LOW_SHADOW_0], 4U);
            (void)memcpy(&mock->registers[FPGA_RX_REG_ASK_HIGH_ACTIVE_0],
                         &mock->registers[FPGA_RX_REG_ASK_HIGH_SHADOW_0], 4U);
            mock->registers[FPGA_RX_REG_RX_MODE_ACTIVE] = mode;
            ++mock->registers[FPGA_RX_REG_CONFIG_GENERATION];
        }
    }
}

static uint8_t mock_read_register(mock_fpga_t *mock, uint8_t address)
{
    if (address == FPGA_RX_REG_RX_DATA) {
        if (mock->payload_offset < mock->payload_length) {
            return mock->payload[mock->payload_offset++];
        }
        mock->registers[FPGA_RX_REG_ERROR_FLAGS] |= FPGA_RX_ERROR_PROTOCOL;
        return 0U;
    }
    if (address == FPGA_RX_REG_SNAPSHOT_DATA) {
        uint16_t sample_index;
        uint8_t byte_index;
        uint32_t value;
        uint8_t result;

        if (mock->snapshot_words == 0U) {
            mock->registers[FPGA_RX_REG_ERROR_FLAGS] |=
                FPGA_RX_ERROR_SNAPSHOT_EMPTY;
            return 0U;
        }

        sample_index = (uint16_t)(FPGA_RX_SPI_SNAPSHOT_WORDS -
                                  mock->snapshot_words);
        byte_index = (uint8_t)(mock->snapshot_byte_offset & 0x03U);
        value = (uint32_t)mock->snapshot[sample_index];
        result = (uint8_t)(value >> (24U - (8U * byte_index)));
        ++mock->snapshot_byte_offset;
        ++mock->snapshot_data_bytes_read;
        if ((mock->snapshot_byte_offset & 0x03U) == 0U) {
            --mock->snapshot_words;
        }
        return result;
    }

    mock_update_dynamic_registers(mock);
    if ((address == FPGA_RX_REG_CONFIG_GENERATION) &&
        (mock->bump_generation_once != 0U)) {
        uint8_t result = mock->registers[address];
        mock->bump_generation_once = 0U;
        ++mock->registers[FPGA_RX_REG_CONFIG_GENERATION];
        return result;
    }
    return mock->registers[address & 0x7FU];
}

static void mock_write_register(mock_fpga_t *mock, uint8_t address, uint8_t value)
{
    if (address == FPGA_RX_REG_CONTROL) {
        mock_control_write(mock, value);
    } else if (address == FPGA_RX_REG_ASK_CONFIG_CONTROL) {
        mock_ask_control_write(mock, value);
    } else {
        mock->registers[address & 0x7FU] = value;
    }
}

static fpga_rx_spi_result_t mock_transfer(
    void *context,
    const uint8_t *tx_data,
    uint8_t *rx_data,
    size_t length,
    uint32_t timeout_ms)
{
    mock_fpga_t *mock = (mock_fpga_t *)context;
    uint8_t address;
    uint8_t is_read;
    uint8_t is_stream;
    size_t index;

    (void)timeout_ms;
    if ((mock == NULL) || (tx_data == NULL) || (rx_data == NULL) ||
        (length == 0U) || (mock->selected == 0U)) {
        return FPGA_RX_SPI_IO_ERROR;
    }
    if (mock->fail_next_transfer != 0U) {
        mock->fail_next_transfer = 0U;
        return FPGA_RX_SPI_IO_ERROR;
    }

    (void)memset(rx_data, 0, length);
    is_read = (uint8_t)(tx_data[0] >> 7);
    address = (uint8_t)(tx_data[0] & 0x7FU);
    is_stream = (uint8_t)((address == FPGA_RX_REG_RX_DATA) ||
                          (address == FPGA_RX_REG_SNAPSHOT_DATA));

    for (index = 1U; index < length; ++index) {
        if (is_read != 0U) {
            rx_data[index] = mock_read_register(mock, address);
        } else {
            mock_write_register(mock, address, tx_data[index]);
        }
        if (is_stream == 0U) {
            address = (uint8_t)((address + 1U) & 0x7FU);
        }
    }

    mock_update_dynamic_registers(mock);
    return FPGA_RX_SPI_OK;
}

static void mock_chip_select(void *context, bool selected)
{
    mock_fpga_t *mock = (mock_fpga_t *)context;

    mock->selected = selected ? 1U : 0U;
    if (selected) {
        ++mock->select_count;
    } else {
        ++mock->deselect_count;
    }
}

static void mock_load_frame(
    mock_fpga_t *mock,
    uint8_t version_type,
    uint8_t sequence,
    const uint8_t *payload,
    uint8_t length)
{
    mock->registers[FPGA_RX_REG_FRAME_COUNT] = 1U;
    mock->registers[FPGA_RX_REG_HEAD_VERSION_TYPE] = version_type;
    mock->registers[FPGA_RX_REG_HEAD_SEQUENCE] = sequence;
    mock->registers[FPGA_RX_REG_HEAD_LENGTH] = length;
    mock->registers[FPGA_RX_REG_STATUS0] |= FPGA_RX_STATUS_FRAME_READY;
    mock->payload_length = length;
    mock->payload_offset = 0U;
    if (length != 0U) {
        (void)memcpy(mock->payload, payload, length);
    }
    mock_update_dynamic_registers(mock);
}

static void mock_load_time_metadata(
    mock_fpga_t *mock,
    uint8_t flags,
    uint32_t time_value)
{
    mock->registers[FPGA_RX_REG_HEAD_TIME_FLAGS] = flags;
    mock->registers[FPGA_RX_REG_HEAD_TIMESTAMP_B3] =
        (uint8_t)(time_value >> 24U);
    mock->registers[FPGA_RX_REG_HEAD_TIMESTAMP_B2] =
        (uint8_t)(time_value >> 16U);
    mock->registers[FPGA_RX_REG_HEAD_TIMESTAMP_B1] =
        (uint8_t)(time_value >> 8U);
    mock->registers[FPGA_RX_REG_HEAD_TIMESTAMP_B0] = (uint8_t)time_value;
}

int main(void)
{
    static const uint8_t payload[] = {0x10U, 0x20U, 0x30U, 0x40U, 0x50U, 0x60U};
    mock_fpga_t mock;
    fpga_rx_spi_bus_t bus;
    fpga_rx_spi_t device;
    fpga_rx_spi_status_t status;
    fpga_rx_spi_diagnostics_t diagnostics;
    fpga_rx_spi_tuning_t tuning;
    fpga_rx_spi_sweep_config_t sweep_config;
    fpga_rx_spi_sweep_result_t sweep_result;
    fpga_rx_spi_ask_config_t ask_config;
    fpga_rx_spi_ask_status_t ask_status;
    fpga_rx_spi_frame_meta_t metadata;
    int32_t samples[FPGA_RX_SPI_SNAPSHOT_WORDS];
    uint8_t firmware_version;
    uint8_t buffer[FPGA_RX_SPI_MAX_PAYLOAD];
    uint8_t parameter;
    uint16_t snapshot_count;
    size_t bytes_read;
    bool ready;
    bool busy;

    (void)memset(&mock, 0, sizeof(mock));
    mock.registers[FPGA_RX_REG_DEVICE_ID] = FPGA_RX_SPI_DEVICE_ID;
    mock.registers[FPGA_RX_REG_FW_VERSION] = FPGA_RX_SPI_PROTOCOL_VERSION;
    mock.registers[FPGA_RX_REG_STATUS0] = FPGA_RX_STATUS_ADC_READY |
                                         FPGA_RX_STATUS_CARRIER |
                                         FPGA_RX_STATUS_SYMBOL_LOCK;
    mock.registers[FPGA_RX_REG_ERROR_FLAGS] = FPGA_RX_ERROR_I2S |
                                              FPGA_RX_ERROR_FIFO_OVERFLOW;
    mock.registers[FPGA_RX_REG_GOOD_COUNT_L] = 0x34U;
    mock.registers[FPGA_RX_REG_GOOD_COUNT_H] = 0x12U;
    mock.registers[FPGA_RX_REG_CRC_ERROR_L] = 0x78U;
    mock.registers[FPGA_RX_REG_CRC_ERROR_H] = 0x56U;
    mock.registers[FPGA_RX_REG_LAST_SOFT_L] = 0xFEU;
    mock.registers[FPGA_RX_REG_LAST_SOFT_H] = 0xFFU;
    mock.registers[FPGA_RX_REG_LAST_ENERGY_0] = 11U;
    mock.registers[FPGA_RX_REG_LAST_ENERGY_1] = 22U;
    mock.registers[FPGA_RX_REG_LAST_CONFIDENCE] = 33U;
    mock.registers[FPGA_RX_REG_RX_MODE_SHADOW] = FPGA_RX_SPI_MODE_FSK;
    mock.registers[FPGA_RX_REG_RX_MODE_ACTIVE] = FPGA_RX_SPI_MODE_FSK;
    mock.registers[FPGA_RX_REG_ASK_LOW_SHADOW_0] = 0x90U;
    mock.registers[FPGA_RX_REG_ASK_LOW_SHADOW_0 + 1U] = 0x01U;
    mock.registers[FPGA_RX_REG_ASK_LOW_ACTIVE_0] = 0x90U;
    mock.registers[FPGA_RX_REG_ASK_LOW_ACTIVE_0 + 1U] = 0x01U;
    mock.registers[FPGA_RX_REG_ASK_HIGH_SHADOW_0] = 0x58U;
    mock.registers[FPGA_RX_REG_ASK_HIGH_SHADOW_0 + 1U] = 0x02U;
    mock.registers[FPGA_RX_REG_ASK_HIGH_ACTIVE_0] = 0x58U;
    mock.registers[FPGA_RX_REG_ASK_HIGH_ACTIVE_0 + 1U] = 0x02U;
    mock.registers[FPGA_RX_REG_ASK_ENERGY_0] = 0x78U;
    mock.registers[FPGA_RX_REG_ASK_ENERGY_0 + 1U] = 0x56U;
    mock.registers[FPGA_RX_REG_ASK_ENERGY_0 + 2U] = 0x34U;
    mock.registers[FPGA_RX_REG_ASK_ENERGY_0 + 3U] = 0x12U;
    mock.registers[FPGA_RX_REG_ASK_FLAGS] = FPGA_RX_ASK_FLAG_HARD_BIT |
                                             FPGA_RX_ASK_FLAG_ENERGY_READY;

    bus.transfer = mock_transfer;
    bus.chip_select = mock_chip_select;
    bus.context = &mock;
    bus.timeout_ms = 0U;

    CHECK(fpga_rx_spi_init(&device, &bus) == FPGA_RX_SPI_OK);
    CHECK(mock.selected == 0U);
    CHECK(device.bus.timeout_ms == FPGA_RX_SPI_DEFAULT_TIMEOUT_MS);
    CHECK(fpga_rx_spi_probe(&device, &firmware_version) == FPGA_RX_SPI_OK);
    CHECK(firmware_version == FPGA_RX_SPI_PROTOCOL_VERSION);

    CHECK(fpga_rx_spi_read_status(&device, &status) == FPGA_RX_SPI_OK);
    CHECK(status.device_id == FPGA_RX_SPI_DEVICE_ID);
    CHECK(status.firmware_version == FPGA_RX_SPI_PROTOCOL_VERSION);
    CHECK(status.good_frame_count == 0x1234U);
    CHECK(status.crc_error_count == 0x5678U);
    CHECK(status.error_flags == (FPGA_RX_ERROR_I2S |
                                 FPGA_RX_ERROR_FIFO_OVERFLOW));

    parameter = 9U;
    CHECK(fpga_rx_spi_write_registers(
              &device, FPGA_RX_REG_SAMPLE_SHIFT, &parameter, 1U) ==
          FPGA_RX_SPI_OK);
    parameter = 0U;
    CHECK(fpga_rx_spi_read_registers(
              &device, FPGA_RX_REG_SAMPLE_SHIFT, &parameter, 1U) ==
          FPGA_RX_SPI_OK);
    CHECK(parameter == 9U);

    tuning.sample_shift = 12U;
    tuning.energy_margin_q4_4 = 0x40U;
    tuning.confidence_threshold = 0x20U;
    tuning.noise_offset = 0x1234U;
    CHECK(fpga_rx_spi_write_tuning(&device, &tuning) == FPGA_RX_SPI_OK);
    (void)memset(&tuning, 0, sizeof(tuning));
    CHECK(fpga_rx_spi_read_tuning(&device, &tuning) == FPGA_RX_SPI_OK);
    CHECK(tuning.sample_shift == 12U);
    CHECK(tuning.energy_margin_q4_4 == 0x40U);
    CHECK(tuning.confidence_threshold == 0x20U);
    CHECK(tuning.noise_offset == 0x1234U);
    tuning.sample_shift = 32U;
    CHECK(fpga_rx_spi_write_tuning(&device, &tuning) ==
          FPGA_RX_SPI_INVALID_ARGUMENT);

    CHECK(fpga_rx_spi_read_diagnostics(&device, &diagnostics) ==
          FPGA_RX_SPI_OK);
    CHECK(diagnostics.soft_metric == -2);
    CHECK(diagnostics.energy_1600 == 11U);
    CHECK(diagnostics.energy_2000 == 22U);
    CHECK(diagnostics.confidence == 33U);

    CHECK(fpga_rx_spi_ask_read_status(&device, &ask_status) == FPGA_RX_SPI_OK);
    CHECK(ask_status.active.mode == FPGA_RX_SPI_MODE_FSK);
    CHECK(ask_status.active.low_threshold == 400U);
    CHECK(ask_status.active.high_threshold == 600U);
    CHECK(ask_status.energy == 0x12345678UL);
    CHECK(ask_status.hard_bit == 1U);
    CHECK(ask_status.symbol_locked == 0U);
    CHECK(ask_status.energy_ready == 1U);

    ask_config.mode = FPGA_RX_SPI_MODE_OOK;
    ask_config.low_threshold = 0x11223344UL;
    ask_config.high_threshold = 0x55667788UL;
    CHECK(fpga_rx_spi_ask_apply_config(&device, &ask_config, &ask_status) ==
          FPGA_RX_SPI_OK);
    CHECK(mock.registers[FPGA_RX_REG_ASK_LOW_SHADOW_0] == 0x44U);
    CHECK(mock.registers[FPGA_RX_REG_ASK_LOW_SHADOW_0 + 3U] == 0x11U);
    CHECK(mock.registers[FPGA_RX_REG_ASK_HIGH_SHADOW_0] == 0x88U);
    CHECK(mock.registers[FPGA_RX_REG_ASK_HIGH_ACTIVE_0 + 3U] == 0x55U);
    CHECK(ask_status.active.mode == FPGA_RX_SPI_MODE_OOK);
    CHECK(ask_status.active.low_threshold == 0x11223344UL);
    CHECK(ask_status.active.high_threshold == 0x55667788UL);
    CHECK(ask_status.generation == 1U);

    mock.bump_generation_once = 1U;
    CHECK(fpga_rx_spi_ask_read_status(&device, &ask_status) == FPGA_RX_SPI_OK);
    CHECK(ask_status.generation == 2U);
    mock.registers[FPGA_RX_REG_ASK_CONFIG_STATUS] = FPGA_RX_ASK_STATUS_PENDING;
    ask_config.mode = FPGA_RX_SPI_MODE_FSK;
    ask_config.low_threshold = 7U;
    ask_config.high_threshold = 8U;
    CHECK(fpga_rx_spi_ask_apply_config(&device, &ask_config, &ask_status) ==
          FPGA_RX_SPI_PROTOCOL_ERROR);
    CHECK(mock.registers[FPGA_RX_REG_RX_MODE_ACTIVE] == FPGA_RX_SPI_MODE_OOK);
    CHECK(mock.registers[FPGA_RX_REG_RX_MODE_SHADOW] == FPGA_RX_SPI_MODE_OOK);
    CHECK(mock.registers[FPGA_RX_REG_ASK_LOW_SHADOW_0] == 0x44U);
    mock.registers[FPGA_RX_REG_ASK_CONFIG_STATUS] = 0U;
    mock.registers[FPGA_RX_REG_RX_MODE_ACTIVE] = 3U;
    CHECK(fpga_rx_spi_ask_read_status(&device, &ask_status) ==
          FPGA_RX_SPI_PROTOCOL_ERROR);
    mock.registers[FPGA_RX_REG_RX_MODE_ACTIVE] = FPGA_RX_SPI_MODE_OOK;
    ask_config.low_threshold = 3U;
    ask_config.high_threshold = 3U;
    CHECK(fpga_rx_spi_ask_stage_config(&device, &ask_config) ==
          FPGA_RX_SPI_INVALID_ARGUMENT);
    mock.registers[FPGA_RX_REG_FW_VERSION] = 0x11U;
    CHECK(fpga_rx_spi_ask_read_status(&device, &ask_status) ==
          FPGA_RX_SPI_PROTOCOL_ERROR);
    mock.registers[FPGA_RX_REG_FW_VERSION] = 0xFFU;
    CHECK(fpga_rx_spi_ask_read_status(&device, &ask_status) ==
          FPGA_RX_SPI_PROTOCOL_ERROR);
    mock.registers[FPGA_RX_REG_FW_VERSION] = FPGA_RX_SPI_PROTOCOL_VERSION;
    mock.registers[FPGA_RX_REG_ASK_CONFIG_STATUS] = FPGA_RX_ASK_STATUS_ERROR;
    CHECK(fpga_rx_spi_ask_clear_error(&device) == FPGA_RX_SPI_OK);
    CHECK(mock.registers[FPGA_RX_REG_ASK_CONFIG_STATUS] == 0U);

    sweep_config.phase_increment = 0x08888889UL;
    sweep_config.settle_samples = 960U;
    sweep_config.window_samples = 4800U;
    sweep_config.average_count = 3U;
    CHECK(fpga_rx_spi_sweep_start(&device, &sweep_config) == FPGA_RX_SPI_OK);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_PHASE_0] == 0x89U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_PHASE_0 + 1U] == 0x88U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_SETTLE_L] == 0xC0U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_SETTLE_L + 1U] == 0x03U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_WINDOW_L] == 0xC0U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_WINDOW_L + 1U] == 0x12U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_AVERAGE] == 3U);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_CONTROL] ==
          FPGA_RX_SWEEP_CONTROL_START);

    mock.registers[FPGA_RX_REG_SWEEP_STATUS] = FPGA_RX_SWEEP_STATUS_ACTIVE |
                                               FPGA_RX_SWEEP_STATUS_DONE;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 0U] = 0x66U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 1U] = 0x55U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 2U] = 0x44U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 3U] = 0x33U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 4U] = 0x22U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 5U] = 0x11U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 6U] = 0U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 7U] = 0U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 8U] = 0x78U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 9U] = 0x56U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 10U] = 0x34U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 11U] = 0x12U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 12U] = 0xEFU;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 13U] = 0xCDU;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 14U] = 0xABU;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 15U] = 0x89U;
    mock.registers[FPGA_RX_REG_SWEEP_SUM_0 + 16U] = 7U;
    mock.registers[FPGA_RX_REG_SWEEP_COUNT] = 3U;
    CHECK(fpga_rx_spi_sweep_read_result(&device, &sweep_result) ==
          FPGA_RX_SPI_OK);
    CHECK(sweep_result.energy_sum == 0x0000112233445566ULL);
    CHECK(sweep_result.energy_min == 0x12345678UL);
    CHECK(sweep_result.energy_max == 0x89ABCDEFUL);
    CHECK(sweep_result.clip_count == 7U);
    CHECK(sweep_result.window_count == 3U);
    CHECK(fpga_rx_spi_sweep_abort(&device) == FPGA_RX_SPI_OK);
    CHECK(mock.registers[FPGA_RX_REG_SWEEP_CONTROL] ==
          FPGA_RX_SWEEP_CONTROL_ABORT);

    mock_load_time_metadata(&mock, 0x02U, 0x12345678UL);
    mock_load_frame(&mock, 0x21U, 0x5AU, NULL, 0U);
    CHECK(fpga_rx_spi_begin_frame(&device, &metadata) == FPGA_RX_SPI_OK);
    CHECK(metadata.version == 2U);
    CHECK(metadata.frame_type == 1U);
    CHECK(metadata.time_base_frame == 1U);
    CHECK(metadata.timestamp_valid == 1U);
    CHECK(metadata.base_time_s == 0x12345678UL);
    CHECK(metadata.timestamp_ms == 0x12345678ULL * 1000ULL);
    CHECK(fpga_rx_spi_pop_frame(&device) == FPGA_RX_SPI_OK);

    mock_load_time_metadata(&mock, 0x01U, 0x00012345UL);
    mock_load_frame(&mock, 0x20U, 0x5AU, payload, (uint8_t)sizeof(payload));
    CHECK(fpga_rx_spi_begin_frame(&device, &metadata) == FPGA_RX_SPI_OK);
    CHECK(metadata.version == 2U);
    CHECK(metadata.frame_type == 0U);
    CHECK(metadata.sequence == 0x5AU);
    CHECK(metadata.payload_length == sizeof(payload));
    CHECK(metadata.elapsed_10ms == 0x00012345UL);
    CHECK(metadata.timestamp_valid == 1U);
    CHECK(metadata.timestamp_ms ==
          (0x12345678ULL * 1000ULL) + (0x00012345ULL * 10ULL));
    CHECK(fpga_rx_spi_read_payload(&device, buffer, 2U, &bytes_read) ==
          FPGA_RX_SPI_OK);
    CHECK(bytes_read == 2U);
    CHECK(memcmp(buffer, payload, 2U) == 0);
    CHECK(fpga_rx_spi_pop_frame(&device) == FPGA_RX_SPI_BAD_STATE);
    CHECK(fpga_rx_spi_read_payload(&device, &buffer[2], sizeof(buffer),
                                   &bytes_read) == FPGA_RX_SPI_OK);
    CHECK(bytes_read == sizeof(payload) - 2U);
    CHECK(memcmp(buffer, payload, sizeof(payload)) == 0);
    CHECK(fpga_rx_spi_pop_frame(&device) == FPGA_RX_SPI_OK);
    CHECK(mock.registers[FPGA_RX_REG_FRAME_COUNT] == 0U);

    mock_load_time_metadata(&mock, 0x00U, 7U);
    mock_load_frame(&mock, 0x10U, 0x5BU, payload, (uint8_t)sizeof(payload));
    CHECK(fpga_rx_spi_begin_frame(&device, &metadata) == FPGA_RX_SPI_OK);
    CHECK(fpga_rx_spi_read_payload(&device, buffer, 1U, &bytes_read) ==
          FPGA_RX_SPI_OK);
    CHECK(fpga_rx_spi_drop_frame(&device) == FPGA_RX_SPI_OK);
    CHECK(mock.payload_offset == mock.payload_length);

    mock_load_frame(&mock, 0x10U, 0x5CU, NULL, 0U);
    CHECK(fpga_rx_spi_begin_frame(&device, &metadata) == FPGA_RX_SPI_OK);
    CHECK(metadata.payload_length == 0U);
    CHECK(fpga_rx_spi_pop_frame(&device) == FPGA_RX_SPI_OK);

    CHECK(fpga_rx_spi_clear_errors(&device) == FPGA_RX_SPI_OK);
    CHECK(mock.registers[FPGA_RX_REG_ERROR_FLAGS] == 0U);
    CHECK(fpga_rx_spi_adc_reinitialize(&device) == FPGA_RX_SPI_OK);
    CHECK(mock.adc_reinit_count == 1U);

    CHECK(fpga_rx_spi_snapshot_start(&device) == FPGA_RX_SPI_OK);
    CHECK(fpga_rx_spi_snapshot_ready(&device, &ready, &busy) == FPGA_RX_SPI_OK);
    CHECK(ready && !busy);
    CHECK(fpga_rx_spi_snapshot_word_count(&device, &snapshot_count) ==
          FPGA_RX_SPI_OK);
    CHECK(snapshot_count == FPGA_RX_SPI_SNAPSHOT_WORDS);
    CHECK(fpga_rx_spi_snapshot_read_bytes(&device, buffer, 3U) ==
          FPGA_RX_SPI_INVALID_ARGUMENT);
    CHECK(fpga_rx_spi_snapshot_read_bytes(
              &device, buffer, FPGA_RX_SPI_SNAPSHOT_BYTES + 4U) ==
          FPGA_RX_SPI_BAD_STATE);
    CHECK(fpga_rx_spi_snapshot_read_all(&device, samples) == FPGA_RX_SPI_OK);
    CHECK(mock.snapshot_data_bytes_read == FPGA_RX_SPI_SNAPSHOT_BYTES);
    CHECK(samples[0] == (int32_t)0x80000000UL);
    CHECK(samples[1] == (int32_t)0x80000001UL);
    CHECK(samples[FPGA_RX_SPI_SNAPSHOT_WORDS - 1U] ==
          (int32_t)0x800003FFUL);
    CHECK(fpga_rx_spi_snapshot_word_count(&device, &snapshot_count) ==
          FPGA_RX_SPI_OK);
    CHECK(snapshot_count == 0U);

    mock.fail_next_transfer = 1U;
    CHECK(fpga_rx_spi_read_status(&device, &status) == FPGA_RX_SPI_IO_ERROR);
    CHECK(mock.selected == 0U);
    CHECK(mock.select_count == mock.deselect_count - 1U);

    (void)printf("PASS: register/status, OOK staging/commit/readback, coherent "
                 "generation, sweep diagnostics, segmented frame, POP/DROP, "
                 "controls and 4096-byte snapshot verified\n");
    return 0;
}
