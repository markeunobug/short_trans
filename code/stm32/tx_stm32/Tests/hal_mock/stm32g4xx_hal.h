#ifndef STM32G4XX_HAL_H
#define STM32G4XX_HAL_H

#include <stdint.h>

typedef enum { HAL_OK = 0, HAL_ERROR = 1 } HAL_StatusTypeDef;
typedef struct { volatile uint32_t CCR; } DMA_Channel_TypeDef;
typedef struct { uint32_t PeriphDataAlignment; uint32_t MemDataAlignment; uint32_t Mode; } DMA_InitTypeDef;
typedef struct DMA_HandleTypeDef { DMA_Channel_TypeDef *Instance; DMA_InitTypeDef Init; void *Parent; uint32_t ErrorCode; uint32_t Counter; } DMA_HandleTypeDef;
typedef struct { uint32_t unused; } DAC_TypeDef;
typedef struct { uint32_t unused; } TIM_TypeDef;
typedef struct { DAC_TypeDef *Instance; DMA_HandleTypeDef *DMA_Handle1; uint32_t ErrorCode; } DAC_HandleTypeDef;
typedef struct { uint32_t Prescaler; uint32_t Period; uint32_t CounterMode; uint32_t ClockDivision; uint32_t AutoReloadPreload; } TIM_Base_InitTypeDef;
typedef struct { TIM_TypeDef *Instance; TIM_Base_InitTypeDef Init; } TIM_HandleTypeDef;
typedef struct { uint32_t MasterOutputTrigger; uint32_t MasterSlaveMode; } TIM_MasterConfigTypeDef;

extern DAC_TypeDef mock_dac1;
extern TIM_TypeDef mock_tim4;
extern uint32_t mock_dac_start_dma_count;
extern uint32_t mock_dac_stop_dma_count;
extern uint32_t mock_tim_start_count;
extern uint32_t mock_tim_stop_count;
#define DAC1 (&mock_dac1)
#define TIM4 (&mock_tim4)
#define DAC_CHANNEL_1 1U
#define DAC_ALIGN_12B_R 0U
#define TIM_COUNTERMODE_UP 0U
#define TIM_CLOCKDIVISION_DIV1 0U
#define TIM_AUTORELOAD_PRELOAD_DISABLE 0U
#define TIM_TRGO_UPDATE 0U
#define TIM_MASTERSLAVEMODE_DISABLE 0U
#define DMA_PDATAALIGN_WORD 0U
#define DMA_MDATAALIGN_HALFWORD 0U
#define DMA_CIRCULAR 0U
#define __HAL_DMA_GET_COUNTER(hdma) ((hdma)->Counter)

uint32_t __get_PRIMASK(void); void __disable_irq(void); void __enable_irq(void);
uint32_t HAL_RCC_GetPCLK1Freq(void); uint32_t HAL_RCC_GetHCLKFreq(void); uint32_t HAL_GetTick(void);
HAL_StatusTypeDef HAL_TIM_Base_Stop(TIM_HandleTypeDef *htim); HAL_StatusTypeDef HAL_TIM_Base_Start(TIM_HandleTypeDef *htim); HAL_StatusTypeDef HAL_TIM_Base_Init(TIM_HandleTypeDef *htim);
HAL_StatusTypeDef HAL_TIMEx_MasterConfigSynchronization(TIM_HandleTypeDef *htim, TIM_MasterConfigTypeDef *config);
HAL_StatusTypeDef HAL_DMA_Abort(DMA_HandleTypeDef *hdma); HAL_StatusTypeDef HAL_DMA_DeInit(DMA_HandleTypeDef *hdma); HAL_StatusTypeDef HAL_DMA_Init(DMA_HandleTypeDef *hdma);
HAL_StatusTypeDef HAL_DAC_SetValue(DAC_HandleTypeDef *hdac, uint32_t channel, uint32_t align, uint32_t value);
HAL_StatusTypeDef HAL_DAC_Start_DMA(DAC_HandleTypeDef *hdac, uint32_t channel, const uint32_t *data, uint32_t length, uint32_t align);
HAL_StatusTypeDef HAL_DAC_Stop_DMA(DAC_HandleTypeDef *hdac, uint32_t channel);
uint32_t HAL_DMA_GetError(DMA_HandleTypeDef *hdma); uint32_t HAL_DAC_GetError(DAC_HandleTypeDef *hdac);
#endif
