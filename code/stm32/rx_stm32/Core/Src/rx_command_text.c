#include "rx_command_text.h"

#include <limits.h>

size_t rx_command_append_u32(
    char *destination,
    size_t capacity,
    size_t used,
    uint32_t value)
{
    char digits[10];
    size_t count = 0U;

    if ((destination == NULL) || (used >= capacity)) {
        return used;
    }
    do {
        digits[count++] = (char)('0' + (value % 10U));
        value /= 10U;
    } while ((value != 0U) && (count < sizeof(digits)));

    while ((count != 0U) && ((used + 1U) < capacity)) {
        destination[used++] = digits[--count];
    }
    destination[used] = '\0';
    return used;
}

uint8_t rx_command_parse_u32_fields(
    const char *text,
    uint32_t *fields,
    uint8_t field_count)
{
    uint8_t index;

    if ((text == NULL) || (fields == NULL) || (field_count == 0U)) {
        return 0U;
    }
    for (index = 0U; index < field_count; ++index) {
        uint32_t value = 0U;
        uint8_t digit_seen = 0U;
        uint8_t separator_seen = 0U;

        while ((*text == ' ') || (*text == '\t')) {
            ++text;
        }
        while ((*text >= '0') && (*text <= '9')) {
            uint32_t digit = (uint32_t)(*text - '0');
            if (value > ((UINT32_MAX - digit) / 10U)) {
                return 0U;
            }
            value = (value * 10U) + digit;
            digit_seen = 1U;
            ++text;
        }
        if (digit_seen == 0U) {
            return 0U;
        }
        fields[index] = value;
        if ((index + 1U) < field_count) {
            while ((*text == ' ') || (*text == '\t')) {
                separator_seen = 1U;
                ++text;
            }
            if (separator_seen == 0U) {
                return 0U;
            }
        }
    }
    while ((*text == ' ') || (*text == '\t')) {
        ++text;
    }
    return (*text == '\0') ? 1U : 0U;
}
