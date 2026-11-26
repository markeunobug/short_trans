#include "fsk_tx.h"

#include <string.h>

#define FSK_TX_HEADER_BYTES             4U
#define FSK_TX_CRC16_BYTES              2U
#define FSK_TX_FRAME_BODY_MAX_BYTES     (FSK_TX_HEADER_BYTES + \
                                         FSK_TX_BASE_TIME_BYTES + \
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
    volatile FskTx_Modulation modulation;
    volatile uint16_t amplitude;
    volatile uint8_t payload_length;
    volatile uint8_t version;
    volatile uint8_t frame_type;
    volatile uint8_t sequence;
    volatile uint8_t time_valid;
    volatile uint8_t time_base_pending;
    volatile uint32_t configured_time_s;
    volatile uint32_t configured_tick_ms;
    volatile uint32_t base_time_s;
    volatile uint32_t base_tick_ms;
    volatile uint32_t elapsed_10ms;
    volatile uint32_t frame_timestamp;
    volatile uint16_t sweep_sequence;
    volatile uint16_t sweep_frequency_hz;
    volatile uint32_t sweep_phase_increment;
    uint32_t sweep_phase_accumulator;
    volatile uint32_t rendered_symbols;
    volatile uint32_t dma_error_count;
    volatile uint32_t render_max_cycles;
    volatile uint32_t render_uart_budget_cycles;
    volatile uint32_t render_over_uart_budget_count;
    volatile uint32_t render_call_count;
    volatile uint8_t render_cycle_counter_available;
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

static uint32_t FskTx_RenderClockStart(void)
{
#if defined(DWT) && defined(DWT_CTRL_CYCCNTENA_Msk)
    return DWT->CYCCNT;
#else
    return 0U;
#endif
}

static void FskTx_RenderClockStop(uint32_t started)
{
    ++s_tx.render_call_count;
#if defined(DWT) && defined(DWT_CTRL_CYCCNTENA_Msk)
    if (s_tx.render_cycle_counter_available != 0U)
    {
        uint32_t elapsed = DWT->CYCCNT - started;
        if (elapsed > s_tx.render_max_cycles) s_tx.render_max_cycles = elapsed;
        if ((s_tx.render_uart_budget_cycles != 0U) &&
            (elapsed >= s_tx.render_uart_budget_cycles))
            ++s_tx.render_over_uart_budget_count;
    }
#else
    (void)started;
#endif
}

#include "fsk_tone_tables.h"

/* 48 ksample/s * 3 cycles / 80 samples = exactly 1800 Hz. */
static const int16_t s_sine_1800_80[FSK_TX_OOK_LUT_SAMPLES] = {
     0,  7649, 14876, 21280, 26509, 30273, 32364, 32666,
 31163, 27938, 23170, 17121, 10126,  2571, -5126,-12539,
-19260,-24916,-29196,-31862,-32767,-31862,-29196,-24916,
-19260,-12539, -5126,  2571, 10126, 17121, 23170, 27938,
 31163, 32666, 32364, 30273, 26509, 21280, 14876,  7649,
     0, -7649,-14876,-21280,-26509,-30273,-32364,-32666,
-31163,-27938,-23170,-17121,-10126, -2571,  5126, 12539,
 19260, 24916, 29196, 31862, 32767, 31862, 29196, 24916,
 19260, 12539,  5126, -2571,-10126,-17121,-23170,-27938,
-31163,-32666,-32364,-30273,-26509,-21280,-14876, -7649
};

static const int16_t s_quarter_sine_256[65] = {
        0,   804,  1608,  2410,  3212,  4011,  4808,  5602,
     6393,  7179,  7962,  8739,  9512, 10278, 11039, 11793,
    12539, 13279, 14010, 14732, 15446, 16151, 16846, 17530,
    18204, 18868, 19519, 20159, 20787, 21403, 22005, 22594,
    23170, 23731, 24279, 24811, 25329, 25832, 26319, 26790,
    27245, 27683, 28105, 28510, 28898, 29268, 29621, 29956,
    30273, 30571, 30852, 31113, 31356, 31580, 31785, 31971,
    32137, 32285, 32412, 32521, 32609, 32678, 32728, 32757,
    32767
};

static int16_t FskTx_SineFromPhase(uint32_t phase)
{
    uint8_t phase8 = (uint8_t)(phase >> 24U);
    uint8_t offset = (uint8_t)(phase8 & 0x3FU);
    int16_t magnitude;

    if ((phase8 & 0x40U) != 0U)
    {
        offset = (uint8_t)(64U - offset);
    }
    magnitude = s_quarter_sine_256[offset];
    return ((phase8 & 0x80U) != 0U) ? (int16_t)-magnitude : magnitude;
}

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

static void FskTx_WriteBe24(uint8_t *destination, uint32_t value)
{
    destination[0] = (uint8_t)(value >> 16U);
    destination[1] = (uint8_t)(value >> 8U);
    destination[2] = (uint8_t)value;
}

static void FskTx_WriteBe32(uint8_t *destination, uint32_t value)
{
    destination[0] = (uint8_t)(value >> 24U);
    destination[1] = (uint8_t)(value >> 16U);
    destination[2] = (uint8_t)(value >> 8U);
    destination[3] = (uint8_t)value;
}

static uint32_t FskTx_CurrentTimeSeconds(uint32_t tick_ms)
{
    return s_tx.configured_time_s +
           ((tick_ms - s_tx.configured_tick_ms) / 1000U);
}

static void FskTx_LatchPacketTime(void)
{
    uint32_t now_ms = HAL_GetTick();

    if (s_tx.frame_type == FSK_TX_FRAME_TYPE_TIME_BASE)
    {
        s_tx.base_time_s = FskTx_CurrentTimeSeconds(now_ms);
        s_tx.base_tick_ms = now_ms;
        s_tx.elapsed_10ms = 0U;
        s_tx.frame_timestamp = s_tx.base_time_s;
    }
    else
    {
        s_tx.elapsed_10ms = (s_tx.time_valid != 0U)
                                ? ((now_ms - s_tx.base_tick_ms) /
                                   FSK_TX_ELAPSED_UNIT_MS)
                                : 0U;
        s_tx.frame_timestamp = s_tx.elapsed_10ms & 0x00FFFFFFUL;
    }
}

static void FskTx_BuildFrameBody(void)
{
    uint16_t crc16;
    uint8_t payload_length = (s_tx.frame_type == FSK_TX_FRAME_TYPE_TIME_BASE)
                                 ? 0U
                                 : s_tx.payload_length;
    uint8_t time_bytes = (s_tx.frame_type == FSK_TX_FRAME_TYPE_TIME_BASE)
                             ? FSK_TX_BASE_TIME_BYTES
                             : FSK_TX_DATA_TIME_BYTES;
    uint16_t payload_offset = (uint16_t)(FSK_TX_HEADER_BYTES + time_bytes);

    s_tx.frame_body[0] = (uint8_t)((s_tx.version << 4U) |
                                   (s_tx.frame_type & 0x0FU));
    s_tx.frame_body[1] = s_tx.sequence;
    s_tx.frame_body[2] = payload_length;
    s_tx.frame_body[3] = FskTx_Crc8Atm(s_tx.frame_body, 3U);

    if (s_tx.frame_type == FSK_TX_FRAME_TYPE_TIME_BASE)
    {
        FskTx_WriteBe32(&s_tx.frame_body[FSK_TX_HEADER_BYTES],
                        s_tx.frame_timestamp);
    }
    else
    {
        FskTx_WriteBe24(&s_tx.frame_body[FSK_TX_HEADER_BYTES],
                        s_tx.frame_timestamp);
    }

    if (payload_length != 0U)
    {
        memcpy(&s_tx.frame_body[payload_offset],
               s_tx.payload,
               payload_length);
    }

    crc16 = FskTx_Crc16CcittFalse(s_tx.frame_body,
                                  payload_offset + payload_length);
    s_tx.frame_body[payload_offset + payload_length] =
        (uint8_t)(crc16 >> 8U);
    s_tx.frame_body[payload_offset + payload_length + 1U] =
        (uint8_t)crc16;
    s_tx.frame_body_length = (uint16_t)(payload_offset +
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
    s_tx.sweep_phase_accumulator = 0U;

    if (mode == FSK_TX_MODE_PACKET)
    {
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
                FskTx_LatchPacketTime();
                FskTx_BuildFrameBody();
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
        case FSK_TX_MODE_TONE_1700:
            return 0;

        case FSK_TX_MODE_TONE_1900:
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
    int8_t symbol;
    uint32_t render_started = FskTx_RenderClockStart();

    if (s_tx.active_mode == FSK_TX_MODE_SWEEP_TONE)
    {
        for (index = 0U; index < FSK_TX_DMA_HALF_SAMPLES; ++index)
        {
            destination[index] = FskTx_ScaleSample(
                FskTx_SineFromPhase(s_tx.sweep_phase_accumulator));
            s_tx.sweep_phase_accumulator += s_tx.sweep_phase_increment;
        }
        ++s_tx.rendered_symbols;
        FskTx_RenderClockStop(render_started);
        return;
    }

    symbol = (s_tx.active_mode == FSK_TX_MODE_CARRIER_1800) ? 1 :
             FskTx_NextSymbol();

    if ((symbol < 0) ||
        ((s_tx.modulation == FSK_TX_MODULATION_OOK) &&
         ((s_tx.active_mode == FSK_TX_MODE_PACKET) ||
          (s_tx.active_mode == FSK_TX_MODE_ALTERNATING_01) ||
          (s_tx.active_mode == FSK_TX_MODE_PRBS)) &&
         (symbol == 0)))
    {
        for (index = 0U; index < FSK_TX_DMA_HALF_SAMPLES; ++index)
        {
            destination[index] = FSK_TX_DAC_MIDPOINT;
        }
    }
    else
    {
        if ((s_tx.active_mode == FSK_TX_MODE_CARRIER_1800) ||
            ((s_tx.modulation == FSK_TX_MODULATION_OOK) &&
             ((s_tx.active_mode == FSK_TX_MODE_PACKET) ||
              (s_tx.active_mode == FSK_TX_MODE_ALTERNATING_01) ||
              (s_tx.active_mode == FSK_TX_MODE_PRBS))))
        {
            table = s_sine_1800_80;
            table_length = FSK_TX_OOK_LUT_SAMPLES;
        }
        else
        {
            table = (symbol == 0) ? s_sine_bit0 : s_sine_bit1;
            table_length = FSK_TX_SYMBOL_SAMPLES;
        }

        for (index = 0U; index < FSK_TX_DMA_HALF_SAMPLES; ++index)
        {
            destination[index] = FskTx_ScaleSample(table[index % table_length]);
        }
    }

    ++s_tx.rendered_symbols;
    FskTx_RenderClockStop(render_started);
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
    s_tx.frame_type = FSK_TX_FRAME_TYPE_DATA;
    s_tx.selected_mode = FSK_TX_MODE_SILENCE;
    s_tx.active_mode = FSK_TX_MODE_SILENCE;
    s_tx.modulation = FSK_TX_MODULATION_FSK;
    s_tx.last_error = FSK_TX_OK;
    s_tx.timer_clock_hz = FskTx_GetTim4ClockHz();
    s_tx.render_uart_budget_cycles = (uint32_t)(((uint64_t)HAL_RCC_GetHCLKFreq() * 10U + 115199U) / 115200U);
#if defined(DWT) && defined(CoreDebug_DEMCR_TRCENA_Msk) && defined(DWT_CTRL_CYCCNTENA_Msk)
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0U;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
    {
        uint32_t initial_cycles = DWT->CYCCNT;
        __NOP(); __NOP(); __NOP(); __NOP();
        __NOP(); __NOP(); __NOP(); __NOP();
        /* A locked/missing CYCCNT must not report zero as a fast render. */
        s_tx.render_cycle_counter_available =
            ((DWT->CTRL & DWT_CTRL_CYCCNTENA_Msk) != 0U) &&
            (DWT->CYCCNT != initial_cycles);
    }
#endif

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

static uint8_t FskTx_IsLeapYear(uint16_t year)
{
    return (uint8_t)(((year % 4U) == 0U) &&
                     (((year % 100U) != 0U) || ((year % 400U) == 0U)));
}

FskTx_Result FskTx_SetTime(uint16_t year,
                          uint8_t month,
                          uint8_t day,
                          uint8_t hour,
                          uint8_t minute,
                          uint8_t second)
{
    static const uint8_t days_per_month[12] = {
        31U, 28U, 31U, 30U, 31U, 30U, 31U, 31U, 30U, 31U, 30U, 31U
    };
    uint32_t days = 0U;
    uint16_t current_year;
    uint8_t current_month;
    uint8_t maximum_day;
    uint32_t primask;

    if ((year < 1970U) || (year > 2099U) ||
        (month < 1U) || (month > 12U) ||
        (hour > 23U) || (minute > 59U) || (second > 59U))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }
    maximum_day = days_per_month[month - 1U];
    if ((month == 2U) && (FskTx_IsLeapYear(year) != 0U))
    {
        ++maximum_day;
    }
    if ((day < 1U) || (day > maximum_day))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    for (current_year = 1970U; current_year < year; ++current_year)
    {
        days += (FskTx_IsLeapYear(current_year) != 0U) ? 366U : 365U;
    }
    for (current_month = 1U; current_month < month; ++current_month)
    {
        days += days_per_month[current_month - 1U];
        if ((current_month == 2U) && (FskTx_IsLeapYear(year) != 0U))
        {
            ++days;
        }
    }
    days += (uint32_t)(day - 1U);

    primask = FskTx_EnterCritical();
    s_tx.configured_time_s = (days * 86400UL) +
                             ((uint32_t)hour * 3600UL) +
                             ((uint32_t)minute * 60UL) + second;
    s_tx.configured_tick_ms = HAL_GetTick();
    s_tx.time_valid = 1U;
    s_tx.time_base_pending = 1U;
    s_tx.version = FSK_TX_PROTOCOL_VERSION_TIME;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
}

FskTx_Result FskTx_RequestTimeBase(void)
{
    if (s_tx.time_valid == 0U)
    {
        return FSK_TX_ERROR_COMMAND;
    }
    s_tx.time_base_pending = 1U;
    s_tx.version = FSK_TX_PROTOCOL_VERSION_TIME;
    return FSK_TX_OK;
}

FskTx_Result FskTx_SelectMode(FskTx_Mode mode)
{
    if (mode > FSK_TX_MODE_CARRIER_1800)
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    s_tx.selected_mode = mode;
    return FSK_TX_OK;
}

FskTx_Result FskTx_SelectModulation(FskTx_Modulation modulation)
{
    uint32_t primask;

    if ((modulation != FSK_TX_MODULATION_FSK) &&
        (modulation != FSK_TX_MODULATION_OOK))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }
    if (s_tx.initialized == 0U)
    {
        return FSK_TX_ERROR_NOT_INITIALIZED;
    }

    primask = FskTx_EnterCritical();
    if (s_tx.running != 0U)
    {
        FskTx_ExitCritical(primask);
        return FSK_TX_ERROR_BUSY;
    }
    s_tx.modulation = modulation;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
}

FskTx_Result FskTx_Start(void)
{
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

    if (s_tx.selected_mode == FSK_TX_MODE_PACKET)
    {
        s_tx.version = FSK_TX_PROTOCOL_VERSION_TIME;
        s_tx.frame_type = (s_tx.time_base_pending != 0U)
                              ? FSK_TX_FRAME_TYPE_TIME_BASE
                              : FSK_TX_FRAME_TYPE_DATA;
        s_tx.time_base_pending = 0U;
    }

    primask = FskTx_EnterCritical();
    // Keep the DAC/DMA stream enabled to avoid output transients on each send.
    FskTx_ResetGenerator(s_tx.selected_mode);
    s_tx.running = (s_tx.selected_mode != FSK_TX_MODE_SILENCE) ? 1U : 0U;
    s_tx.last_error = FSK_TX_OK;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
}

FskTx_Result FskTx_Stop(void)
{
    uint32_t primask;

    if (s_tx.initialized == 0U)
    {
        return FSK_TX_ERROR_NOT_INITIALIZED;
    }

    primask = FskTx_EnterCritical();
    s_tx.running = 0U;
    FskTx_ResetGenerator(FSK_TX_MODE_SILENCE);
    s_tx.last_error = FSK_TX_OK;
    FskTx_ExitCritical(primask);
    return FSK_TX_OK;
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
    status->modulation = s_tx.modulation;
    status->amplitude = s_tx.amplitude;
    status->payload_length = s_tx.payload_length;
    status->version = s_tx.version;
    status->frame_type = s_tx.frame_type;
    status->sequence = s_tx.sequence;
    status->time_valid = s_tx.time_valid;
    status->time_base_pending = s_tx.time_base_pending;
    status->configured_time_s = s_tx.configured_time_s;
    status->base_time_s = s_tx.base_time_s;
    status->elapsed_10ms = s_tx.elapsed_10ms;
    status->frame_timestamp = s_tx.frame_timestamp;
    status->sweep_sequence = s_tx.sweep_sequence;
    status->sweep_frequency_hz = s_tx.sweep_frequency_hz;
    status->timer_clock_hz = s_tx.timer_clock_hz;
    status->sample_rate_hz = s_tx.sample_rate_hz;
    status->rendered_symbols = s_tx.rendered_symbols;
    status->dma_error_count = s_tx.dma_error_count;
    status->last_error = s_tx.last_error;
    status->dma_hal_error = HAL_DMA_GetError(s_tx.hdac->DMA_Handle1);
    status->dac_hal_error = HAL_DAC_GetError(s_tx.hdac);
    status->dma_remaining = __HAL_DMA_GET_COUNTER(s_tx.hdac->DMA_Handle1);
    status->dma_ccr = s_tx.hdac->DMA_Handle1->Instance->CCR;
    status->render_max_cycles = s_tx.render_max_cycles;
    status->render_uart_budget_cycles = s_tx.render_uart_budget_cycles;
    status->render_over_uart_budget_count = s_tx.render_over_uart_budget_count;
    status->render_call_count = s_tx.render_call_count;
    status->render_cycle_counter_available = s_tx.render_cycle_counter_available;
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

static uint8_t FskTx_ParseUnsignedFields(const char *text,
                                         uint32_t *fields,
                                         uint8_t field_count)
{
    uint8_t index;

    for (index = 0U; index < field_count; ++index)
    {
        uint32_t value = 0U;
        uint8_t digit_seen = 0U;

        text = FskTx_SkipSpaces(text);
        while ((*text >= '0') && (*text <= '9'))
        {
            uint32_t digit = (uint32_t)(*text - '0');
            if (value > ((UINT32_MAX - digit) / 10U))
            {
                return 0U;
            }
            value = (value * 10U) + digit;
            digit_seen = 1U;
            ++text;
        }
        if (digit_seen == 0U)
        {
            return 0U;
        }
        fields[index] = value;
    }
    return (*FskTx_SkipSpaces(text) == '\0') ? 1U : 0U;
}

static FskTx_Result FskTx_StartSweepTone(uint16_t sequence,
                                         uint16_t frequency_hz,
                                         uint16_t amplitude)
{
    FskTx_Result result;

    if ((frequency_hz < FSK_TX_SWEEP_MIN_HZ) ||
        (frequency_hz > FSK_TX_SWEEP_MAX_HZ) ||
        (((frequency_hz - FSK_TX_SWEEP_MIN_HZ) %
          FSK_TX_SWEEP_STEP_HZ) != 0U))
    {
        return FSK_TX_ERROR_ARGUMENT;
    }

    result = FskTx_SetAmplitude(amplitude);
    if (result != FSK_TX_OK)
    {
        return result;
    }
    s_tx.sweep_sequence = sequence;
    s_tx.sweep_frequency_hz = frequency_hz;
    s_tx.sweep_phase_increment = (uint32_t)(
        ((((uint64_t)frequency_hz << 32U) +
          (FSK_TX_SAMPLE_RATE_HZ / 2U)) /
         FSK_TX_SAMPLE_RATE_HZ));
    s_tx.selected_mode = FSK_TX_MODE_SWEEP_TONE;
    return FskTx_Start();
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
    if (FskTx_ArgumentEquals(argument, "TONE1700") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_TONE_1700);
    }
    if (FskTx_ArgumentEquals(argument, "TONE1900") != 0U)
    {
        return FskTx_SelectMode(FSK_TX_MODE_TONE_1900);
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
    if ((FskTx_ArgumentEquals(argument, "CARRIER") != 0U) ||
        (FskTx_ArgumentEquals(argument, "CARRIER1800") != 0U))
    {
        return FskTx_SelectMode(FSK_TX_MODE_CARRIER_1800);
    }
    return FSK_TX_ERROR_COMMAND;
}

static FskTx_Result FskTx_CommandModulation(const char *argument)
{
    if (FskTx_ArgumentEquals(argument, "FSK") != 0U)
    {
        return FskTx_SelectModulation(FSK_TX_MODULATION_FSK);
    }
    if (FskTx_ArgumentEquals(argument, "OOK") != 0U)
    {
        return FskTx_SelectModulation(FSK_TX_MODULATION_OOK);
    }
    return FSK_TX_ERROR_COMMAND;
}

static uint8_t FskTx_ParseSetTime(const char *text)
{
    uint32_t fields[6] = {0U};
    uint8_t field = 0U;
    uint8_t digits = 0U;

    text = FskTx_SkipSpaces(text);
    while (*text != '\0')
    {
        if ((*text >= '0') && (*text <= '9'))
        {
            if (digits >= 4U)
            {
                return 0U;
            }
            fields[field] = (fields[field] * 10U) +
                            (uint32_t)(*text - '0');
            ++digits;
            ++text;
            continue;
        }
        if (((*text == '-') && (field < 2U)) ||
            ((*text == ':') && (field >= 2U) && (field < 5U)) ||
            (*text == ' ' && field == 2U))
        {
            if (digits == 0U)
            {
                return 0U;
            }
            ++field;
            digits = 0U;
            ++text;
            continue;
        }
        return 0U;
    }
    if ((field != 5U) || (digits == 0U))
    {
        return 0U;
    }
    return (FskTx_SetTime((uint16_t)fields[0],
                          (uint8_t)fields[1],
                          (uint8_t)fields[2],
                          (uint8_t)fields[3],
                          (uint8_t)fields[4],
                          (uint8_t)fields[5]) == FSK_TX_OK) ? 1U : 0U;
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
                          "SET_TIME YYYY-MM-DD HH:MM:SS | TIME_BASE | "
                          "MODE SILENCE|TONE1700|TONE1900|ALT|PRBS|PACKET|CARRIER|CARRIER1800 | "
                          "MOD FSK|OOK | SWEEP INFO|TONE|OFF | SEND | STOP | STATUS | UART DIAG\r\n");
        return FSK_TX_OK;
    }
    if (FskTx_TokenEquals(line, "SWEEP") != 0U)
    {
        const char *sweep_command = FskTx_AfterToken(line);

        if (FskTx_ArgumentEquals(sweep_command, "INFO") != 0U)
        {
            FskTx_ResponseSet(response, response_size,
                              "OK SWEEP INFO min=1500 max=2100 step=20 "
                              "fs=48000 ampmax=2047\r\n");
            return FSK_TX_OK;
        }
        if (FskTx_TokenEquals(sweep_command, "TONE") != 0U)
        {
            uint32_t fields[3];

            if ((FskTx_ParseUnsignedFields(FskTx_AfterToken(sweep_command),
                                           fields, 3U) == 0U) ||
                (fields[0] > 65535U) ||
                (fields[1] > 65535U) ||
                (fields[2] > FSK_TX_MAX_AMPLITUDE))
            {
                FskTx_ResponseSet(response, response_size,
                                  "ERR SWEEP ARG\r\n");
                return FSK_TX_ERROR_ARGUMENT;
            }
            result = FskTx_StartSweepTone((uint16_t)fields[0],
                                           (uint16_t)fields[1],
                                           (uint16_t)fields[2]);
            if (result != FSK_TX_OK)
            {
                FskTx_ResponseSet(response, response_size,
                                  "ERR SWEEP RANGE\r\n");
                return result;
            }
            used = 0U;
            if ((response != NULL) && (response_size != 0U))
            {
                response[0] = '\0';
            }
            used = FskTx_AppendText(response, response_size, used,
                                    "OK SWEEP TONE seq=");
            used = FskTx_AppendUnsigned(response, response_size, used,
                                        fields[0]);
            used = FskTx_AppendText(response, response_size, used,
                                    " freq=");
            used = FskTx_AppendUnsigned(response, response_size, used,
                                        fields[1]);
            used = FskTx_AppendText(response, response_size, used,
                                    " amp=");
            used = FskTx_AppendUnsigned(response, response_size, used,
                                        fields[2]);
            (void)FskTx_AppendText(response, response_size, used, "\r\n");
            return FSK_TX_OK;
        }
        if (FskTx_ArgumentEquals(sweep_command, "OFF") != 0U)
        {
            result = FskTx_Stop();
            FskTx_ResponseSet(response, response_size,
                              (result == FSK_TX_OK)
                                  ? "OK SWEEP OFF\r\n"
                                  : "ERR SWEEP OFF\r\n");
            return result;
        }
        FskTx_ResponseSet(response, response_size, "ERR SWEEP COMMAND\r\n");
        return FSK_TX_ERROR_COMMAND;
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
    else if (FskTx_TokenEquals(line, "SET_TIME") != 0U)
    {
        result = (FskTx_ParseSetTime(FskTx_AfterToken(line)) != 0U)
                     ? FSK_TX_OK
                     : FSK_TX_ERROR_COMMAND;
    }
    else if (FskTx_TokenEquals(line, "TIME_BASE") != 0U)
    {
        result = FskTx_RequestTimeBase();
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
    else if (FskTx_TokenEquals(line, "MOD") != 0U)
    {
        result = FskTx_CommandModulation(FskTx_AfterToken(line));
        if (result == FSK_TX_OK)
        {
            FskTx_ResponseSet(response, response_size,
                              (s_tx.modulation == FSK_TX_MODULATION_OOK)
                                  ? "OK MOD OOK\r\n" : "OK MOD FSK\r\n");
            return FSK_TX_OK;
        }
        if (result == FSK_TX_ERROR_BUSY)
        {
            FskTx_ResponseSet(response, response_size, "ERR busy\r\n");
            return result;
        }
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
        used = FskTx_AppendText(response, response_size, used, " mod=");
        used = FskTx_AppendText(response, response_size, used,
                                 (status.modulation == FSK_TX_MODULATION_OOK)
                                     ? "OOK" : "FSK");
        used = FskTx_AppendText(response, response_size, used, " amp=");
        used = FskTx_AppendUnsigned(response, response_size, used, status.amplitude);
        used = FskTx_AppendText(response, response_size, used, " len=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.payload_length);
        used = FskTx_AppendText(response, response_size, used, " time_valid=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.time_valid);
        used = FskTx_AppendText(response, response_size, used, " time_base_pending=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.time_base_pending);
        used = FskTx_AppendText(response, response_size, used, " base_s=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.base_time_s);
        used = FskTx_AppendText(response, response_size, used, " elapsed10=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.elapsed_10ms);
        used = FskTx_AppendText(response, response_size, used, " fs=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.sample_rate_hz);
        used = FskTx_AppendText(response, response_size, used, " sweep_seq=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.sweep_sequence);
        used = FskTx_AppendText(response, response_size, used, " sweep_freq=");
        used = FskTx_AppendUnsigned(response, response_size, used,
                                    status.sweep_frequency_hz);
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
