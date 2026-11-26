/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */
/* Includes ------------------------------------------------------------------*/
#include "main.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "fsk_tx.h"
#include "rs485_half_duplex.h"

#include <stdio.h>
#include <string.h>
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define FSK_UART_RX_RING_SIZE 256U
#define FSK_UART_RX_RING_MASK (FSK_UART_RX_RING_SIZE - 1U)
#define FSK_UART_DIAG_BAD_BYTES 32U
#define FSK_UART_LINE_MAX_LENGTH UINT16_MAX
#if defined(__OPTIMIZE__)
#define FSK_UART_DIAG_OPTIMIZED 1U
#else
#define FSK_UART_DIAG_OPTIMIZED 0U
#endif
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
DAC_HandleTypeDef hdac1;
DMA_HandleTypeDef hdma_dac1_ch1;

TIM_HandleTypeDef htim4;

UART_HandleTypeDef huart1;

/* USER CODE BEGIN PV */
static char fsk_uart_line[160];
static char fsk_uart_response[320];
static uint16_t fsk_uart_line_length;
static rs485_half_duplex_t rs485a;
static uint8_t fsk_uart_irq_byte;
static uint8_t fsk_uart_rx_ring[FSK_UART_RX_RING_SIZE];
static volatile uint16_t fsk_uart_rx_head;
static volatile uint16_t fsk_uart_rx_tail;
static volatile uint32_t fsk_uart_error_count;
static volatile uint32_t fsk_uart_overflow_count;
static volatile uint32_t fsk_uart_ore_count, fsk_uart_fe_count;
static volatile uint32_t fsk_uart_ne_count, fsk_uart_pe_count;
static volatile uint32_t fsk_uart_rearm_fail_count, fsk_uart_tx_error_count;
static volatile uint32_t fsk_uart_line_overflow_count;
static volatile uint32_t fsk_uart_command_error_count;
static uint8_t fsk_uart_line_overflowed;
static uint8_t fsk_uart_last_bad[FSK_UART_DIAG_BAD_BYTES];
static uint16_t fsk_uart_last_bad_length;
static uint8_t fsk_uart_last_bad_count;
static uint16_t fsk_uart_line_total_length;
/* Separate from the unchanged normal-command response buffer. */
static char fsk_uart_diag_response[512];
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
static void MX_GPIO_Init(void);
static void MX_DMA_Init(void);
static void MX_DAC1_Init(void);
static void MX_USART1_UART_Init(void);
static void MX_TIM4_Init(void);
/* USER CODE BEGIN PFP */

/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */
static void FskUart_RecordHardwareErrors(uint32_t error)
{
  if ((error & HAL_UART_ERROR_ORE) != 0U) ++fsk_uart_ore_count;
  if ((error & HAL_UART_ERROR_FE) != 0U) ++fsk_uart_fe_count;
  if ((error & HAL_UART_ERROR_NE) != 0U) ++fsk_uart_ne_count;
  if ((error & HAL_UART_ERROR_PE) != 0U) ++fsk_uart_pe_count;
}

static void FskUart_RememberBadLine(const char *line,
                                    uint16_t captured_length,
                                    uint16_t total_length)
{
  uint16_t count = (captured_length > FSK_UART_DIAG_BAD_BYTES) ?
                   FSK_UART_DIAG_BAD_BYTES : captured_length;
  memset(fsk_uart_last_bad, 0, sizeof(fsk_uart_last_bad));
  memcpy(fsk_uart_last_bad, line, count);
  fsk_uart_last_bad_count = (uint8_t)count;
  fsk_uart_last_bad_length = total_length;
}

static void FskUart_Transmit(const char *text)
{
  if (rs485_half_duplex_transmit(&rs485a, (const uint8_t *)text,
                                (uint16_t)strlen(text), 100U) != HAL_OK)
  {
    ++fsk_uart_tx_error_count;
  }
}

static void FskUart_SendDiagnostics(void)
{
  static const char hex[] = "0123456789ABCDEF";
  FskTx_Status status;
  uint32_t saved_irq, rxerr, rxovf, ore, fe, ne, pe, rearm;
  int written;
  size_t used;
  uint16_t index, count;

  /* Snapshot interrupt-owned counters; formatting never masks interrupts. */
  saved_irq = __get_PRIMASK();
  __disable_irq();
  rxerr = fsk_uart_error_count; rxovf = fsk_uart_overflow_count;
  ore = fsk_uart_ore_count; fe = fsk_uart_fe_count;
  ne = fsk_uart_ne_count; pe = fsk_uart_pe_count;
  rearm = fsk_uart_rearm_fail_count;
  if (saved_irq == 0U) __enable_irq();
  FskTx_GetStatus(&status);
  written = snprintf(fsk_uart_diag_response, sizeof(fsk_uart_diag_response),
      "OK UART DIAG rxerr=%lu rxovf=%lu lineovf=%lu cmderr=%lu "
      "ore=%lu fe=%lu ne=%lu pe=%lu rearmfail=%lu txerr=%lu "
      "badlen=%u badcap=%u badhex=",
      (unsigned long)rxerr, (unsigned long)rxovf,
      (unsigned long)fsk_uart_line_overflow_count,
      (unsigned long)fsk_uart_command_error_count,
      (unsigned long)ore, (unsigned long)fe, (unsigned long)ne,
      (unsigned long)pe, (unsigned long)rearm,
      (unsigned long)fsk_uart_tx_error_count,
      (unsigned)fsk_uart_last_bad_length, (unsigned)fsk_uart_last_bad_count);
  if ((written < 0) || ((size_t)written >= sizeof(fsk_uart_diag_response)))
  {
    (void)strcpy(fsk_uart_diag_response, "ERR UART DIAG BUFFER\r\n");
  }
  else
  {
    used = (size_t)written;
    count = fsk_uart_last_bad_count;
    for (index = 0U; index < count && (used + 2U) < sizeof(fsk_uart_diag_response); ++index)
    {
      fsk_uart_diag_response[used++] = hex[fsk_uart_last_bad[index] >> 4U];
      fsk_uart_diag_response[used++] = hex[fsk_uart_last_bad[index] & 0x0FU];
    }
    written = snprintf(&fsk_uart_diag_response[used], sizeof(fsk_uart_diag_response) - used,
        " rendermax=%lu uartbudget=%lu renderlate=%lu renders=%lu dwt=%u hclk=%lu schema=1 opt=%u\r\n",
        (unsigned long)status.render_max_cycles,
        (unsigned long)status.render_uart_budget_cycles,
        (unsigned long)status.render_over_uart_budget_count,
        (unsigned long)status.render_call_count,
        (unsigned)status.render_cycle_counter_available,
        (unsigned long)HAL_RCC_GetHCLKFreq(), (unsigned)FSK_UART_DIAG_OPTIMIZED);
    if ((written < 0) || ((size_t)written >= sizeof(fsk_uart_diag_response) - used))
      (void)strcpy(fsk_uart_diag_response, "ERR UART DIAG BUFFER\r\n");
  }
  FskUart_Transmit(fsk_uart_diag_response);
}

static void FskUart_ProcessByte(uint8_t byte)
{
  if ((byte == '\r') || (byte == '\n'))
  {
    if (fsk_uart_line_length == 0U)
    {
      if (fsk_uart_line_overflowed != 0U)
      {
        ++fsk_uart_line_overflow_count;
        FskUart_RememberBadLine(fsk_uart_line, fsk_uart_line_length,
                                fsk_uart_line_total_length);
        fsk_uart_line_overflowed = 0U;
        fsk_uart_line_total_length = 0U;
      }
      return;
    }

    HAL_Delay(1U);
    fsk_uart_line[fsk_uart_line_length] = '\0';
    if (fsk_uart_line_overflowed != 0U)
    {
      ++fsk_uart_line_overflow_count;
      FskUart_RememberBadLine(fsk_uart_line, fsk_uart_line_length,
                              fsk_uart_line_total_length);
    }
    if ((fsk_uart_line_overflowed == 0U) &&
        (strcmp(fsk_uart_line, "UART DIAG") == 0))
    {
      FskUart_SendDiagnostics();
    }
    else
    {
      FskTx_Result command_result = FskTx_HandleUartCommand(
          fsk_uart_line, fsk_uart_response, sizeof(fsk_uart_response));
      if (command_result == FSK_TX_ERROR_COMMAND)
      {
        ++fsk_uart_command_error_count;
        FskUart_RememberBadLine(fsk_uart_line, fsk_uart_line_length,
                                fsk_uart_line_total_length);
      }
      FskUart_Transmit(fsk_uart_response);
    }
    fsk_uart_line_overflowed = 0U;
    fsk_uart_line_length = 0U;
    fsk_uart_line_total_length = 0U;
    return;
  }

  if ((byte == 0x08U) || (byte == 0x7FU))
  {
    if (fsk_uart_line_length != 0U)
    {
      --fsk_uart_line_length;
    }
    return;
  }

  if ((byte >= 0x20U) && (byte <= 0x7EU) &&
      (fsk_uart_line_length < (sizeof(fsk_uart_line) - 1U)))
  {
    fsk_uart_line[fsk_uart_line_length++] = (char)byte;
    if (fsk_uart_line_total_length < FSK_UART_LINE_MAX_LENGTH)
    {
      ++fsk_uart_line_total_length;
    }
  }
  else if ((byte >= 0x20U) && (byte <= 0x7EU))
  {
    fsk_uart_line_overflowed = 1U;
    if (fsk_uart_line_total_length < FSK_UART_LINE_MAX_LENGTH)
    {
      ++fsk_uart_line_total_length;
    }
  }
}

static void FskUart_Service(void)
{
  while (fsk_uart_rx_tail != fsk_uart_rx_head)
  {
    uint8_t byte = fsk_uart_rx_ring[fsk_uart_rx_tail];
    fsk_uart_rx_tail = (uint16_t)((fsk_uart_rx_tail + 1U) &
                                  FSK_UART_RX_RING_MASK);
    FskUart_ProcessByte(byte);
  }
}
/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{
  /* USER CODE BEGIN 1 */

  /* USER CODE END 1 */

  /* MCU Configuration--------------------------------------------------------*/

  /* Reset of all peripherals, Initializes the Flash interface and the Systick. */
  HAL_Init();

  /* USER CODE BEGIN Init */

  /* USER CODE END Init */

  /* Configure the system clock */
  SystemClock_Config();

  /* USER CODE BEGIN SysInit */

  /* USER CODE END SysInit */

  /* Initialize all configured peripherals */
  MX_GPIO_Init();
  MX_DMA_Init();
  MX_DAC1_Init();
  MX_USART1_UART_Init();
  MX_TIM4_Init();
  /* USER CODE BEGIN 2 */
  if (rs485_half_duplex_init(&rs485a, &huart1,
                             RS485A_EN_GPIO_Port, RS485A_EN_Pin) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_UART_Receive_IT(&huart1, &fsk_uart_irq_byte, 1U) != HAL_OK)
  {
    Error_Handler();
  }
  if (FskTx_Init(&hdac1, &htim4) != FSK_TX_OK)
  {
    Error_Handler();
  }

#if defined(FSK_TX_BOOT_TEST_TONE1700)
  (void)FskTx_SelectMode(FSK_TX_MODE_TONE_1700);
  (void)FskTx_Start();
#elif defined(FSK_TX_BOOT_TEST_TONE1900)
  (void)FskTx_SelectMode(FSK_TX_MODE_TONE_1900);
  (void)FskTx_Start();
#elif defined(FSK_TX_BOOT_TEST_ALT)
  (void)FskTx_SelectMode(FSK_TX_MODE_ALTERNATING_01);
  (void)FskTx_Start();
#endif

/* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  while (1)
  {
    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
    FskUart_Service();
  }
  /* USER CODE END 3 */
}

/**
  * @brief System Clock Configuration
  * @retval None
  */
void SystemClock_Config(void)
{
  RCC_OscInitTypeDef RCC_OscInitStruct = {0};
  RCC_ClkInitTypeDef RCC_ClkInitStruct = {0};

  /** Configure the main internal regulator output voltage
  */
  HAL_PWREx_ControlVoltageScaling(PWR_REGULATOR_VOLTAGE_SCALE1);

  /** Initializes the RCC Oscillators according to the specified parameters
  * in the RCC_OscInitTypeDef structure.
  */
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSE;
  RCC_OscInitStruct.HSEState = RCC_HSE_BYPASS;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource = RCC_PLLSOURCE_HSE;
  RCC_OscInitStruct.PLL.PLLM = RCC_PLLM_DIV2;
  RCC_OscInitStruct.PLL.PLLN = 24;
  RCC_OscInitStruct.PLL.PLLP = RCC_PLLP_DIV2;
  RCC_OscInitStruct.PLL.PLLQ = RCC_PLLQ_DIV2;
  RCC_OscInitStruct.PLL.PLLR = RCC_PLLR_DIV2;
  if (HAL_RCC_OscConfig(&RCC_OscInitStruct) != HAL_OK)
  {
    Error_Handler();
  }

  /** Initializes the CPU, AHB and APB buses clocks
  */
  RCC_ClkInitStruct.ClockType = RCC_CLOCKTYPE_HCLK|RCC_CLOCKTYPE_SYSCLK
                              |RCC_CLOCKTYPE_PCLK1|RCC_CLOCKTYPE_PCLK2;
  RCC_ClkInitStruct.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  RCC_ClkInitStruct.AHBCLKDivider = RCC_SYSCLK_DIV1;
  RCC_ClkInitStruct.APB1CLKDivider = RCC_HCLK_DIV1;
  RCC_ClkInitStruct.APB2CLKDivider = RCC_HCLK_DIV1;

  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct, FLASH_LATENCY_4) != HAL_OK)
  {
    Error_Handler();
  }
}

/**
  * @brief DAC1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_DAC1_Init(void)
{

  /* USER CODE BEGIN DAC1_Init 0 */

  /* USER CODE END DAC1_Init 0 */

  DAC_ChannelConfTypeDef sConfig = {0};

  /* USER CODE BEGIN DAC1_Init 1 */

  /* USER CODE END DAC1_Init 1 */

  /** DAC Initialization
  */
  hdac1.Instance = DAC1;
  if (HAL_DAC_Init(&hdac1) != HAL_OK)
  {
    Error_Handler();
  }

  /** DAC channel OUT1 config
  */
  sConfig.DAC_HighFrequency = DAC_HIGH_FREQUENCY_INTERFACE_MODE_AUTOMATIC;
  sConfig.DAC_DMADoubleDataMode = DISABLE;
  sConfig.DAC_SignedFormat = DISABLE;
  sConfig.DAC_SampleAndHold = DAC_SAMPLEANDHOLD_DISABLE;
  sConfig.DAC_Trigger = DAC_TRIGGER_T4_TRGO;
  sConfig.DAC_Trigger2 = DAC_TRIGGER_NONE;
  sConfig.DAC_OutputBuffer = DAC_OUTPUTBUFFER_ENABLE;
  sConfig.DAC_ConnectOnChipPeripheral = DAC_CHIPCONNECT_EXTERNAL;
  sConfig.DAC_UserTrimming = DAC_TRIMMING_FACTORY;
  if (HAL_DAC_ConfigChannel(&hdac1, &sConfig, DAC_CHANNEL_1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN DAC1_Init 2 */

  /* USER CODE END DAC1_Init 2 */

}

/**
  * @brief TIM4 Initialization Function
  * @param None
  * @retval None
  */
static void MX_TIM4_Init(void)
{

  /* USER CODE BEGIN TIM4_Init 0 */

  /* USER CODE END TIM4_Init 0 */

  TIM_ClockConfigTypeDef sClockSourceConfig = {0};
  TIM_MasterConfigTypeDef sMasterConfig = {0};

  /* USER CODE BEGIN TIM4_Init 1 */

  /* USER CODE END TIM4_Init 1 */
  htim4.Instance = TIM4;
  htim4.Init.Prescaler = 4;
  htim4.Init.CounterMode = TIM_COUNTERMODE_UP;
  htim4.Init.Period = 624;
  htim4.Init.ClockDivision = TIM_CLOCKDIVISION_DIV1;
  htim4.Init.AutoReloadPreload = TIM_AUTORELOAD_PRELOAD_DISABLE;
  if (HAL_TIM_Base_Init(&htim4) != HAL_OK)
  {
    Error_Handler();
  }
  sClockSourceConfig.ClockSource = TIM_CLOCKSOURCE_INTERNAL;
  if (HAL_TIM_ConfigClockSource(&htim4, &sClockSourceConfig) != HAL_OK)
  {
    Error_Handler();
  }
  sMasterConfig.MasterOutputTrigger = TIM_TRGO_UPDATE;
  sMasterConfig.MasterSlaveMode = TIM_MASTERSLAVEMODE_DISABLE;
  if (HAL_TIMEx_MasterConfigSynchronization(&htim4, &sMasterConfig) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN TIM4_Init 2 */

  /* USER CODE END TIM4_Init 2 */

}

/**
  * @brief USART1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART1_UART_Init(void)
{

  /* USER CODE BEGIN USART1_Init 0 */

  /* USER CODE END USART1_Init 0 */

  /* USER CODE BEGIN USART1_Init 1 */

  /* USER CODE END USART1_Init 1 */
  huart1.Instance = USART1;
  huart1.Init.BaudRate = 115200;
  huart1.Init.WordLength = UART_WORDLENGTH_8B;
  huart1.Init.StopBits = UART_STOPBITS_1;
  huart1.Init.Parity = UART_PARITY_NONE;
  huart1.Init.Mode = UART_MODE_TX_RX;
  huart1.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart1.Init.OverSampling = UART_OVERSAMPLING_16;
  huart1.Init.OneBitSampling = UART_ONE_BIT_SAMPLE_DISABLE;
  huart1.Init.ClockPrescaler = UART_PRESCALER_DIV1;
  huart1.AdvancedInit.AdvFeatureInit = UART_ADVFEATURE_SWAP_INIT;
  huart1.AdvancedInit.Swap = UART_ADVFEATURE_SWAP_ENABLE;
  if (HAL_UART_Init(&huart1) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_UARTEx_SetTxFifoThreshold(&huart1, UART_TXFIFO_THRESHOLD_1_8) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_UARTEx_SetRxFifoThreshold(&huart1, UART_RXFIFO_THRESHOLD_1_8) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_UARTEx_DisableFifoMode(&huart1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART1_Init 2 */

  /* USER CODE END USART1_Init 2 */

}

/**
  * Enable DMA controller clock
  */
static void MX_DMA_Init(void)
{

  /* DMA controller clock enable */
  __HAL_RCC_DMAMUX1_CLK_ENABLE();
  __HAL_RCC_DMA1_CLK_ENABLE();

  /* DMA interrupt init */
  /* DMA1_Channel1_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Channel1_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA1_Channel1_IRQn);

}

/**
  * @brief GPIO Initialization Function
  * @param None
  * @retval None
  */
static void MX_GPIO_Init(void)
{
  GPIO_InitTypeDef GPIO_InitStruct = {0};
/* USER CODE BEGIN MX_GPIO_Init_1 */
/* USER CODE END MX_GPIO_Init_1 */

  /* GPIO Ports Clock Enable */
  __HAL_RCC_GPIOF_CLK_ENABLE();
  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOC_CLK_ENABLE();

  HAL_GPIO_WritePin(RS485A_EN_GPIO_Port, RS485A_EN_Pin, GPIO_PIN_RESET);

  GPIO_InitStruct.Pin = RS485A_EN_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(RS485A_EN_GPIO_Port, &GPIO_InitStruct);

/* USER CODE BEGIN MX_GPIO_Init_2 */
/* USER CODE END MX_GPIO_Init_2 */
}

/* USER CODE BEGIN 4 */
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart)
{
  if (huart == &huart1)
  {
    /* HAL's one-byte RxISR can call us with an error already set. Rearming
       below clears ErrorCode, before HAL_UART_IRQHandler checks it again;
       that path does not necessarily reach HAL_UART_ErrorCallback. */
    uint32_t receive_error = huart->ErrorCode;
    uint16_t next = (uint16_t)((fsk_uart_rx_head + 1U) &
                               FSK_UART_RX_RING_MASK);

    if (receive_error != HAL_UART_ERROR_NONE)
    {
      FskUart_RecordHardwareErrors(receive_error);
      ++fsk_uart_error_count;
    }

    if (next != fsk_uart_rx_tail)
    {
      fsk_uart_rx_ring[fsk_uart_rx_head] = fsk_uart_irq_byte;
      fsk_uart_rx_head = next;
    }
    else
    {
      ++fsk_uart_overflow_count;
    }

    if (HAL_UART_Receive_IT(&huart1, &fsk_uart_irq_byte, 1U) != HAL_OK)
    {
      ++fsk_uart_error_count;
      ++fsk_uart_rearm_fail_count;
    }
  }
}

void HAL_UART_ErrorCallback(UART_HandleTypeDef *huart)
{
  if (huart == &huart1)
  {
    uint32_t error = huart->ErrorCode;
    FskUart_RecordHardwareErrors(error);
    ++fsk_uart_error_count;
    __HAL_UART_CLEAR_OREFLAG(&huart1);
    if (HAL_UART_Receive_IT(&huart1, &fsk_uart_irq_byte, 1U) != HAL_OK)
    {
      ++fsk_uart_rearm_fail_count;
    }
  }
}

/* USER CODE END 4 */

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */
  /* User can add his own implementation to report the HAL error return state */
  __disable_irq();
  while (1)
  {
  }
  /* USER CODE END Error_Handler_Debug */
}

#ifdef  USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* USER CODE BEGIN 6 */
  /* User can add his own implementation to report the file name and line number,
     ex: printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */
