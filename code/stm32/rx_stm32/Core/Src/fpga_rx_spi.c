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
        (address == FPGA_RX_REG_SNAPSHOT_DATA)) {
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
        (address == FPGA_RX_REG_SNAPSHOT_DATA)) {
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

fpga_rx_spi_result_t fpga_rx_spi_begin_frame(
    fpga_rx_spi_t *device,
    fpga_rx_spi_frame_meta_t *metadata)
{
    uint8_t head[4];
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
