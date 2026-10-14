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
#include "fpga_rx_spi.h"
#include "fpga_rx_spi_stm32.h"
#include "rs485_half_duplex.h"
#include "rx_command_text.h"
#include "rx_trace.h"
#include <string.h>
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define RS485A_RX_RING_SIZE 128U
#define RS485A_RX_RING_MASK (RS485A_RX_RING_SIZE - 1U)
#define RS485A_LINE_SIZE    64U
#define RS485A_RESPONSE_SIZE 384U
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
UART_HandleTypeDef huart1;

/* USER CODE BEGIN PV */
static fpga_rx_spi_t fpga_rx;
static fpga_rx_spi_stm32_t fpga_rx_bus;
static fpga_rx_spi_frame_meta_t fpga_rx_last_frame;
static uint8_t fpga_rx_payload[FPGA_RX_SPI_MAX_PAYLOAD];
static volatile fpga_rx_spi_result_t fpga_rx_last_result = FPGA_RX_SPI_BAD_STATE;
static volatile uint8_t fpga_rx_connected;
static volatile uint8_t fpga_rx_firmware_version;
static volatile uint8_t fpga_rx_payload_length;
static uint32_t fpga_rx_next_service_ms;
static rs485_half_duplex_t rs485a;
static uint8_t rs485a_irq_byte;
static uint8_t rs485a_rx_ring[RS485A_RX_RING_SIZE];
static volatile uint8_t rs485a_rx_head;
static volatile uint8_t rs485a_rx_tail;
static volatile uint32_t rs485a_uart_error_count;
static volatile uint32_t rs485a_rx_restart_count;
static volatile uint32_t rs485a_tx_error_count;
static volatile uint32_t rs485a_ring_overflow_count;
static char rs485a_line[RS485A_LINE_SIZE];
static uint8_t rs485a_line_length;
static uint8_t rs485a_line_overflow;
static char rs485a_response[RS485A_RESPONSE_SIZE];
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
static void MX_GPIO_Init(void);
static void MX_USART1_UART_Init(void);
/* USER CODE BEGIN PFP */

/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */
static void Rs485A_EnsureReceive(void)
{
  if (huart1.RxState == HAL_UART_STATE_READY)
  {
    if (HAL_UART_Receive_IT(&huart1, &rs485a_irq_byte, 1U) == HAL_OK)
    {
      ++rs485a_rx_restart_count;
    }
    else
    {
      ++rs485a_uart_error_count;
    }
  }
}

static void Rs485A_SendText(const char *text)
{
  size_t length;

  if (text == NULL)
  {
    return;
  }

  length = strlen(text);
  if ((length != 0U) && (length <= UINT16_MAX))
  {
    if (rs485_half_duplex_transmit(
            &rs485a, (const uint8_t *)text, (uint16_t)length, 100U) != HAL_OK)
    {
      ++rs485a_tx_error_count;
    }
  }
}

static size_t Rs485A_AppendText(char *destination, size_t capacity,
                                size_t used, const char *text)
{
  while ((*text != '\0') && ((used + 1U) < capacity))
  {
    destination[used++] = *text++;
  }
  if (capacity != 0U)
  {
    destination[used] = '\0';
  }
  return used;
}

static size_t Rs485A_AppendUnsigned64(char *destination, size_t capacity,
                                      size_t used, uint64_t value)
{
  char digits[20];
  size_t count = 0U;

  do
  {
    digits[count++] = (char)('0' + (value % 10ULL));
    value /= 10ULL;
  } while ((value != 0ULL) && (count < sizeof(digits)));

  while ((count != 0U) && ((used + 1U) < capacity))
  {
    destination[used++] = digits[--count];
  }
  if (capacity != 0U)
  {
    destination[used] = '\0';
  }
  return used;
}

static uint32_t Sweep_PhaseIncrement(uint32_t frequency_hz)
{
  return (uint32_t)((((uint64_t)frequency_hz << 32U) + 24000ULL) /
                    48000ULL);
}

static void Rs485A_HandleSweepMeasure(const char *arguments)
{
  uint32_t fields[5];
  fpga_rx_spi_sweep_config_t config;
  fpga_rx_spi_sweep_result_t measurement;
  fpga_rx_spi_result_t result;
  uint8_t status = 0U;
  uint32_t started_ms;
  uint32_t timeout_ms;
  uint64_t mean_energy;
  size_t used;

  if ((rx_command_parse_u32_fields(arguments, fields, 5U) == 0U) ||
      (fields[0] > 65535U) ||
      (fields[1] < 1500U) || (fields[1] > 2100U) ||
      (((fields[1] - 1500U) % 20U) != 0U) ||
      (fields[2] > 1000U) ||
      (fields[3] == 0U) || (fields[3] > 1000U) ||
      (fields[4] == 0U) || (fields[4] > 16U) ||
      ((fields[2] * 48U) > 65535U) ||
      ((fields[3] * 48U) > 65535U))
  {
    Rs485A_SendText("ERR SWEEP ARG\r\n");
    return;
  }
  if (fpga_rx_connected == 0U)
  {
    Rs485A_SendText("ERR SWEEP FPGA\r\n");
    return;
  }

  config.phase_increment = Sweep_PhaseIncrement(fields[1]);
  config.settle_samples = (uint16_t)(fields[2] * 48U);
  config.window_samples = (uint16_t)(fields[3] * 48U);
  config.average_count = (uint8_t)fields[4];
  result = fpga_rx_spi_sweep_start(&fpga_rx, &config);
  if (result != FPGA_RX_SPI_OK)
  {
    Rs485A_SendText("ERR SWEEP START\r\n");
    return;
  }

  timeout_ms = fields[2] + (fields[3] * fields[4]) + 1000U;
  started_ms = HAL_GetTick();
  do
  {
    HAL_Delay(2U);
    result = fpga_rx_spi_sweep_read_status(&fpga_rx, &status);
    if (result != FPGA_RX_SPI_OK)
    {
      (void)fpga_rx_spi_sweep_abort(&fpga_rx);
      Rs485A_SendText("ERR SWEEP SPI\r\n");
      return;
    }
    if ((status & FPGA_RX_SWEEP_STATUS_ERROR) != 0U)
    {
      (void)fpga_rx_spi_sweep_abort(&fpga_rx);
      Rs485A_SendText("ERR SWEEP FPGA\r\n");
      return;
    }
  } while (((status & FPGA_RX_SWEEP_STATUS_DONE) == 0U) &&
           ((HAL_GetTick() - started_ms) < timeout_ms));

  if ((status & FPGA_RX_SWEEP_STATUS_DONE) == 0U)
  {
    (void)fpga_rx_spi_sweep_abort(&fpga_rx);
    Rs485A_SendText("ERR SWEEP TIMEOUT\r\n");
    return;
  }
  result = fpga_rx_spi_sweep_read_result(&fpga_rx, &measurement);
  if (result != FPGA_RX_SPI_OK)
  {
    Rs485A_SendText("ERR SWEEP RESULT\r\n");
    return;
  }

  mean_energy = measurement.energy_sum / measurement.window_count;
  used = 0U;
  rs485a_response[0] = '\0';
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           "OK SWEEP RESULT seq=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               fields[0]);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " freq=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               fields[1]);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " n=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               measurement.window_count);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " mean=");
  used = Rs485A_AppendUnsigned64(rs485a_response, sizeof(rs485a_response), used,
                                 mean_energy);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " min=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               measurement.energy_min);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " max=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               measurement.energy_max);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " clip=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               measurement.clip_count);
  (void)Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                          "\r\n");
  Rs485A_SendText(rs485a_response);
}

static uint8_t Rs485A_AskSupported(void)
{
  return ((fpga_rx_connected != 0U) &&
          (fpga_rx_firmware_version >= FPGA_RX_SPI_ASK_MIN_FW_VERSION) &&
          (fpga_rx_firmware_version != 0xFFU)) ?
         1U : 0U;
}

static const char *Rs485A_ModeName(uint8_t mode)
{
  return (mode == (uint8_t)FPGA_RX_SPI_MODE_OOK) ? "OOK" : "FSK";
}

static void Rs485A_SendAskStatus(const fpga_rx_spi_ask_status_t *status)
{
  size_t used = 0U;

  rs485a_response[0] = '\0';
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           "OK ASK STATUS mode=");
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           Rs485A_ModeName(status->active.mode));
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " low=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->active.low_threshold);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " high=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->active.high_threshold);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " energy=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->energy);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " pending=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->pending);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " error=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->error);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " generation=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->generation);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " bit=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->hard_bit);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " locked=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->symbol_locked);
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " ready=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status->energy_ready);
  (void)Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                          "\r\n");
  Rs485A_SendText(rs485a_response);
}

static void Rs485A_HandleAskApply(uint8_t mode, uint32_t low, uint32_t high,
                                  const char *success_prefix)
{
  fpga_rx_spi_ask_config_t config;
  fpga_rx_spi_ask_status_t status;
  fpga_rx_spi_result_t result;
  size_t used = 0U;

  if (Rs485A_AskSupported() == 0U)
  {
    Rs485A_SendText("ERR ASK UNSUPPORTED\r\n");
    return;
  }
  config.mode = mode;
  config.low_threshold = low;
  config.high_threshold = high;
  result = fpga_rx_spi_ask_apply_config(&fpga_rx, &config, &status);
  if (result != FPGA_RX_SPI_OK)
  {
    Rs485A_SendText("ERR ASK APPLY\r\n");
    return;
  }

  rs485a_response[0] = '\0';
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           success_prefix);
  if (success_prefix[3] == 'A')
  {
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                             " low=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                                 low);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                             " high=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                                 high);
  }
  used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                           " pending=");
  used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response), used,
                               status.pending);
  (void)Rs485A_AppendText(rs485a_response, sizeof(rs485a_response), used,
                          "\r\n");
  Rs485A_SendText(rs485a_response);
}

static void Rs485A_HandleMod(uint8_t mode)
{
  fpga_rx_spi_ask_status_t status;

  if (Rs485A_AskSupported() == 0U)
  {
    Rs485A_SendText("ERR MOD UNSUPPORTED\r\n");
    return;
  }
  if (fpga_rx_spi_ask_read_status(&fpga_rx, &status) != FPGA_RX_SPI_OK)
  {
    Rs485A_SendText("ERR MOD STATUS\r\n");
    return;
  }
  if (status.pending != 0U)
  {
    Rs485A_SendText("ERR ASK BUSY\r\n");
    return;
  }
  if (status.error != 0U)
  {
    Rs485A_SendText("ERR ASK ERROR\r\n");
    return;
  }
  Rs485A_HandleAskApply(mode, status.active.low_threshold,
                         status.active.high_threshold,
                         (mode == (uint8_t)FPGA_RX_SPI_MODE_OOK) ?
                         "OK MOD OOK" : "OK MOD FSK");
}

static void Rs485A_HandleAskThreshold(const char *arguments)
{
  uint32_t fields[2];
  fpga_rx_spi_ask_status_t status;

  if ((rx_command_parse_u32_fields(arguments, fields, 2U) == 0U) ||
      (fields[0] >= fields[1]))
  {
    Rs485A_SendText("ERR ASK THRESH ARG\r\n");
    return;
  }
  if (Rs485A_AskSupported() == 0U)
  {
    Rs485A_SendText("ERR ASK UNSUPPORTED\r\n");
    return;
  }
  if (fpga_rx_spi_ask_read_status(&fpga_rx, &status) != FPGA_RX_SPI_OK)
  {
    Rs485A_SendText("ERR ASK STATUS\r\n");
    return;
  }
  if (status.pending != 0U)
  {
    Rs485A_SendText("ERR ASK BUSY\r\n");
    return;
  }
  if (status.error != 0U)
  {
    Rs485A_SendText("ERR ASK ERROR\r\n");
    return;
  }
  Rs485A_HandleAskApply(status.active.mode, fields[0], fields[1],
                         "OK ASK THRESH");
}

static void Rs485A_HandleLine(const char *line)
{
  static const char hex[] = "0123456789ABCDEF";
  size_t used;
  uint8_t index;

  size_t trace_length = rx_trace_command(&fpga_rx, line,
      (uint8_t *)rs485a_response, sizeof rs485a_response);
  if (trace_length != 0U)
  {
    if (rs485_half_duplex_transmit(&rs485a, (const uint8_t *)rs485a_response,
        (uint16_t)trace_length, 100U) != HAL_OK) ++rs485a_tx_error_count;
    return;
  }
  if (strcmp(line, "PING") == 0)
  {
    Rs485A_SendText("OK PONG\r\n");
    return;
  }

  if (strcmp(line, "HELP") == 0)
  {
    Rs485A_SendText("OK PING | STATUS | READ | CLEAR_ERRORS | "
                    "MOD FSK|OOK | ASK THRESH <low> <high>|STATUS | "
                    "SWEEP INFO|MEASURE|STOP | TRACE ARM|TRIGGER|STATUS|READ|STOP | HELP\r\n");
    return;
  }

  if (strcmp(line, "MOD FSK") == 0)
  {
    Rs485A_HandleMod((uint8_t)FPGA_RX_SPI_MODE_FSK);
    return;
  }

  if (strcmp(line, "MOD OOK") == 0)
  {
    Rs485A_HandleMod((uint8_t)FPGA_RX_SPI_MODE_OOK);
    return;
  }

  if (strncmp(line, "ASK THRESH ", 11U) == 0)
  {
    Rs485A_HandleAskThreshold(&line[11]);
    return;
  }

  if (strcmp(line, "ASK STATUS") == 0)
  {
    fpga_rx_spi_ask_status_t status;

    if (Rs485A_AskSupported() == 0U)
    {
      Rs485A_SendText("ERR ASK UNSUPPORTED\r\n");
    }
    else if (fpga_rx_spi_ask_read_status(&fpga_rx, &status) != FPGA_RX_SPI_OK)
    {
      Rs485A_SendText("ERR ASK STATUS\r\n");
    }
    else
    {
      Rs485A_SendAskStatus(&status);
    }
    return;
  }

  if (strcmp(line, "SWEEP INFO") == 0)
  {
    Rs485A_SendText("OK SWEEP INFO min=1500 max=2100 step=20 "
                    "settle_ms=20 window_ms=100 avg=3 fs=48000\r\n");
    return;
  }

  if (strncmp(line, "SWEEP MEASURE ", 14U) == 0)
  {
    Rs485A_HandleSweepMeasure(&line[14]);
    return;
  }

  if (strcmp(line, "SWEEP STOP") == 0)
  {
    if ((fpga_rx_connected != 0U) &&
        (fpga_rx_spi_sweep_abort(&fpga_rx) == FPGA_RX_SPI_OK))
    {
      Rs485A_SendText("OK SWEEP STOP\r\n");
    }
    else
    {
      Rs485A_SendText("ERR SWEEP STOP\r\n");
    }
    return;
  }

  if (strcmp(line, "CLEAR_ERRORS") == 0)
  {
    fpga_rx_spi_result_t clear_result = FPGA_RX_SPI_BAD_STATE;

    if (fpga_rx_connected != 0U)
    {
      clear_result = fpga_rx_spi_clear_errors(&fpga_rx);
      if ((clear_result == FPGA_RX_SPI_OK) && (Rs485A_AskSupported() != 0U))
      {
        clear_result = fpga_rx_spi_ask_clear_error(&fpga_rx);
      }
    }
    rs485a_uart_error_count = 0U;
    rs485a_rx_restart_count = 0U;
    rs485a_tx_error_count = 0U;
    rs485a_ring_overflow_count = 0U;
    if (clear_result == FPGA_RX_SPI_OK)
    {
      Rs485A_SendText("OK\r\n");
    }
    else
    {
      Rs485A_SendText("ERR CLEAR_ERRORS\r\n");
    }
    return;
  }

  if (strcmp(line, "STATUS") == 0)
  {
    used = 0U;
    rs485a_response[0] = '\0';
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, "OK fpga=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_connected);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " ver=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_firmware_version);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " result=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, (uint32_t)fpga_rx_last_result);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " len=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_payload_length);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " seq=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_last_frame.sequence);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " type=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_last_frame.frame_type);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " time_valid=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_last_frame.timestamp_valid);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " base_s=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_last_frame.base_time_s);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " elapsed10ms=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_last_frame.elapsed_10ms);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " timestamp_ms=");
    used = Rs485A_AppendUnsigned64(rs485a_response, sizeof(rs485a_response),
                                   used, fpga_rx_last_frame.timestamp_ms);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " uart_err=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, rs485a_uart_error_count);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " rx_restart=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, rs485a_rx_restart_count);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " tx_err=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, rs485a_tx_error_count);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " overflow=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, rs485a_ring_overflow_count);
    (void)Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                            used, "\r\n");
    Rs485A_SendText(rs485a_response);
    return;
  }

  if (strcmp(line, "READ") == 0)
  {
    memcpy(rs485a_response, "OK DATA ", 8U);
    used = 8U;
    for (index = 0U; index < fpga_rx_payload_length; ++index)
    {
      rs485a_response[used++] = hex[fpga_rx_payload[index] >> 4U];
      rs485a_response[used++] = hex[fpga_rx_payload[index] & 0x0FU];
    }
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " time_valid=");
    used = rx_command_append_u32(rs485a_response, sizeof(rs485a_response),
                                 used, fpga_rx_last_frame.timestamp_valid);
    used = Rs485A_AppendText(rs485a_response, sizeof(rs485a_response),
                             used, " timestamp_ms=");
    used = Rs485A_AppendUnsigned64(rs485a_response, sizeof(rs485a_response),
                                   used, fpga_rx_last_frame.timestamp_ms);
    rs485a_response[used++] = '\r';
    rs485a_response[used++] = '\n';
    rs485a_response[used] = '\0';
    Rs485A_SendText(rs485a_response);
    return;
  }

  Rs485A_SendText("ERR COMMAND\r\n");
}

static void Rs485A_ProcessByte(uint8_t byte)
{
  if ((byte == '\r') || (byte == '\n'))
  {
    if (rs485a_line_overflow != 0U)
    {
      HAL_Delay(1U);
      Rs485A_SendText("ERR LINE TOO LONG\r\n");
    }
    else if (rs485a_line_length != 0U)
    {
      HAL_Delay(1U);
      rs485a_line[rs485a_line_length] = '\0';
      Rs485A_HandleLine(rs485a_line);
    }
    rs485a_line_length = 0U;
    rs485a_line_overflow = 0U;
    return;
  }

  if ((byte == 0x08U) || (byte == 0x7FU))
  {
    if (rs485a_line_length != 0U)
    {
      --rs485a_line_length;
    }
    return;
  }

  if ((byte >= 0x20U) && (byte <= 0x7EU))
  {
    if (rs485a_line_length < (sizeof(rs485a_line) - 1U))
    {
      rs485a_line[rs485a_line_length++] = (char)byte;
    }
    else
    {
      rs485a_line_overflow = 1U;
    }
  }
}

static void Rs485A_Service(void)
{
  while (rs485a_rx_tail != rs485a_rx_head)
  {
    uint8_t byte = rs485a_rx_ring[rs485a_rx_tail];
    rs485a_rx_tail = (uint8_t)((rs485a_rx_tail + 1U) & RS485A_RX_RING_MASK);
    Rs485A_ProcessByte(byte);
  }

}

static void FpgaRx_Service(void)
{
  fpga_rx_spi_frame_meta_t metadata;
  fpga_rx_spi_result_t result;
  uint8_t firmware_version;
  size_t offset = 0U;

  /* FPGA polling is background work. Never let it take precedence over a
   * pending RS485 command, and rate-limit it so a failed SPI transaction
   * cannot starve the command responder. */
  if ((int32_t)(HAL_GetTick() - fpga_rx_next_service_ms) < 0)
  {
    return;
  }
  if (rs485a_rx_tail != rs485a_rx_head)
  {
    return;
  }
  fpga_rx_next_service_ms = HAL_GetTick() + 5U;

  if (fpga_rx_connected == 0U)
  {
    result = fpga_rx_spi_probe(&fpga_rx, &firmware_version);
    fpga_rx_last_result = result;
    fpga_rx_connected = (result == FPGA_RX_SPI_OK) ? 1U : 0U;
    if (result == FPGA_RX_SPI_OK)
    {
      fpga_rx_firmware_version = firmware_version;
    }
    return;
  }

  result = fpga_rx_spi_begin_frame(&fpga_rx, &metadata);
  if (result == FPGA_RX_SPI_EMPTY)
  {
    fpga_rx_last_result = FPGA_RX_SPI_OK;
    return;
  }
  if (result != FPGA_RX_SPI_OK)
  {
    fpga_rx_last_result = result;
    fpga_rx_connected = 0U;
    return;
  }

  while (offset < metadata.payload_length)
  {
    size_t bytes_read = 0U;
    size_t request = metadata.payload_length - offset;

    if (request > 16U)
    {
      request = 16U;
    }
    result = fpga_rx_spi_read_payload(
        &fpga_rx, &fpga_rx_payload[offset], request, &bytes_read);
    if ((result != FPGA_RX_SPI_OK) || (bytes_read == 0U))
    {
      fpga_rx_spi_result_t read_result =
          (result != FPGA_RX_SPI_OK) ? result : FPGA_RX_SPI_PROTOCOL_ERROR;
      (void)fpga_rx_spi_drop_frame(&fpga_rx);
      fpga_rx_last_result = read_result;
      fpga_rx_connected = 0U;
      return;
    }
    offset += bytes_read;
  }

  result = fpga_rx_spi_pop_frame(&fpga_rx);
  fpga_rx_last_result = result;
  if (result == FPGA_RX_SPI_OK)
  {
    fpga_rx_last_frame = metadata;
    fpga_rx_payload_length = metadata.payload_length;
  }
  else
  {
    fpga_rx_connected = 0U;
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
  uint8_t firmware_version;
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
  MX_USART1_UART_Init();
  /* USER CODE BEGIN 2 */
  if (rs485_half_duplex_init(&rs485a, &huart1,
                             RS485A_EN_GPIO_Port, RS485A_EN_Pin) != HAL_OK)
  {
    Error_Handler();
  }
  if (HAL_UART_Receive_IT(&huart1, &rs485a_irq_byte, 1U) != HAL_OK)
  {
    Error_Handler();
  }
  fpga_rx_last_result = fpga_rx_spi_stm32_init(
      &fpga_rx, &fpga_rx_bus, FPGA_RX_SPI_DEFAULT_TIMEOUT_MS);
  if (fpga_rx_last_result == FPGA_RX_SPI_OK)
  {
    fpga_rx_last_result = fpga_rx_spi_probe(&fpga_rx, &firmware_version);
    fpga_rx_connected = (fpga_rx_last_result == FPGA_RX_SPI_OK) ? 1U : 0U;
    if (fpga_rx_last_result == FPGA_RX_SPI_OK)
    {
      fpga_rx_firmware_version = firmware_version;
    }
  }
  /* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  while (1)
  {
    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
    Rs485A_EnsureReceive();
    Rs485A_Service();
    FpgaRx_Service();

    HAL_Delay(1U);
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
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSI;
  RCC_OscInitStruct.HSIState = RCC_HSI_ON;
  RCC_OscInitStruct.HSICalibrationValue = RCC_HSICALIBRATION_DEFAULT;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource = RCC_PLLSOURCE_HSI;
  RCC_OscInitStruct.PLL.PLLM = RCC_PLLM_DIV4;
  RCC_OscInitStruct.PLL.PLLN = 75;
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

  /*Configure GPIO pin Output Level */
  HAL_GPIO_WritePin(RS485A_EN_GPIO_Port, RS485A_EN_Pin, GPIO_PIN_RESET);

  /*Configure GPIO pin : RS485A_EN_Pin */
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
    uint8_t next = (uint8_t)((rs485a_rx_head + 1U) & RS485A_RX_RING_MASK);

    if (next != rs485a_rx_tail)
    {
      rs485a_rx_ring[rs485a_rx_head] = rs485a_irq_byte;
      rs485a_rx_head = next;
    }
    else
    {
      ++rs485a_ring_overflow_count;
    }

    if (HAL_UART_Receive_IT(&huart1, &rs485a_irq_byte, 1U) != HAL_OK)
    {
      ++rs485a_uart_error_count;
    }
  }
}

void HAL_UART_ErrorCallback(UART_HandleTypeDef *huart)
{
  if (huart == &huart1)
  {
    ++rs485a_uart_error_count;
    __HAL_UART_CLEAR_FLAG(&huart1, UART_CLEAR_OREF | UART_CLEAR_NEF |
                                  UART_CLEAR_FEF | UART_CLEAR_PEF);

    /* ORE aborts the HAL receive transaction.  FE/NE/PE are recoverable and
     * may leave the current one-byte transaction active, so only re-arm when
     * HAL has returned the receiver to READY.  The main-loop watchdog covers
     * a failed re-arm without disturbing an active receive transaction. */
    Rs485A_EnsureReceive();
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
