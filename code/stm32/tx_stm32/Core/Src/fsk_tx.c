#include "fsk_tx.h"

#include <string.h>

#define FSK_TX_HEADER_BYTES             4U
#define FSK_TX_CRC16_BYTES              2U
#define FSK_TX_FRAME_BODY_MAX_BYTES     (FSK_TX_HEADER_BYTES + \
                                         FSK_TX_MAX_PAYLOAD_BYTES + \
                                         FSK_TX_CRC16_BYTES)
#define FSK_TX_SILENCE_SYMBOLS          (FSK_TX_INTERFRAME_SILENCE_MS / 10U)
#define FSK_TX_COMMAND_PAYLOAD_CHARS     (2U * FSK_TX_MAX_PAYLOAD_BYTES)

typedef enum
{
    PACKET_STAGE_PRE_SILENCE = 0,
    PACKET_STAGE_PREAMBLE,
    PACKET_STAGE_SYNC,
    PACKET_STAGE_BODY,
    PACKET_STAGE_POST_SILENCE,
    PACKET_STAGE_DONE
} FskTx_PacketStage;

typedef struct
{
    DAC_HandleTypeDef *hdac;
    TIM_HandleTypeDef *htim;
    uint16_t dma_buffer[FSK_TX_DMA_SAMPLES];
    uint8_t payload[FSK_TX_MAX_PAYLOAD_BYTES];
    uint8_t frame_body[FSK_TX_FRAME_BODY_MAX_BYTES];
    volatile uint8_t initialized;
    volatile uint8_t running;
    volatile FskTx_Mode selected_mode;
    volatile FskTx_Mode active_mode;
    volatile uint16_t amplitude;
    volatile uint8_t payload_length;
    volatile uint8_t version;
    volatile uint8_t frame_type;
    volatile uint8_t sequence;
    volatile uint32_t rendered_symbols;
    volatile uint32_t dma_error_count;
    volatile FskTx_Result last_error;
    uint32_t timer_clock_hz;
    uint32_t sample_rate_hz;
    uint16_t frame_body_length;
    uint16_t packet_bit_index;
    uint8_t silence_symbols_remaining;
    uint8_t alternating_bit;
    uint8_t prbs_state;
    FskTx_PacketStage packet_stage;
} FskTx_Context;

static FskTx_Context s_tx;

static const int16_t s_sine_1600[30] = {
         0,   6813,  13328,  19260,  24351,  28377,  31163,  32587,
     32587,  31163,  28377,  24351,  19260,  13328,   6813,      0,
     -6813, -13328, -19260, -24351, -28377, -31163, -32587, -32587,
    -31163, -28377, -24351, -19260, -13328,  -6813
};

static const int16_t s_sine_2000[24] = {
         0,   8481,  16383,  23170,  28377,  31650,  32767,  31650,
     28377,  23170,  16383,   8481,      0,  -8481, -16383, -23170,
    -28377, -31650, -32767, -31650, -28377, -23170, -16384,  -8481
};

static uint32_t FskTx_EnterCritical(void)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    return primask;
}

static void FskTx_ExitCritical(uint32_t primask)
{
    if (primask == 0U)
    {
        __enable_irq();
    }
}

static uint32_t FskTx_GetTim4ClockHz(void)
{
    uint32_t pclk1 = HAL_RCC_GetPCLK1Freq();

    if (pclk1 == HAL_RCC_GetHCLKFreq())
    {
        return pclk1;
    }

    return 2U * pclk1;
}

static uint8_t FskTx_FindTimerDividers(uint32_t timer_clock_hz,
                                       uint16_t *prescaler,
                                       uint16_t *period)
{
    uint32_t total_divider;
    uint32_t psc_divider;
    uint32_t arr_divider;

    if ((timer_clock_hz == 0U) ||
        ((timer_clock_hz % FSK_TX_SAMPLE_RATE_HZ) != 0U))
    {
        return 0U;
    }

    total_divider = timer_clock_hz / FSK_TX_SAMPLE_RATE_HZ;

    /* Prefer PSC=4. At the current 150 MHz clock this gives ARR=624. */
    if (((total_divider % 5U) == 0U) && ((total_divider / 5U) <= 65536U))
    {
        *prescaler = 4U;
        *period = (uint16_t)((total_divider / 5U) - 1U);
        return 1U;
    }

    for (psc_divider = 1U; psc_divider <= 65536U; ++psc_divider)
    {
        if ((total_divider % psc_divider) != 0U)
        {
            continue;
        }

        arr_divider = total_divider / psc_divider;
        if ((arr_divider >= 1U) && (arr_divider <= 65536U))
        {
            *prescaler = (uint16_t)(psc_divider - 1U);
            *period = (uint16_t)(arr_divider - 1U);
            return 1U;
        }
    }

    return 0U;
}

uint8_t FskTx_Crc8Atm(const uint8_t *data, size_t length)
{
    uint8_t crc = 0x00U;
    size_t index;
    uint8_t bit;

    if ((data == NULL) && (length != 0U))
    {
        return 0U;
    }

    for (index = 0U; index < length; ++index)
    {
        crc ^= data[index];
        for (bit = 0U; bit < 8U; ++bit)
        {
            crc = ((crc & 0x80U) != 0U)
                      ? (uint8_t)((crc << 1U) ^ 0x07U)
                      : (uint8_t)(crc << 1U);
        }
    }

    return crc;
}

uint16_t FskTx_Crc16CcittFalse(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xFFFFU;
    size_t index;
    uint8_t bit;

    if ((data == NULL) && (length != 0U))
    {
        return 0U;
    }

    for (index = 0U; index < length; ++index)
    {
        crc ^= (uint16_t)((uint16_t)data[index] << 8U);
        for (bit = 0U; bit < 8U; ++bit)
        {
            crc = ((crc & 0x8000U) != 0U)
                      ? (uint16_t)((crc << 1U) ^ 0x1021U)
                      : (uint16_t)(crc << 1U);
        }
    }

    return crc;
}

static void FskTx_BuildFrameBody(void)
{
    uint16_t crc16;
    uint8_t payload_length = s_tx.payload_length;

    s_tx.frame_body[0] = (uint8_t)((s_tx.version << 4U) |
                                   (s_tx.frame_type & 0x0FU));
    s_tx.frame_body[1] = s_tx.sequence;
    s_tx.frame_body[2] = payload_length;
    s_tx.frame_body[3] = FskTx_Crc8Atm(s_tx.frame_body, 3U);

    if (payload_length != 0U)
    {
        memcpy(&s_tx.frame_body[FSK_TX_HEADER_BYTES],
               s_tx.payload,
               payload_length);
    }

    crc16 = FskTx_Crc16CcittFalse(s_tx.frame_body,
                                  FSK_TX_HEADER_BYTES + payload_length);
    s_tx.frame_body[FSK_TX_HEADER_BYTES + payload_length] =
        (uint8_t)(crc16 >> 8U);
    s_tx.frame_body[FSK_TX_HEADER_BYTES + payload_length + 1U] =
        (uint8_t)crc16;
    s_tx.frame_body_length = (uint16_t)(FSK_TX_HEADER_BYTES +
                                        payload_length +
                                        FSK_TX_CRC16_BYTES);
}

static void FskTx_ResetGenerator(FskTx_Mode mode)
{
    s_tx.active_mode = mode;
    s_tx.alternating_bit = 0U;
    s_tx.prbs_state = 0x5DU;
    s_tx.packet_bit_index = 0U;
    s_tx.silence_symbols_remaining = 0U;
    s_tx.packet_stage = PACKET_STAGE_DONE;

    if (mode == FSK_TX_MODE_PACKET)
    {
        FskTx_BuildFrameBody();
        s_tx.packet_stage = PACKET_STAGE_PRE_SILENCE;
        s_tx.silence_symbols_remaining = FSK_TX_SILENCE_SYMBOLS;
    }
}

static uint8_t FskTx_GetWordBit(uint16_t word, uint16_t bit_index)
{
    return (uint8_t)((word >> (15U - bit_index)) & 1U);
}

static uint8_t FskTx_GetBodyBit(uint16_t bit_index)
{
    uint16_t byte_index = bit_index / 8U;
    uint8_t shift = (uint8_t)(7U - (bit_index % 8U));
    return (uint8_t)((s_tx.frame_body[byte_index] >> shift) & 1U);
}

static int8_t FskTx_NextPacketSymbol(void)
{
    uint8_t bit_value;

    for (;;)
    {
        switch (s_tx.packet_stage)
        {
            case PACKET_STAGE_PRE_SILENCE:
                if (s_tx.silence_symbols_remaining != 0U)
                {
                    --s_tx.silence_symbols_remaining;
                    return -1;
                }
                s_tx.packet_stage = PACKET_STAGE_PREAMBLE;
                s_tx.packet_bit_index = 0U;
                break;

            case PACKET_STAGE_PREAMBLE:
                bit_value = FskTx_GetWordBit(FSK_TX_PREAMBLE,
                                             s_tx.packet_bit_index++);
                if (s_tx.packet_bit_index == 16U)
                {
                    s_tx.packet_stage = PACKET_STAGE_SYNC;
                    s_tx.packet_bit_index = 0U;
                }
                return (int8_t)bit_value;

            case PACKET_STAGE_SYNC:
                bit_value = FskTx_GetWordBit(FSK_TX_SYNC_WORD,
                                             s_tx.packet_bit_index++);
                if (s_tx.packet_bit_index == 16U)
                {
                    s_tx.packet_stage = PACKET_STAGE_BODY;
                    s_tx.packet_bit_index = 0U;
                }
                return (int8_t)bit_value;

            case PACKET_STAGE_BODY:
                bit_value = FskTx_GetBodyBit(s_tx.packet_bit_index++);
                if (s_tx.packet_bit_index == (uint16_t)(8U * s_tx.frame_body_length))
                {
                    s_tx.packet_stage = PACKET_STAGE_POST_SILENCE;
                    s_tx.silence_symbols_remaining = FSK_TX_SILENCE_SYMBOLS;
                }
                return (int8_t)bit_value;

            case PACKET_STAGE_POST_SILENCE:
                if (s_tx.silence_symbols_remaining != 0U)
                {
                    --s_tx.silence_symbols_remaining;
                    return -1;
                }
                s_tx.packet_stage = PACKET_STAGE_DONE;
                s_tx.running = 0U;
                s_tx.active_mode = FSK_TX_MODE_SILENCE;
                break;

            case PACKET_STAGE_DONE:
            default:
                return -1;
        }
    }
}

static int8_t FskTx_NextSymbol(void)
{
    uint8_t output_bit;
    uint8_t feedback;

    switch (s_tx.active_mode)
    {
        case FSK_TX_MODE_TONE_1600:
            return 0;

        case FSK_TX_MODE_TONE_2000:
            return 1;

        case FSK_TX_MODE_ALTERNATING_01:
            output_bit = s_tx.alternating_bit;
            s_tx.alternating_bit ^= 1U;
            return (int8_t)output_bit;

        case FSK_TX_MODE_PRBS:
            output_bit = (uint8_t)(s_tx.prbs_state & 1U);
            feedback = (uint8_t)(((s_tx.prbs_state >> 6U) ^
                                  (s_tx.prbs_state >> 5U)) & 1U);
            s_tx.prbs_state = (uint8_t)(((s_tx.prbs_state << 1U) & 0x7EU) |
                                        feedback);
            if (s_tx.prbs_state == 0U)
            {
                s_tx.prbs_state = 0x5DU;
            }
            return (int8_t)output_bit;

        case FSK_TX_MODE_PACKET:
            return FskTx_NextPacketSymbol();

        case FSK_TX_MODE_SILENCE:
        default:
            return -1;
    }
}

static uint16_t FskTx_ScaleSample(int16_t q15_sample)
{
    int32_t scaled = ((int32_t)q15_sample * (int32_t)s_tx.amplitude);

    if (scaled >= 0)
    {
        scaled = (scaled + 16384) / 32768;
    }
    else
    {
        scaled = (scaled - 16384) / 32768;
    }

    scaled += (int32_t)FSK_TX_DAC_MIDPOINT;
    if (scaled < 0)
    {
        scaled = 0;
    }
    else if (scaled > 4095)
    {
        scaled = 4095;
    }

    return (uint16_t)scaled;
}

static void FskTx_RenderHalf(uint16_t *destination)
{
    const int16_t *table;
    uint16_t table_length;
    uint16_t index;
    int8_t symbol = FskTx_NextSymbol();

    if (symbol < 0)
    {
        for (index = 0U; index < FSK_TX_DMA_HALF_SAMPLES; ++index)
        {
            destination[index] = FSK_TX_DAC_MIDPOINT;
        }
    }
    else
    {
        table = (symbol == 0) ? s_sine_1600 : s_sine_2000;
        table_length = (symbol == 0) ? 30U : 24U;

        for (index = 0U; index < FSK_TX_DMA_HALF_SAMPLES; ++index)
        {
            destination[index] = FskTx_ScaleSample(table[index % table_length]);
        }
    }

    ++s_tx.rendered_symbols;
}

static FskTx_Result FskTx_RestartDmaStream(void)
{
    HAL_StatusTypeDef hal_status;

    (void)HAL_TIM_Base_Stop(s_tx.htim);
    (void)HAL_DAC_Stop_DMA(s_tx.hdac, DAC_CHANNEL_1);

    FskTx_RenderHalf(&s_tx.dma_buffer[0]);
    FskTx_RenderHalf(&s_tx.dma_buffer[FSK_TX_DMA_HALF_SAMPLES]);

    hal_status = HAL_DAC_Start_DMA(s_tx.hdac,
                                  DAC_CHANNEL_1,
                                  (const uint32_t *)s_tx.dma_buffer,
                                  FSK_TX_DMA_SAMPLES,
                                  DAC_ALIGN_12B_R);
    if (hal_status != HAL_OK)
    {
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }

    hal_status = HAL_TIM_Base_Start(s_tx.htim);
    if (hal_status != HAL_OK)
    {
        (void)HAL_DAC_Stop_DMA(s_tx.hdac, DAC_CHANNEL_1);
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }

    return FSK_TX_OK;
}

FskTx_Result FskTx_Init(DAC_HandleTypeDef *hdac, TIM_HandleTypeDef *htim)
{
    TIM_MasterConfigTypeDef master_config = {0};
    DMA_HandleTypeDef *hdma;
    uint16_t prescaler;
    uint16_t period;

    if ((hdac == NULL) || (htim == NULL) ||
        (hdac->Instance != DAC1) || (htim->Instance != TIM4) ||
        (hdac->DMA_Handle1 == NULL))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    memset(&s_tx, 0, sizeof(s_tx));
    s_tx.hdac = hdac;
    s_tx.htim = htim;
    s_tx.amplitude = FSK_TX_DEFAULT_AMPLITUDE;
    s_tx.version = 1U;
    s_tx.frame_type = 0U;
    s_tx.selected_mode = FSK_TX_MODE_SILENCE;
    s_tx.active_mode = FSK_TX_MODE_SILENCE;
    s_tx.last_error = FSK_TX_OK;
    s_tx.timer_clock_hz = FskTx_GetTim4ClockHz();

    if (FskTx_FindTimerDividers(s_tx.timer_clock_hz,
                                &prescaler,
                                &period) == 0U)
    {
        s_tx.last_error = FSK_TX_ERROR_TIMER_RATE;
        return FSK_TX_ERROR_TIMER_RATE;
    }

    (void)HAL_TIM_Base_Stop(htim);
    htim->Init.Prescaler = prescaler;
    htim->Init.Period = period;
    htim->Init.CounterMode = TIM_COUNTERMODE_UP;
    htim->Init.ClockDivision = TIM_CLOCKDIVISION_DIV1;
    htim->Init.AutoReloadPreload = TIM_AUTORELOAD_PRELOAD_DISABLE;
    if (HAL_TIM_Base_Init(htim) != HAL_OK)
    {
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }

    master_config.MasterOutputTrigger = TIM_TRGO_UPDATE;
    master_config.MasterSlaveMode = TIM_MASTERSLAVEMODE_DISABLE;
    if (HAL_TIMEx_MasterConfigSynchronization(htim, &master_config) != HAL_OK)
    {
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }

    s_tx.sample_rate_hz = s_tx.timer_clock_hz /
                          ((uint32_t)(prescaler + 1U) *
                           (uint32_t)(period + 1U));
    if (s_tx.sample_rate_hz != FSK_TX_SAMPLE_RATE_HZ)
    {
        s_tx.last_error = FSK_TX_ERROR_TIMER_RATE;
        return FSK_TX_ERROR_TIMER_RATE;
    }

    hdma = hdac->DMA_Handle1;
    (void)HAL_DMA_Abort(hdma);
    if (HAL_DMA_DeInit(hdma) != HAL_OK)
    {
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }
    /* STM32G4 DAC DHR registers require word-sized peripheral DMA writes. */
    hdma->Init.PeriphDataAlignment = DMA_PDATAALIGN_WORD;
    hdma->Init.MemDataAlignment = DMA_MDATAALIGN_HALFWORD;
    hdma->Init.Mode = DMA_CIRCULAR;
    if (HAL_DMA_Init(hdma) != HAL_OK)
    {
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }
    hdma->Parent = hdac;

    if (HAL_DAC_SetValue(hdac,
                         DAC_CHANNEL_1,
                         DAC_ALIGN_12B_R,
                         FSK_TX_DAC_MIDPOINT) != HAL_OK)
    {
        s_tx.last_error = FSK_TX_ERROR_HAL;
        return FSK_TX_ERROR_HAL;
    }

    s_tx.initialized = 1U;
    FskTx_ResetGenerator(FSK_TX_MODE_SILENCE);
    if (FskTx_RestartDmaStream() != FSK_TX_OK)
    {
        s_tx.initialized = 0U;
        return FSK_TX_ERROR_HAL;
    }

    return FSK_TX_OK;
}

FskTx_Result FskTx_SetAmplitude(uint16_t amplitude)
{
    uint32_t primask;

    if (amplitude > FSK_TX_MAX_AMPLITUDE)
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    primask = FskTx_EnterCritical();
    s_tx.amplitude = amplitude;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
}

FskTx_Result FskTx_SetPayload(const uint8_t *payload, uint8_t length)
{
    uint32_t primask;

    if (length > FSK_TX_MAX_PAYLOAD_BYTES)
    {
        return FSK_TX_ERROR_PAYLOAD_TOO_LONG;
    }
    if ((payload == NULL) && (length != 0U))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    primask = FskTx_EnterCritical();
    if (length != 0U)
    {
        memcpy(s_tx.payload, payload, length);
    }
    s_tx.payload_length = length;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
}

FskTx_Result FskTx_SetFrameMetadata(uint8_t version,
                                    uint8_t frame_type,
                                    uint8_t sequence)
{
    uint32_t primask;

    if ((version > 0x0FU) || (frame_type > 0x0FU))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    primask = FskTx_EnterCritical();
    s_tx.version = version;
    s_tx.frame_type = frame_type;
    s_tx.sequence = sequence;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
}

FskTx_Result FskTx_SelectMode(FskTx_Mode mode)
{
    if (mode > FSK_TX_MODE_PACKET)
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    s_tx.selected_mode = mode;
    return FSK_TX_OK;
}

FskTx_Result FskTx_Start(void)
{
    FskTx_Result result;
    uint32_t primask;

    if (s_tx.initialized == 0U)
    {
        return FSK_TX_ERROR_NOT_INITIALIZED;
    }

    if ((s_tx.selected_mode == FSK_TX_MODE_PACKET) &&
        (FSK_TX_SYNC_WORD_IS_FROZEN == 0U))
    {
        s_tx.last_error = FSK_TX_ERROR_SYNC_WORD_UNAVAILABLE;
        return FSK_TX_ERROR_SYNC_WORD_UNAVAILABLE;
    }

    primask = FskTx_EnterCritical();
    FskTx_ResetGenerator(s_tx.selected_mode);
    s_tx.running = (s_tx.selected_mode != FSK_TX_MODE_SILENCE) ? 1U : 0U;
    result = FskTx_RestartDmaStream();
    s_tx.last_error = result;
    FskTx_ExitCritical(primask);
    return result;
}

FskTx_Result FskTx_Stop(void)
{
    FskTx_Result result;
    uint32_t primask;

    if (s_tx.initialized == 0U)
    {
        return FSK_TX_ERROR_NOT_INITIALIZED;
    }

    primask = FskTx_EnterCritical();
    s_tx.running = 0U;
    FskTx_ResetGenerator(FSK_TX_MODE_SILENCE);
    result = FskTx_RestartDmaStream();
    s_tx.last_error = result;
    FskTx_ExitCritical(primask);
    return result;
}

void FskTx_GetStatus(FskTx_Status *status)
{
    uint32_t primask;

    if (status == NULL)
    {
        return;
    }

    primask = FskTx_EnterCritical();
    status->initialized = s_tx.initialized;
    status->running = s_tx.running;
    status->selected_mode = s_tx.selected_mode;
    status->active_mode = s_tx.active_mode;
    status->amplitude = s_tx.amplitude;
    status->payload_length = s_tx.payload_length;
    status->version = s_tx.version;
    status->frame_type = s_tx.frame_type;
    status->sequence = s_tx.sequence;
    status->timer_clock_hz = s_tx.timer_clock_hz;
    status->sample_rate_hz = s_tx.sample_rate_hz;
    status->rendered_symbols = s_tx.rendered_symbols;
    status->dma_error_count = s_tx.dma_error_count;
    status->last_error = s_tx.last_error;
    status->dma_hal_error = HAL_DMA_GetError(s_tx.hdac->DMA_Handle1);
    status->dac_hal_error = HAL_DAC_GetError(s_tx.hdac);
    status->dma_remaining = __HAL_DMA_GET_COUNTER(s_tx.hdac->DMA_Handle1);
    status->dma_ccr = s_tx.hdac->DMA_Handle1->Instance->CCR;
    FskTx_ExitCritical(primask);
}

static const char *FskTx_SkipSpaces(const char *text)
{
    while ((*text == ' ') || (*text == '\t'))
    {
        ++text;
    }
    return text;
}

static uint8_t FskTx_CharUpper(uint8_t value)
{
    if ((value >= (uint8_t)'a') && (value <= (uint8_t)'z'))
    {
        value = (uint8_t)(value - ((uint8_t)'a' - (uint8_t)'A'));
    }
    return value;
}

static uint8_t FskTx_TokenEquals(const char *text, const char *token)
{
    while ((*token != '\0') && (*text != '\0'))
    {
        if (FskTx_CharUpper((uint8_t)*text) != (uint8_t)*token)
        {
            return 0U;
        }
        ++text;
        ++token;
    }

    return (uint8_t)((*token == '\0') &&
                     ((*text == '\0') || (*text == ' ') || (*text == '\t')));
}

static uint8_t FskTx_ArgumentEquals(const char *text, const char *token)
{
    while ((*token != '\0') && (*text != '\0'))
    {
        if (FskTx_CharUpper((uint8_t)*text) != (uint8_t)*token)
        {
            return 0U;
        }
        ++text;
        ++token;
    }

    return (uint8_t)((*token == '\0') && (*FskTx_SkipSpaces(text) == '\0'));
}

static const char *FskTx_AfterToken(const char *text)
{
    while ((*text != '\0') && (*text != ' ') && (*text != '\t'))
    {
        ++text;
    }
    return FskTx_SkipSpaces(text);
}

static uint8_t FskTx_ParseUnsigned(const char *text,
                                   uint32_t maximum,
                                   uint32_t *value)
{
    uint32_t parsed = 0U;
    uint8_t digit_seen = 0U;

    text = FskTx_SkipSpaces(text);
    while ((*text >= '0') && (*text <= '9'))
    {
        digit_seen = 1U;
        parsed = (parsed * 10U) + (uint32_t)(*text - '0');
        if (parsed > maximum)
        {
            return 0U;
        }
        ++text;
    }

    text = FskTx_SkipSpaces(text);
    if ((digit_seen == 0U) || (*text != '\0'))
    {
        return 0U;
    }

    *value = parsed;
    return 1U;
}

static int8_t FskTx_HexNibble(char value)
{
    value = (char)FskTx_CharUpper((uint8_t)value);
    if ((value >= '0') && (value <= '9'))
    {
        return (int8_t)(value - '0');
    }
    if ((value >= 'A') && (value <= 'F'))
    {
        return (int8_t)(value - 'A' + 10);
    }
    return -1;
}

static FskTx_Result FskTx_ParsePayload(const char *text)
{
    uint8_t payload[FSK_TX_MAX_PAYLOAD_BYTES];
    size_t character_count;
    size_t index;
    int8_t high;
    int8_t low;

    text = FskTx_SkipSpaces(text);
    if ((*text == '\0') || ((*text == '-') && (text[1] == '\0')))
    {
        return FskTx_SetPayload(NULL, 0U);
    }

    character_count = strlen(text);
    if ((character_count > FSK_TX_COMMAND_PAYLOAD_CHARS) ||
        ((character_count & 1U) != 0U))
    {
        return FSK_TX_ERROR_COMMAND;
    }

    for (index = 0U; index < character_count; index += 2U)
    {
        high = FskTx_HexNibble(text[index]);
        low = FskTx_HexNibble(text[index + 1U]);
        if ((high < 0) || (low < 0))
        {
            return FSK_TX_ERROR_COMMAND;
        }
        payload[index / 2U] = (uint8_t)(((uint8_t)high << 4U) | (uint8_t)low);
    }

    return FskTx_SetPayload(payload, (uint8_t)(character_count / 2U));
}

static void FskTx_ResponseSet(char *response,
                              size_t response_size,
                              const char *text)
{
    size_t index = 0U;

    if ((response == NULL) || (response_size == 0U))
    {
        return;
    }

    while ((text[index] != '\0') && ((index + 1U) < response_size))
    {
        response[index] = text[index];
        ++index;
    }
    response[index] = '\0';
}

static size_t FskTx_AppendText(char *response,
                               size_t response_size,
                               size_t used,
                               const char *text)
{
    while ((*text != '\0') && ((used + 1U) < response_size))
    {
        response[used++] = *text++;
    }
    if (response_size != 0U)
    {
        response[used] = '\0';
    }
    return used;
}

static size_t FskTx_AppendUnsigned(char *response,
                                   size_t response_size,
                                   size_t used,
                                   uint32_t value)
{
    char digits[10];
    size_t count = 0U;

    do
    {
        digits[count++] = (char)('0' + (value % 10U));
        value /= 10U;
    } while ((value != 0U) && (count < sizeof(digits)));

    while ((count != 0U) && ((used + 1U) < response_size))
    {
        response[used++] = digits[--count];
    }
    if (response_size != 0U)
    {
        response[used] = '\0';
    }
    return used;
}

static FskTx_Result FskTx_CommandMode(const char *argument)
{
    if (FskTx_ArgumentEquals(argument, "SILENCE") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_SILENCE);
    }
    if (FskTx_ArgumentEquals(argument, "TONE1600") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_TONE_1600);
    }
    if (FskTx_ArgumentEquals(argument, "TONE2000") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_TONE_2000);
    }
    if (FskTx_ArgumentEquals(argument, "ALT") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_ALTERNATING_01);
    }
    if (FskTx_ArgumentEquals(argument, "PRBS") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_PRBS);
    }
    if (FskTx_ArgumentEquals(argument, "PACKET") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_PACKET);
    }
    return FSK_TX_ERROR_COMMAND;
}

FskTx_Result FskTx_HandleUartCommand(const char *line,
                                     char *response,
                                     size_t response_size)
{
    FskTx_Result result = FSK_TX_ERROR_COMMAND;
    FskTx_Status status;
    uint32_t value;
    size_t used;

    if (line == NULL)
    {
        FskTx_ResponseSet(response, response_size, "ERR ARG\r\n");
        return FSK_TX_ERROR_ARGUMENT;
    }

    if (response == NULL)
    {
        response_size = 0U;
    }

    line = FskTx_SkipSpaces(line);
    if (FskTx_TokenEquals(line, "HELP") != 0U)
    {
        FskTx_ResponseSet(response, response_size,
                          "OK AMP n | PAYLOAD hex|- | META v t seq | "
                          "MODE SILENCE|TONE1600|TONE2000|ALT|PRBS|PACKET | "
                          "SEND | STOP | STATUS\r\n");
        return FSK_TX_OK;
    }
    if (FskTx_TokenEquals(line, "AMP") != 0U)
    {
        if (FskTx_ParseUnsigned(FskTx_AfterToken(line),
                                FSK_TX_MAX_AMPLITUDE,
                                &value) != 0U)
        {
            result = FskTx_SetAmplitude((uint16_t)value);
        }
    }
    else if (FskTx_TokenEquals(line, "PAYLOAD") != 0U)
    {
        result = FskTx_ParsePayload(FskTx_AfterToken(line));
    }
    else if (FskTx_TokenEquals(line, "META") != 0U)
    {
        uint32_t fields[3];
        uint8_t field_index;
        const char *argument = FskTx_AfterToken(line);
        char token[4];

        result = FSK_TX_OK;
        for (field_index = 0U; field_index < 3U; ++field_index)
        {
            size_t token_length = 0U;
            argument = FskTx_SkipSpaces(argument);
            while ((*argument >= '0') && (*argument <= '9') &&
                   (token_length < (sizeof(token) - 1U)))
            {
                token[token_length++] = *argument++;
            }
            token[token_length] = '\0';
            if (FskTx_ParseUnsigned(token,
                                    (field_index < 2U) ? 15U : 255U,
                                    &fields[field_index]) == 0U)
            {
                result = FSK_TX_ERROR_COMMAND;
                break;
            }
        }
        if ((result == FSK_TX_OK) && (*FskTx_SkipSpaces(argument) == '\0'))
        {
            result = FskTx_SetFrameMetadata((uint8_t)fields[0],
                                            (uint8_t)fields[1],
                                            (uint8_t)fields[2]);
        }
        else
        {
            result = FSK_TX_ERROR_COMMAND;
        }
    }
    else if (FskTx_TokenEquals(line, "MODE") != 0U)
    {
        result = FskTx_CommandMode(FskTx_AfterToken(line));
    }
    else if (FskTx_TokenEquals(line, "SEND") != 0U)
    {
        result = FskTx_Start();
    }
    else if (FskTx_TokenEquals(line, "STOP") != 0U)
    {
        result = FskTx_Stop();
    }
    else if (FskTx_TokenEquals(line, "STATUS") != 0U)
    {
        FskTx_GetStatus(&status);
        used = 0U;
        if ((response != NULL) && (response_size != 0U))
        {
            response[0] = '\0';
        }
        used = FskTx_AppendText(response, response_size, used, "OK run=");
        used = FskTx_AppendUnsigned(response, response_size, used, status.running);
        used = FskTx_AppendText(response, response_size, used, " mode=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    (uint32_t)status.active_mode);
        used = FskTx_AppendText(response, response_size, used, " amp=");
        used = FskTx_AppendUnsigned(response, response_size, used, status.amplitude);
        used = FskTx_AppendText(response, response_size, used, " len=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.payload_length);
        used = FskTx_AppendText(response, response_size, used, " fs=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.sample_rate_hz);
        used = FskTx_AppendText(response, response_size, used, " sync=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    FSK_TX_SYNC_WORD_IS_FROZEN);
        used = FskTx_AppendText(response, response_size, used, " err=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    (uint32_t)status.last_error);
        used = FskTx_AppendText(response, response_size, used, " dmaerr=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.dma_error_count);
        used = FskTx_AppendText(response, response_size, used, " hde=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.dma_hal_error);
        used = FskTx_AppendText(response, response_size, used, " hae=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.dac_hal_error);
        used = FskTx_AppendText(response, response_size, used, " remain=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.dma_remaining);
        used = FskTx_AppendText(response, response_size, used, " ccr=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.dma_ccr);
        (void)FskTx_AppendText(response, response_size, used, "\r\n");
        return FSK_TX_OK;
    }

    if (result == FSK_TX_OK)
    {
        FskTx_ResponseSet(response, response_size, "OK\r\n");
    }
    else if (result == FSK_TX_ERROR_SYNC_WORD_UNAVAILABLE)
    {
        FskTx_ResponseSet(response, response_size,
                          "ERR SYNC_WORD_NOT_FROZEN\r\n");
    }
    else
    {
        FskTx_ResponseSet(response, response_size, "ERR COMMAND\r\n");
    }
    return result;
}

void HAL_DAC_ConvHalfCpltCallbackCh1(DAC_HandleTypeDef *hdac)
{
    if ((s_tx.initialized != 0U) && (hdac == s_tx.hdac))
    {
        FskTx_RenderHalf(&s_tx.dma_buffer[0]);
    }
}

void HAL_DAC_ConvCpltCallbackCh1(DAC_HandleTypeDef *hdac)
{
    if ((s_tx.initialized != 0U) && (hdac == s_tx.hdac))
    {
        FskTx_RenderHalf(&s_tx.dma_buffer[FSK_TX_DMA_HALF_SAMPLES]);
    }
}

void HAL_DAC_ErrorCallbackCh1(DAC_HandleTypeDef *hdac)
{
    if ((s_tx.initialized != 0U) && (hdac == s_tx.hdac))
    {
        ++s_tx.dma_error_count;
        s_tx.last_error = FSK_TX_ERROR_HAL;
        s_tx.running = 0U;
    }
}
