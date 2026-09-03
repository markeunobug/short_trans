#ifndef FSK_TX_H
#define FSK_TX_H

#ifdef __cplusplus
extern "C" {
#endif

#include "stm32g4xx_hal.h"

#include <stddef.h>
#include <stdint.h>

#define FSK_TX_SAMPLE_RATE_HZ          48000UL
#define FSK_TX_BIT_RATE_BPS            100UL
#define FSK_TX_SYMBOL_SAMPLES          480U
#define FSK_TX_DMA_HALF_SAMPLES        FSK_TX_SYMBOL_SAMPLES
#define FSK_TX_DMA_SAMPLES             (2U * FSK_TX_DMA_HALF_SAMPLES)
#define FSK_TX_FREQUENCY_BIT0_HZ       1600UL
#define FSK_TX_FREQUENCY_BIT1_HZ       2000UL
#define FSK_TX_DAC_MIDPOINT            2048U
#define FSK_TX_MAX_AMPLITUDE           2047U
#define FSK_TX_DEFAULT_AMPLITUDE       256U
#define FSK_TX_MAX_PAYLOAD_BYTES       64U
#define FSK_TX_PREAMBLE                0xAAAAU
#define FSK_TX_INTERFRAME_SILENCE_MS   100U

/* Selected by the exhaustive sync-word search in the RX FPGA project. */
#define FSK_TX_SYNC_WORD               0x06B7U
#define FSK_TX_SYNC_WORD_IS_FROZEN     1U

typedef enum
{
    FSK_TX_MODE_SILENCE = 0,
    FSK_TX_MODE_TONE_1600,
    FSK_TX_MODE_TONE_2000,
    FSK_TX_MODE_ALTERNATING_01,
    FSK_TX_MODE_PRBS,
    FSK_TX_MODE_PACKET
} FskTx_Mode;

typedef enum
{
    FSK_TX_OK = 0,
    FSK_TX_ERROR_ARGUMENT,
    FSK_TX_ERROR_NOT_INITIALIZED,
    FSK_TX_ERROR_HAL,
    FSK_TX_ERROR_TIMER_RATE,
    FSK_TX_ERROR_PAYLOAD_TOO_LONG,
    FSK_TX_ERROR_SYNC_WORD_UNAVAILABLE,
    FSK_TX_ERROR_COMMAND
} FskTx_Result;

typedef struct
{
    uint8_t initialized;
    uint8_t running;
    FskTx_Mode selected_mode;
    FskTx_Mode active_mode;
    uint16_t amplitude;
    uint8_t payload_length;
    uint8_t version;
    uint8_t frame_type;
    uint8_t sequence;
    uint32_t timer_clock_hz;
    uint32_t sample_rate_hz;
    uint32_t rendered_symbols;
    uint32_t dma_error_count;
    FskTx_Result last_error;
    uint32_t dma_hal_error;
    uint32_t dac_hal_error;
    uint32_t dma_remaining;
    uint32_t dma_ccr;
} FskTx_Status;

FskTx_Result FskTx_Init(DAC_HandleTypeDef *hdac, TIM_HandleTypeDef *htim);
FskTx_Result FskTx_SetAmplitude(uint16_t amplitude);
FskTx_Result FskTx_SetPayload(const uint8_t *payload, uint8_t length);
FskTx_Result FskTx_SetFrameMetadata(uint8_t version,
                                    uint8_t frame_type,
                                    uint8_t sequence);
FskTx_Result FskTx_SelectMode(FskTx_Mode mode);
FskTx_Result FskTx_Start(void);
FskTx_Result FskTx_Stop(void);
void FskTx_GetStatus(FskTx_Status *status);

/*
 * Parses one NUL-terminated UART command line without owning a UART handle or
 * receive state machine. The caller may send the returned ASCII response.
 */
FskTx_Result FskTx_HandleUartCommand(const char *line,
                                     char *response,
                                     size_t response_size);

uint8_t FskTx_Crc8Atm(const uint8_t *data, size_t length);
uint16_t FskTx_Crc16CcittFalse(const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* FSK_TX_H */
