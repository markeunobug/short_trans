#include "rx_command_text.h"

#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            (void)fprintf(stderr, "FAIL:%d: %s\n", __LINE__, #condition);    \
            return 1;                                                           \
        }                                                                       \
    } while (0)

int main(void)
{
    uint32_t fields[2];
    char text[32];
    size_t used;

    CHECK(rx_command_parse_u32_fields("0 4294967295", fields, 2U) == 1U);
    CHECK(fields[0] == 0U);
    CHECK(fields[1] == UINT32_MAX);
    CHECK(rx_command_parse_u32_fields("4294967296 1", fields, 2U) == 0U);
    CHECK(rx_command_parse_u32_fields("1+2", fields, 2U) == 0U);
    CHECK(rx_command_parse_u32_fields("12", fields, 2U) == 0U);
    CHECK(rx_command_parse_u32_fields("1\t2", fields, 2U) == 1U);
    CHECK(rx_command_parse_u32_fields("1 2x", fields, 2U) == 0U);

    text[0] = '\0';
    used = rx_command_append_u32(text, sizeof(text), 0U, UINT32_MAX);
    CHECK(used == strlen("4294967295"));
    CHECK(strcmp(text, "4294967295") == 0);
    CHECK(rx_command_append_u32(text, 5U, 0U, UINT32_MAX) == 4U);
    CHECK(strcmp(text, "4294") == 0);
    (void)printf("PASS: command uint32 parser and formatter boundaries verified\n");
    return 0;
}
