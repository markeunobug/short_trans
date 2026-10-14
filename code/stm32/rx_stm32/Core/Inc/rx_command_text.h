#ifndef RX_COMMAND_TEXT_H
#define RX_COMMAND_TEXT_H

#include <stddef.h>
#include <stdint.h>

size_t rx_command_append_u32(
    char *destination,
    size_t capacity,
    size_t used,
    uint32_t value);

uint8_t rx_command_parse_u32_fields(
    const char *text,
    uint32_t *fields,
    uint8_t field_count);

#endif
