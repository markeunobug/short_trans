#include "fsk_tx.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

extern const uint32_t *mock_dac_dma_data;
void HAL_DAC_ConvHalfCpltCallbackCh1(DAC_HandleTypeDef *hdac);
void HAL_DAC_ConvCpltCallbackCh1(DAC_HandleTypeDef *hdac);

static void write_half(FILE *out, const uint16_t *samples, uint32_t *count)
{
    uint16_t index;
    for (index = 0U; index < FSK_TX_DMA_HALF_SAMPLES; ++index)
    {
        assert(fprintf(out, "%03X\n", samples[index]) > 0);
        ++*count;
    }
}

static uint32_t capture_packet(FILE *out, DAC_HandleTypeDef *hdac)
{
    FskTx_Status status;
    uint32_t count = 0U;

    assert(FskTx_Start() == FSK_TX_OK);
    write_half(out, (const uint16_t *)mock_dac_dma_data, &count);
    write_half(out, (const uint16_t *)mock_dac_dma_data + FSK_TX_DMA_HALF_SAMPLES,
               &count);
    do
    {
        HAL_DAC_ConvHalfCpltCallbackCh1(hdac);
        write_half(out, (const uint16_t *)mock_dac_dma_data, &count);
        FskTx_GetStatus(&status);
        if (status.running == 0U)
        {
            break;
        }
        HAL_DAC_ConvCpltCallbackCh1(hdac);
        write_half(out, (const uint16_t *)mock_dac_dma_data + FSK_TX_DMA_HALF_SAMPLES,
                   &count);
        FskTx_GetStatus(&status);
    } while (status.running != 0U);
    return count;
}

int main(int argc, char **argv)
{
    DMA_Channel_TypeDef channel = {0};
    DMA_HandleTypeDef dma = { .Instance = &channel };
    DAC_HandleTypeDef dac = { .Instance = DAC1, .DMA_Handle1 = &dma };
    TIM_HandleTypeDef tim = { .Instance = TIM4 };
    const uint8_t payload[] = { 0x01U, 0x23U, 0x45U, 0x67U };
    FILE *out;
    uint32_t time_base_samples;
    uint32_t data_samples;

    if (argc != 2)
    {
        return 2;
    }
    out = fopen(argv[1], "w");
    if (out == NULL)
    {
        return 3;
    }
    assert(FskTx_Init(&dac, &tim) == FSK_TX_OK);
    assert(FskTx_SelectModulation(FSK_TX_MODULATION_OOK) == FSK_TX_OK);
    assert(FskTx_SetTime(2026U, 9U, 23U, 0U, 0U, 0U) == FSK_TX_OK);
    assert(FskTx_SetPayload(payload, sizeof(payload)) == FSK_TX_OK);
    assert(FskTx_SelectMode(FSK_TX_MODE_PACKET) == FSK_TX_OK);
    time_base_samples = capture_packet(out, &dac);
    data_samples = capture_packet(out, &dac);
    assert(fclose(out) == 0);
    printf("time_base_samples=%lu data_samples=%lu total_samples=%lu\n",
           (unsigned long)time_base_samples, (unsigned long)data_samples,
           (unsigned long)(time_base_samples + data_samples));
    return 0;
}
