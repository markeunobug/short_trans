#include "fpga_rx_spi.h"

#include <string.h>

#define FPGA_RX_SPI_READ_COMMAND       0x80U
#define FPGA_RX_SPI_ADDRESS_MASK       0x7FU
#define FPGA_RX_SPI_IO_CHUNK           64U

static fpga_rx_spi_result_t fpga_rx_spi_exchange(
    fpga_rx_spi_t *device,
    const uint8_t *tx_data,
    uint8_t *rx_data,
    size_t length)
{
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (device->bus.transfer == NULL) ||
        (device->bus.chip_select == NULL) || (tx_data == NULL) ||
        (rx_data == NULL) || (length == 0U)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    device->bus.chip_select(device->bus.context, true);
    result = device->bus.transfer(
        device->bus.context,
        tx_data,
        rx_data,
        length,
        device->bus.timeout_ms);
    device->bus.chip_select(device->bus.context, false);

    return result;
}

static fpga_rx_spi_result_t fpga_rx_spi_read_stream(
    fpga_rx_spi_t *device,
    uint8_t address,
    uint8_t *data,
    size_t length)
{
    uint8_t tx_data[FPGA_RX_SPI_IO_CHUNK + 1U];
    uint8_t rx_data[FPGA_RX_SPI_IO_CHUNK + 1U];
    fpga_rx_spi_result_t result;
    size_t offset = 0U;

    if ((device == NULL) || ((length != 0U) && (data == NULL))) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    while (offset < length) {
        size_t chunk = length - offset;
        if (chunk > FPGA_RX_SPI_IO_CHUNK) {
            chunk = FPGA_RX_SPI_IO_CHUNK;
        }

        (void)memset(tx_data, 0, chunk + 1U);
        tx_data[0] = (uint8_t)(FPGA_RX_SPI_READ_COMMAND |
                              (address & FPGA_RX_SPI_ADDRESS_MASK));
        result = fpga_rx_spi_exchange(device, tx_data, rx_data, chunk + 1U);
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }

        (void)memcpy(&data[offset], &rx_data[1], chunk);
        offset += chunk;
    }

    return FPGA_RX_SPI_OK;
}

static fpga_rx_spi_result_t fpga_rx_spi_write_control(
    fpga_rx_spi_t *device,
    uint8_t control_bits)
{
    return fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_CONTROL, &control_bits, 1U);
}

static void fpga_rx_spi_close_frame(fpga_rx_spi_t *device)
{
    device->frame_open = 0U;
    device->frame_length = 0U;
    device->frame_bytes_read = 0U;
}

static uint32_t fpga_rx_spi_unpack_u32_le(const uint8_t bytes[4])
{
    return (uint32_t)bytes[0] |
           ((uint32_t)bytes[1] << 8U) |
           ((uint32_t)bytes[2] << 16U) |
           ((uint32_t)bytes[3] << 24U);
}

static void fpga_rx_spi_pack_u32_le(uint8_t bytes[4], uint32_t value)
{
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8U);
    bytes[2] = (uint8_t)(value >> 16U);
    bytes[3] = (uint8_t)(value >> 24U);
}

static fpga_rx_spi_result_t fpga_rx_spi_ask_require_firmware(
    fpga_rx_spi_t *device)
{
    uint8_t firmware_version;
    fpga_rx_spi_result_t result;

    if (device == NULL) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_FW_VERSION, &firmware_version, 1U);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    return ((firmware_version >= FPGA_RX_SPI_ASK_MIN_FW_VERSION) &&
            (firmware_version != 0xFFU))
               ? FPGA_RX_SPI_OK
               : FPGA_RX_SPI_PROTOCOL_ERROR;
}

static fpga_rx_spi_result_t fpga_rx_spi_fsk_require_firmware(
    fpga_rx_spi_t *device)
{
    uint8_t firmware_version;
    fpga_rx_spi_result_t result;

    if (device == NULL) return FPGA_RX_SPI_INVALID_ARGUMENT;
    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_FW_VERSION, &firmware_version, 1U);
    if (result != FPGA_RX_SPI_OK) return result;
    return (firmware_version >= FPGA_RX_SPI_FSK_TUNING_MIN_FW_VERSION &&
            firmware_version != 0xFFU) ? FPGA_RX_SPI_OK : FPGA_RX_SPI_PROTOCOL_ERROR;
}
static bool fpga_rx_spi_ask_config_valid(const fpga_rx_spi_ask_config_t *config)
{
    return (config != NULL) &&
           ((config->mode == (uint8_t)FPGA_RX_SPI_MODE_FSK) ||
            (config->mode == (uint8_t)FPGA_RX_SPI_MODE_OOK)) &&
           (config->low_threshold < config->high_threshold);
}

fpga_rx_spi_result_t fpga_rx_spi_init(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_bus_t *bus)
{
    if ((device == NULL) || (bus == NULL) || (bus->transfer == NULL) ||
        (bus->chip_select == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    (void)memset(device, 0, sizeof(*device));
    device->bus = *bus;
    if (device->bus.timeout_ms == 0U) {
        device->bus.timeout_ms = FPGA_RX_SPI_DEFAULT_TIMEOUT_MS;
    }
    device->bus.chip_select(device->bus.context, false);

    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_probe(
    fpga_rx_spi_t *device,
    uint8_t *firmware_version)
{
    uint8_t identification[2];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (firmware_version == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_DEVICE_ID, identification, sizeof(identification));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    if (identification[0] != FPGA_RX_SPI_DEVICE_ID) {
        return FPGA_RX_SPI_BAD_DEVICE;
    }

    *firmware_version = identification[1];
    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_read_registers(
    fpga_rx_spi_t *device,
    uint8_t address,
    uint8_t *data,
    size_t length)
{
    uint8_t current_address = address;
    size_t offset = 0U;

    if ((device == NULL) || ((length != 0U) && (data == NULL)) ||
        ((address & ~FPGA_RX_SPI_ADDRESS_MASK) != 0U)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    if ((address == FPGA_RX_REG_RX_DATA) ||
        (address == FPGA_RX_REG_SNAPSHOT_DATA) ||
        (address == FPGA_RX_REG_TRACE_DATA) ||
        (address == FPGA_RX_REG_BER_DATA)) {
        return fpga_rx_spi_read_stream(device, address, data, length);
    }

    while (offset < length) {
        uint8_t tx_data[FPGA_RX_SPI_IO_CHUNK + 1U];
        uint8_t rx_data[FPGA_RX_SPI_IO_CHUNK + 1U];
        fpga_rx_spi_result_t result;
        size_t chunk = length - offset;
        size_t address_space = 0x80U - (size_t)current_address;

        if (chunk > FPGA_RX_SPI_IO_CHUNK) {
            chunk = FPGA_RX_SPI_IO_CHUNK;
        }
        if (chunk > address_space) {
            chunk = address_space;
        }

        (void)memset(tx_data, 0, chunk + 1U);
        tx_data[0] = (uint8_t)(FPGA_RX_SPI_READ_COMMAND | current_address);
        result = fpga_rx_spi_exchange(device, tx_data, rx_data, chunk + 1U);
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }
        (void)memcpy(&data[offset], &rx_data[1], chunk);

        offset += chunk;
        current_address = (uint8_t)(current_address + chunk);
        if ((offset < length) && (current_address >= 0x80U)) {
            return FPGA_RX_SPI_INVALID_ARGUMENT;
        }
    }

    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_write_registers(
    fpga_rx_spi_t *device,
    uint8_t address,
    const uint8_t *data,
    size_t length)
{
    uint8_t current_address = address;
    size_t offset = 0U;

    if ((device == NULL) || ((length != 0U) && (data == NULL)) ||
        ((address & ~FPGA_RX_SPI_ADDRESS_MASK) != 0U) ||
        (address == FPGA_RX_REG_RX_DATA) ||
        (address == FPGA_RX_REG_SNAPSHOT_DATA) ||
        (address == FPGA_RX_REG_TRACE_DATA) ||
        (address == FPGA_RX_REG_BER_DATA)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    while (offset < length) {
        uint8_t tx_data[FPGA_RX_SPI_IO_CHUNK + 1U];
        uint8_t rx_data[FPGA_RX_SPI_IO_CHUNK + 1U];
        fpga_rx_spi_result_t result;
        size_t chunk = length - offset;
        size_t address_space = 0x80U - (size_t)current_address;

        if (chunk > FPGA_RX_SPI_IO_CHUNK) {
            chunk = FPGA_RX_SPI_IO_CHUNK;
        }
        if (chunk > address_space) {
            chunk = address_space;
        }

        tx_data[0] = current_address;
        (void)memcpy(&tx_data[1], &data[offset], chunk);
        (void)memset(rx_data, 0, chunk + 1U);
        result = fpga_rx_spi_exchange(device, tx_data, rx_data, chunk + 1U);
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }

        offset += chunk;
        current_address = (uint8_t)(current_address + chunk);
        if ((offset < length) && (current_address >= 0x80U)) {
            return FPGA_RX_SPI_INVALID_ARGUMENT;
        }
    }

    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_read_status(
    fpga_rx_spi_t *device,
    fpga_rx_spi_status_t *status)
{
    uint8_t registers[14];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (status == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_DEVICE_ID, registers, sizeof(registers));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    status->device_id = registers[0];
    status->firmware_version = registers[1];
    status->status0 = registers[2];
    status->error_flags = registers[3];
    status->frame_count = registers[4];
    status->rx_fifo_level = (uint16_t)registers[8] |
                            ((uint16_t)(registers[9] & 0x01U) << 8);
    status->good_frame_count = (uint16_t)registers[10] |
                               ((uint16_t)registers[11] << 8);
    status->crc_error_count = (uint16_t)registers[12] |
                              ((uint16_t)registers[13] << 8);

    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_read_diagnostics(
    fpga_rx_spi_t *device,
    fpga_rx_spi_diagnostics_t *diagnostics)
{
    uint8_t registers[5];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (diagnostics == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_LAST_SOFT_L, registers, sizeof(registers));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    diagnostics->soft_metric = (int16_t)((uint16_t)registers[0] |
                                         ((uint16_t)registers[1] << 8));
    diagnostics->energy_1600 = registers[2];
    diagnostics->energy_2000 = registers[3];
    diagnostics->confidence = registers[4];

    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_read_tuning(
    fpga_rx_spi_t *device,
    fpga_rx_spi_tuning_t *tuning)
{
    uint8_t registers[5];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (tuning == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_SAMPLE_SHIFT, registers, sizeof(registers));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    tuning->sample_shift = (uint8_t)(registers[0] & 0x1FU);
    tuning->energy_margin_q4_4 = registers[1];
    tuning->confidence_threshold = registers[2];
    tuning->noise_offset = (uint16_t)registers[3] |
                           ((uint16_t)registers[4] << 8);
    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_write_tuning(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_tuning_t *tuning)
{
    uint8_t registers[5];

    if ((device == NULL) || (tuning == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    if (tuning->sample_shift > 31U) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    registers[0] = tuning->sample_shift;
    registers[1] = tuning->energy_margin_q4_4;
    registers[2] = tuning->confidence_threshold;
    registers[3] = (uint8_t)(tuning->noise_offset & 0xFFU);
    registers[4] = (uint8_t)(tuning->noise_offset >> 8);
    return fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_SAMPLE_SHIFT, registers, sizeof(registers));
}

fpga_rx_spi_result_t fpga_rx_spi_sweep_start(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_sweep_config_t *config)
{
    uint8_t registers[9];
    uint8_t control = FPGA_RX_SWEEP_CONTROL_START;
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (config == NULL) ||
        (config->phase_increment == 0U) ||
        (config->window_samples == 0U) ||
        (config->average_count == 0U)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    registers[0] = (uint8_t)config->phase_increment;
    registers[1] = (uint8_t)(config->phase_increment >> 8U);
    registers[2] = (uint8_t)(config->phase_increment >> 16U);
    registers[3] = (uint8_t)(config->phase_increment >> 24U);
    registers[4] = (uint8_t)config->settle_samples;
    registers[5] = (uint8_t)(config->settle_samples >> 8U);
    registers[6] = (uint8_t)config->window_samples;
    registers[7] = (uint8_t)(config->window_samples >> 8U);
    registers[8] = config->average_count;

    result = fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_SWEEP_PHASE_0, registers, sizeof(registers));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    return fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_SWEEP_CONTROL, &control, 1U);
}

fpga_rx_spi_result_t fpga_rx_spi_sweep_abort(fpga_rx_spi_t *device)
{
    uint8_t control = FPGA_RX_SWEEP_CONTROL_ABORT;

    if (device == NULL) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    return fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_SWEEP_CONTROL, &control, 1U);
}

fpga_rx_spi_result_t fpga_rx_spi_sweep_read_status(
    fpga_rx_spi_t *device,
    uint8_t *status)
{
    if ((device == NULL) || (status == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    return fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_SWEEP_STATUS, status, 1U);
}

fpga_rx_spi_result_t fpga_rx_spi_sweep_read_result(
    fpga_rx_spi_t *device,
    fpga_rx_spi_sweep_result_t *result)
{
    uint8_t registers[21];
    fpga_rx_spi_result_t read_result;
    uint8_t index;

    if ((device == NULL) || (result == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    read_result = fpga_rx_spi_sweep_read_status(device, &result->status);
    if (read_result != FPGA_RX_SPI_OK) {
        return read_result;
    }
    if ((result->status & FPGA_RX_SWEEP_STATUS_DONE) == 0U) {
        return FPGA_RX_SPI_BAD_STATE;
    }

    read_result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_SWEEP_SUM_0, registers, sizeof(registers));
    if (read_result != FPGA_RX_SPI_OK) {
        return read_result;
    }

    result->energy_sum = 0ULL;
    for (index = 0U; index < 8U; ++index) {
        result->energy_sum |= ((uint64_t)registers[index]) << (8U * index);
    }
    result->energy_min = (uint32_t)registers[8] |
                         ((uint32_t)registers[9] << 8U) |
                         ((uint32_t)registers[10] << 16U) |
                         ((uint32_t)registers[11] << 24U);
    result->energy_max = (uint32_t)registers[12] |
                         ((uint32_t)registers[13] << 8U) |
                         ((uint32_t)registers[14] << 16U) |
                         ((uint32_t)registers[15] << 24U);
    result->clip_count = (uint32_t)registers[16] |
                         ((uint32_t)registers[17] << 8U) |
                         ((uint32_t)registers[18] << 16U) |
                         ((uint32_t)registers[19] << 24U);
    result->window_count = registers[20];
    return (result->window_count == 0U)
               ? FPGA_RX_SPI_PROTOCOL_ERROR
               : FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_fsk_read_status(
    fpga_rx_spi_t *device,
    fpga_rx_spi_fsk_status_t *status)
{
    uint8_t values[4], flags, generation_before, generation_after, mode;
    fpga_rx_spi_result_t result;
    uint8_t attempt;

    if ((device == NULL) || (status == NULL)) return FPGA_RX_SPI_INVALID_ARGUMENT;
    result = fpga_rx_spi_fsk_require_firmware(device);
    if (result != FPGA_RX_SPI_OK) return result;

    for (attempt = 0U; attempt < 3U; ++attempt) {
        result = fpga_rx_spi_read_registers(device,
            FPGA_RX_REG_FSK_CONFIG_GENERATION, &generation_before, 1U);
        if (result != FPGA_RX_SPI_OK) return result;
        result = fpga_rx_spi_read_registers(device,
            FPGA_RX_REG_FSK_CONFIG_STATUS, &flags, 1U);
        if (result != FPGA_RX_SPI_OK) return result;
        result = fpga_rx_spi_read_registers(device,
            FPGA_RX_REG_ENERGY_MARGIN, values, sizeof(values));
        if (result != FPGA_RX_SPI_OK) return result;
        result = fpga_rx_spi_read_registers(device,
            FPGA_RX_REG_RX_MODE_ACTIVE, &mode, 1U);
        if (result != FPGA_RX_SPI_OK) return result;
        result = fpga_rx_spi_read_registers(device,
            FPGA_RX_REG_FSK_CONFIG_GENERATION, &generation_after, 1U);
        if (result != FPGA_RX_SPI_OK) return result;
        if (generation_before == generation_after) {
            status->active.energy_margin_q4_4 = values[0];
            status->active.noise_offset_units = (uint16_t)values[2] |
                ((uint16_t)values[3] << 8U);
            status->pending = (uint8_t)((flags & 1U) != 0U);
            status->error = (uint8_t)((flags & 2U) != 0U);
            status->rx_busy = (uint8_t)((flags & 4U) != 0U);
            status->sweep_active = (uint8_t)((flags & 8U) != 0U);
            status->mode = (uint8_t)(mode & 3U);
            status->generation = generation_after;
            return status->active.energy_margin_q4_4 == 0U
                ? FPGA_RX_SPI_PROTOCOL_ERROR : FPGA_RX_SPI_OK;
        }
    }
    return FPGA_RX_SPI_PROTOCOL_ERROR;
}

fpga_rx_spi_result_t fpga_rx_spi_fsk_apply_config(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_fsk_config_t *config,
    fpga_rx_spi_fsk_status_t *status)
{
    uint8_t staged[3], control;
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (config == NULL) || (status == NULL) ||
        (config->energy_margin_q4_4 == 0U)) return FPGA_RX_SPI_INVALID_ARGUMENT;
    result = fpga_rx_spi_fsk_read_status(device, status);
    if (result != FPGA_RX_SPI_OK) return result;
    if (status->mode != FPGA_RX_SPI_MODE_FSK || status->pending != 0U)
        return FPGA_RX_SPI_BAD_STATE;
    if (status->error != 0U) {
        control = FPGA_RX_FSK_CONFIG_CLEAR_ERROR;
        result = fpga_rx_spi_write_registers(
            device, FPGA_RX_REG_FSK_CONFIG_CONTROL, &control, 1U);
        if (result != FPGA_RX_SPI_OK) return result;
    }

    staged[0] = config->energy_margin_q4_4;
    staged[1] = (uint8_t)config->noise_offset_units;
    staged[2] = (uint8_t)(config->noise_offset_units >> 8U);
    result = fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_FSK_MARGIN_SHADOW, staged, sizeof(staged));
    if (result != FPGA_RX_SPI_OK) return result;
    control = FPGA_RX_FSK_CONFIG_COMMIT;
    result = fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_FSK_CONFIG_CONTROL, &control, 1U);
    if (result != FPGA_RX_SPI_OK) return result;
    result = fpga_rx_spi_fsk_read_status(device, status);
    if (result != FPGA_RX_SPI_OK) return result;
    return status->error ? FPGA_RX_SPI_PROTOCOL_ERROR : FPGA_RX_SPI_OK;
}
fpga_rx_spi_result_t fpga_rx_spi_ask_stage_config(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_ask_config_t *config)
{
    uint8_t registers[9];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || !fpga_rx_spi_ask_config_valid(config)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_ask_require_firmware(device);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    registers[0] = config->mode;
    fpga_rx_spi_pack_u32_le(&registers[1], config->low_threshold);
    fpga_rx_spi_pack_u32_le(&registers[5], config->high_threshold);
    return fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_RX_MODE_SHADOW, registers, sizeof(registers));
}

fpga_rx_spi_result_t fpga_rx_spi_ask_commit(fpga_rx_spi_t *device)
{
    uint8_t control = FPGA_RX_ASK_CONFIG_COMMIT;
    uint8_t status;
    fpga_rx_spi_result_t result;

    if (device == NULL) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_ask_require_firmware(device);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    result = fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_ASK_CONFIG_CONTROL, &control, 1U);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_ASK_CONFIG_STATUS, &status, 1U);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    return ((status & FPGA_RX_ASK_STATUS_ERROR) != 0U)
               ? FPGA_RX_SPI_PROTOCOL_ERROR
               : FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_ask_clear_error(fpga_rx_spi_t *device)
{
    uint8_t control = FPGA_RX_ASK_CONFIG_CLEAR_ERROR;
    fpga_rx_spi_result_t result;

    if (device == NULL) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_ask_require_firmware(device);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    return fpga_rx_spi_write_registers(
        device, FPGA_RX_REG_ASK_CONFIG_CONTROL, &control, 1U);
}

fpga_rx_spi_result_t fpga_rx_spi_ask_read_status(
    fpga_rx_spi_t *device,
    fpga_rx_spi_ask_status_t *status)
{
    uint8_t registers[16];
    uint8_t generation_before;
    uint8_t generation_after;
    fpga_rx_spi_result_t result;
    uint8_t attempt;

    if ((device == NULL) || (status == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_ask_require_firmware(device);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    for (attempt = 0U; attempt < 3U; ++attempt) {
        result = fpga_rx_spi_read_registers(
            device, FPGA_RX_REG_CONFIG_GENERATION, &generation_before, 1U);
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }
        result = fpga_rx_spi_read_registers(
            device, FPGA_RX_REG_ASK_CONFIG_STATUS, registers, sizeof(registers));
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }
        result = fpga_rx_spi_read_registers(
            device, FPGA_RX_REG_CONFIG_GENERATION, &generation_after, 1U);
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }
        if ((generation_before == registers[15]) &&
            (registers[15] == generation_after)) {
            status->pending = (uint8_t)((registers[0] &
                                         FPGA_RX_ASK_STATUS_PENDING) != 0U);
            status->error = (uint8_t)((registers[0] &
                                       FPGA_RX_ASK_STATUS_ERROR) != 0U);
            status->rx_busy = (uint8_t)((registers[0] &
                                         FPGA_RX_ASK_STATUS_RX_BUSY) != 0U);
            status->sweep_active = (uint8_t)((registers[0] &
                                               FPGA_RX_ASK_STATUS_SWEEP_ACTIVE) != 0U);
            status->active.low_threshold = fpga_rx_spi_unpack_u32_le(&registers[1]);
            status->active.high_threshold = fpga_rx_spi_unpack_u32_le(&registers[5]);
            status->energy = fpga_rx_spi_unpack_u32_le(&registers[9]);
            status->active.mode = registers[13];
            status->hard_bit = (uint8_t)((registers[14] & FPGA_RX_ASK_FLAG_HARD_BIT) != 0U);
            status->symbol_locked = (uint8_t)((registers[14] & FPGA_RX_ASK_FLAG_SYMBOL_LOCK) != 0U);
            status->energy_ready = (uint8_t)((registers[14] & FPGA_RX_ASK_FLAG_ENERGY_READY) != 0U);
            status->generation = registers[15];
            if (!fpga_rx_spi_ask_config_valid(&status->active)) {
                return FPGA_RX_SPI_PROTOCOL_ERROR;
            }
            return FPGA_RX_SPI_OK;
        }
    }

    return FPGA_RX_SPI_PROTOCOL_ERROR;
}

fpga_rx_spi_result_t fpga_rx_spi_ask_apply_config(
    fpga_rx_spi_t *device,
    const fpga_rx_spi_ask_config_t *config,
    fpga_rx_spi_ask_status_t *status)
{
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (status == NULL) ||
        !fpga_rx_spi_ask_config_valid(config)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_ask_read_status(device, status);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    if ((status->pending != 0U) || (status->error != 0U)) {
        return FPGA_RX_SPI_PROTOCOL_ERROR;
    }
    result = fpga_rx_spi_ask_stage_config(device, config);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    result = fpga_rx_spi_ask_commit(device);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    result = fpga_rx_spi_ask_read_status(device, status);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    if ((status->error != 0U) ||
        ((status->pending == 0U) &&
         ((status->active.mode != config->mode) ||
          (status->active.low_threshold != config->low_threshold) ||
          (status->active.high_threshold != config->high_threshold)))) {
        return FPGA_RX_SPI_PROTOCOL_ERROR;
    }
    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_begin_frame(
    fpga_rx_spi_t *device,
    fpga_rx_spi_frame_meta_t *metadata)
{
    uint8_t head[4];
    uint8_t time_registers[5];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (metadata == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    if (device->frame_open != 0U) {
        return FPGA_RX_SPI_BAD_STATE;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_FRAME_COUNT, head, sizeof(head));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    if (head[0] == 0U) {
        return FPGA_RX_SPI_EMPTY;
    }
    if (head[3] > FPGA_RX_SPI_MAX_PAYLOAD) {
        return FPGA_RX_SPI_PROTOCOL_ERROR;
    }

    metadata->version = (uint8_t)(head[1] >> 4);
    metadata->frame_type = (uint8_t)(head[1] & 0x0FU);
    metadata->sequence = head[2];
    metadata->payload_length = head[3];

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_HEAD_TIME_FLAGS, time_registers,
        sizeof(time_registers));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    metadata->time_flags = time_registers[0];
    metadata->timestamp_valid = 0U;
    metadata->time_base_frame = (uint8_t)((time_registers[0] >> 1U) & 0x01U);
    metadata->time_value = ((uint32_t)time_registers[1] << 24U) |
                          ((uint32_t)time_registers[2] << 16U) |
                          ((uint32_t)time_registers[3] << 8U) |
                          (uint32_t)time_registers[4];
    metadata->base_time_s = device->base_time_s;
    metadata->elapsed_10ms = metadata->time_value & 0x00FFFFFFUL;
    if (metadata->time_base_frame != 0U) {
        device->base_time_s = metadata->time_value;
        device->timestamp_valid = 1U;
        metadata->base_time_s = device->base_time_s;
        metadata->timestamp_valid = 1U;
        metadata->elapsed_10ms = 0U;
    } else if (((time_registers[0] & 0x01U) != 0U) &&
               (device->timestamp_valid != 0U)) {
        metadata->timestamp_valid = 1U;
    }
    metadata->timestamp_ms = ((uint64_t)metadata->base_time_s * 1000ULL) +
                             ((uint64_t)metadata->elapsed_10ms * 10ULL);

    device->frame_open = 1U;
    device->frame_length = head[3];
    device->frame_bytes_read = 0U;

    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_read_payload(
    fpga_rx_spi_t *device,
    uint8_t *data,
    size_t requested,
    size_t *bytes_read)
{
    size_t remaining;
    size_t amount;
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (bytes_read == NULL) ||
        ((requested != 0U) && (data == NULL))) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    *bytes_read = 0U;
    if (device->frame_open == 0U) {
        return FPGA_RX_SPI_BAD_STATE;
    }

    remaining = (size_t)device->frame_length -
                (size_t)device->frame_bytes_read;
    amount = requested;
    if (amount > remaining) {
        amount = remaining;
    }
    if (amount == 0U) {
        return FPGA_RX_SPI_OK;
    }

    result = fpga_rx_spi_read_stream(
        device, FPGA_RX_REG_RX_DATA, data, amount);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    device->frame_bytes_read = (uint8_t)(device->frame_bytes_read + amount);
    *bytes_read = amount;
    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_pop_frame(fpga_rx_spi_t *device)
{
    fpga_rx_spi_result_t result;

    if (device == NULL) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    if ((device->frame_open == 0U) ||
        (device->frame_bytes_read != device->frame_length)) {
        return FPGA_RX_SPI_BAD_STATE;
    }

    result = fpga_rx_spi_write_control(device, FPGA_RX_CONTROL_POP_FRAME);
    if (result == FPGA_RX_SPI_OK) {
        fpga_rx_spi_close_frame(device);
    }
    return result;
}

fpga_rx_spi_result_t fpga_rx_spi_drop_frame(fpga_rx_spi_t *device)
{
    fpga_rx_spi_result_t result;

    if (device == NULL) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    if (device->frame_open == 0U) {
        return FPGA_RX_SPI_BAD_STATE;
    }

    result = fpga_rx_spi_write_control(device, FPGA_RX_CONTROL_DROP_FRAME);
    if (result == FPGA_RX_SPI_OK) {
        fpga_rx_spi_close_frame(device);
    }
    return result;
}

fpga_rx_spi_result_t fpga_rx_spi_clear_errors(fpga_rx_spi_t *device)
{
    return fpga_rx_spi_write_control(device, FPGA_RX_CONTROL_CLEAR_ERRORS);
}

fpga_rx_spi_result_t fpga_rx_spi_adc_reinitialize(fpga_rx_spi_t *device)
{
    return fpga_rx_spi_write_control(device, FPGA_RX_CONTROL_ADC_REINIT);
}

fpga_rx_spi_result_t fpga_rx_spi_snapshot_start(fpga_rx_spi_t *device)
{
    return fpga_rx_spi_write_control(device, FPGA_RX_CONTROL_SNAPSHOT_START);
}

fpga_rx_spi_result_t fpga_rx_spi_snapshot_word_count(
    fpga_rx_spi_t *device,
    uint16_t *word_count)
{
    uint8_t registers[2];
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (word_count == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_SNAPSHOT_COUNT_L, registers, sizeof(registers));
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    *word_count = (uint16_t)registers[0] |
                  ((uint16_t)(registers[1] & 0x07U) << 8);
    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_snapshot_ready(
    fpga_rx_spi_t *device,
    bool *ready,
    bool *busy)
{
    uint8_t status;
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (ready == NULL) || (busy == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_read_registers(
        device, FPGA_RX_REG_STATUS0, &status, 1U);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }

    *busy = (status & FPGA_RX_STATUS_SNAPSHOT_BUSY) != 0U;
    *ready = ((status & FPGA_RX_STATUS_SNAPSHOT_AVAILABLE) != 0U) && !*busy;
    return FPGA_RX_SPI_OK;
}

fpga_rx_spi_result_t fpga_rx_spi_snapshot_read_bytes(
    fpga_rx_spi_t *device,
    uint8_t *data,
    size_t length)
{
    uint16_t word_count;
    fpga_rx_spi_result_t result;

    if ((device == NULL) || ((length != 0U) && (data == NULL))) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    if ((length & 0x03U) != 0U) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }
    result = fpga_rx_spi_snapshot_word_count(device, &word_count);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    if ((length / 4U) > (size_t)word_count) {
        return FPGA_RX_SPI_BAD_STATE;
    }
    return fpga_rx_spi_read_stream(
        device, FPGA_RX_REG_SNAPSHOT_DATA, data, length);
}

fpga_rx_spi_result_t fpga_rx_spi_snapshot_read_all(
    fpga_rx_spi_t *device,
    int32_t samples[FPGA_RX_SPI_SNAPSHOT_WORDS])
{
    uint8_t bytes[FPGA_RX_SPI_IO_CHUNK];
    uint16_t word_count;
    size_t sample_index = 0U;
    fpga_rx_spi_result_t result;

    if ((device == NULL) || (samples == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    result = fpga_rx_spi_snapshot_word_count(device, &word_count);
    if (result != FPGA_RX_SPI_OK) {
        return result;
    }
    if (word_count != FPGA_RX_SPI_SNAPSHOT_WORDS) {
        return FPGA_RX_SPI_BAD_STATE;
    }

    while (sample_index < FPGA_RX_SPI_SNAPSHOT_WORDS) {
        size_t byte_index;
        result = fpga_rx_spi_read_stream(
            device, FPGA_RX_REG_SNAPSHOT_DATA, bytes, sizeof(bytes));
        if (result != FPGA_RX_SPI_OK) {
            return result;
        }

        for (byte_index = 0U; byte_index < sizeof(bytes); byte_index += 4U) {
            uint32_t value = ((uint32_t)bytes[byte_index] << 24) |
                             ((uint32_t)bytes[byte_index + 1U] << 16) |
                             ((uint32_t)bytes[byte_index + 2U] << 8) |
                             (uint32_t)bytes[byte_index + 3U];
            samples[sample_index++] = (int32_t)value;
        }
    }

    return FPGA_RX_SPI_OK;
}

#if defined(FPGA_RX_SPI_ENABLE_STM32_HAL)
static fpga_rx_spi_result_t fpga_rx_spi_hal_transfer(
    void *context,
    const uint8_t *tx_data,
    uint8_t *rx_data,
    size_t length,
    uint32_t timeout_ms)
{
    fpga_rx_spi_hal_context_t *hal_context =
        (fpga_rx_spi_hal_context_t *)context;
    HAL_StatusTypeDef hal_result;

    if ((hal_context == NULL) || (hal_context->hspi == NULL) ||
        (length > UINT16_MAX)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    hal_result = HAL_SPI_TransmitReceive(
        hal_context->hspi,
        (uint8_t *)tx_data,
        rx_data,
        (uint16_t)length,
        timeout_ms);
    return (hal_result == HAL_OK) ? FPGA_RX_SPI_OK : FPGA_RX_SPI_IO_ERROR;
}

static void fpga_rx_spi_hal_chip_select(void *context, bool selected)
{
    fpga_rx_spi_hal_context_t *hal_context =
        (fpga_rx_spi_hal_context_t *)context;

    if ((hal_context != NULL) && (hal_context->nss_port != NULL)) {
        HAL_GPIO_WritePin(
            hal_context->nss_port,
            hal_context->nss_pin,
            selected ? GPIO_PIN_RESET : GPIO_PIN_SET);
    }
}

fpga_rx_spi_result_t fpga_rx_spi_init_hal(
    fpga_rx_spi_t *device,
    fpga_rx_spi_hal_context_t *hal_context,
    SPI_HandleTypeDef *hspi,
    GPIO_TypeDef *nss_port,
    uint16_t nss_pin,
    uint32_t timeout_ms)
{
    fpga_rx_spi_bus_t bus;

    if ((device == NULL) || (hal_context == NULL) || (hspi == NULL) ||
        (nss_port == NULL)) {
        return FPGA_RX_SPI_INVALID_ARGUMENT;
    }

    hal_context->hspi = hspi;
    hal_context->nss_port = nss_port;
    hal_context->nss_pin = nss_pin;

    bus.transfer = fpga_rx_spi_hal_transfer;
    bus.chip_select = fpga_rx_spi_hal_chip_select;
    bus.context = hal_context;
    bus.timeout_ms = timeout_ms;
    return fpga_rx_spi_init(device, &bus);
}
#endif
