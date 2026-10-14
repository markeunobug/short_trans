#include "stm32g4xx_hal.h"
DAC_TypeDef mock_dac1; TIM_TypeDef mock_tim4;
const uint32_t *mock_dac_dma_data; uint32_t mock_dac_dma_length; uint32_t mock_dac_value;
uint32_t __get_PRIMASK(void) { return 0U; } void __disable_irq(void) {} void __enable_irq(void) {}
uint32_t HAL_RCC_GetPCLK1Freq(void) { return 150000000U; } uint32_t HAL_RCC_GetHCLKFreq(void) { return 150000000U; } uint32_t HAL_GetTick(void) { return 0U; }
HAL_StatusTypeDef HAL_TIM_Base_Stop(TIM_HandleTypeDef *x) { (void)x; return HAL_OK; } HAL_StatusTypeDef HAL_TIM_Base_Start(TIM_HandleTypeDef *x) { (void)x; return HAL_OK; } HAL_StatusTypeDef HAL_TIM_Base_Init(TIM_HandleTypeDef *x) { (void)x; return HAL_OK; }
HAL_StatusTypeDef HAL_TIMEx_MasterConfigSynchronization(TIM_HandleTypeDef *x, TIM_MasterConfigTypeDef *y) { (void)x; (void)y; return HAL_OK; }
HAL_StatusTypeDef HAL_DMA_Abort(DMA_HandleTypeDef *x) { (void)x; return HAL_OK; } HAL_StatusTypeDef HAL_DMA_DeInit(DMA_HandleTypeDef *x) { (void)x; return HAL_OK; } HAL_StatusTypeDef HAL_DMA_Init(DMA_HandleTypeDef *x) { (void)x; return HAL_OK; }
HAL_StatusTypeDef HAL_DAC_SetValue(DAC_HandleTypeDef *x, uint32_t y, uint32_t z, uint32_t value) { (void)x; (void)y; (void)z; mock_dac_value=value; return HAL_OK; }
HAL_StatusTypeDef HAL_DAC_Start_DMA(DAC_HandleTypeDef *x, uint32_t y, const uint32_t *data, uint32_t length, uint32_t z) { (void)x; (void)y; (void)z; mock_dac_dma_data=data; mock_dac_dma_length=length; return HAL_OK; }
HAL_StatusTypeDef HAL_DAC_Stop_DMA(DAC_HandleTypeDef *x, uint32_t y) { (void)x; (void)y; return HAL_OK; }
uint32_t HAL_DMA_GetError(DMA_HandleTypeDef *x) { return x->ErrorCode; } uint32_t HAL_DAC_GetError(DAC_HandleTypeDef *x) { return x->ErrorCode; }
