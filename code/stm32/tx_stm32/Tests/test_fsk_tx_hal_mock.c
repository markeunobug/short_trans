#include "fsk_tx.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
extern const uint32_t *mock_dac_dma_data; extern uint32_t mock_dac_dma_length;
extern uint32_t mock_dac_start_dma_count, mock_dac_stop_dma_count;
extern uint32_t mock_tim_start_count, mock_tim_stop_count;
void HAL_DAC_ConvHalfCpltCallbackCh1(DAC_HandleTypeDef *hdac);
void HAL_DAC_ConvCpltCallbackCh1(DAC_HandleTypeDef *hdac);
static void midpoint(const uint16_t *x) { uint16_t i; for(i=0;i<FSK_TX_SYMBOL_SAMPLES;++i) assert(x[i] == FSK_TX_DAC_MIDPOINT); }
static void ook(const uint16_t *x) { uint16_t i; uint8_t changed=0U; for(i=0;i<FSK_TX_SYMBOL_SAMPLES;++i) { assert(x[i] == x[i % FSK_TX_OOK_LUT_SAMPLES]); if(x[i] != FSK_TX_DAC_MIDPOINT) changed=1U; } assert(changed); assert(x[0] == FSK_TX_DAC_MIDPOINT); assert(x[40] == FSK_TX_DAC_MIDPOINT); assert(x[7] > FSK_TX_DAC_MIDPOINT); assert(x[20] < FSK_TX_DAC_MIDPOINT); assert(x[60] > FSK_TX_DAC_MIDPOINT); }
/* Count positive-going crossings over one cyclic 10 ms DMA half-buffer. */
static void fsk(const uint16_t *x, unsigned cycles) {
 unsigned i, crossings=0;
 for(i=0;i<FSK_TX_SYMBOL_SAMPLES;++i) {
  assert(x[i] <= 4095U);
  if(x[i] <= FSK_TX_DAC_MIDPOINT && x[(i+1U)%FSK_TX_SYMBOL_SAMPLES] > FSK_TX_DAC_MIDPOINT) ++crossings;
 }
 assert(crossings == cycles);
 assert(x[0] == FSK_TX_DAC_MIDPOINT);
 assert(x[240] == FSK_TX_DAC_MIDPOINT);
}
static void complete_line(const char *line) { size_t length=strlen(line); assert(length >= 2U); assert(line[length-2U]=='\r'); assert(line[length-1U]=='\n'); }
int main(void) {
 DMA_Channel_TypeDef channel={0}; DMA_HandleTypeDef dma={.Instance=&channel}; DAC_HandleTypeDef dac={.Instance=DAC1,.DMA_Handle1=&dma}; TIM_HandleTypeDef tim={.Instance=TIM4}; char reply[320]; uint8_t n; FskTx_Status status;
 assert(FskTx_Init(&dac,&tim)==FSK_TX_OK); assert(mock_dac_dma_length==FSK_TX_DMA_SAMPLES);
 assert(mock_dac_start_dma_count==1U); assert(mock_dac_stop_dma_count==1U);
 assert(mock_tim_start_count==1U); assert(mock_tim_stop_count==2U);
 assert(FskTx_HandleUartCommand("MOD OOK",reply,sizeof(reply))==FSK_TX_OK); assert(strcmp(reply,"OK MOD OOK\r\n")==0);
 assert(FskTx_HandleUartCommand("MODE PACKET",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK); midpoint((const uint16_t*)mock_dac_dma_data);
 for(n=0;n<10U;++n) { HAL_DAC_ConvHalfCpltCallbackCh1(&dac); midpoint((const uint16_t*)mock_dac_dma_data); }
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); ook((const uint16_t*)mock_dac_dma_data); HAL_DAC_ConvHalfCpltCallbackCh1(&dac); midpoint((const uint16_t*)mock_dac_dma_data);
 assert(FskTx_HandleUartCommand("MOD FSK",reply,sizeof(reply))==FSK_TX_ERROR_BUSY); assert(strcmp(reply,"ERR busy\r\n")==0);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK); HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac); midpoint((const uint16_t*)mock_dac_dma_data); midpoint((const uint16_t*)mock_dac_dma_data + FSK_TX_SYMBOL_SAMPLES); assert(FskTx_HandleUartCommand("MODE ALT",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
 midpoint((const uint16_t*)mock_dac_dma_data); ook((const uint16_t*)mock_dac_dma_data + FSK_TX_SYMBOL_SAMPLES);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("MODE PRBS",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
 ook((const uint16_t*)mock_dac_dma_data); HAL_DAC_ConvHalfCpltCallbackCh1(&dac); ook((const uint16_t*)mock_dac_dma_data); HAL_DAC_ConvHalfCpltCallbackCh1(&dac); midpoint((const uint16_t*)mock_dac_dma_data);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("MOD FSK",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("MODE TONE1700",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
 fsk((const uint16_t*)mock_dac_dma_data,17U);
 fsk((const uint16_t*)mock_dac_dma_data + FSK_TX_SYMBOL_SAMPLES,17U);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); fsk((const uint16_t*)mock_dac_dma_data,17U);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK);
 assert(FskTx_HandleUartCommand("MODE TONE1900",reply,sizeof(reply))==FSK_TX_OK);
 assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
 fsk((const uint16_t*)mock_dac_dma_data,19U);
 fsk((const uint16_t*)mock_dac_dma_data + FSK_TX_SYMBOL_SAMPLES,19U);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK);
 assert(FskTx_HandleUartCommand("MODE ALT",reply,sizeof(reply))==FSK_TX_OK);
 assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac);
 fsk((const uint16_t*)mock_dac_dma_data,17U);
 fsk((const uint16_t*)mock_dac_dma_data + FSK_TX_SYMBOL_SAMPLES,19U);
 HAL_DAC_ConvHalfCpltCallbackCh1(&dac); fsk((const uint16_t*)mock_dac_dma_data,17U);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK);
 assert(FskTx_HandleUartCommand("MODE TONE1600",reply,sizeof(reply))==FSK_TX_ERROR_COMMAND);
 assert(FskTx_HandleUartCommand("MODE TONE2000",reply,sizeof(reply))==FSK_TX_ERROR_COMMAND);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("MODE CARRIER",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("SEND",reply,sizeof(reply))==FSK_TX_OK); HAL_DAC_ConvHalfCpltCallbackCh1(&dac); HAL_DAC_ConvCpltCallbackCh1(&dac); ook((const uint16_t*)mock_dac_dma_data);
 assert(FskTx_HandleUartCommand("STOP",reply,sizeof(reply))==FSK_TX_OK); assert(FskTx_HandleUartCommand("SWEEP TONE 7 1800 256",reply,sizeof(reply))==FSK_TX_OK); assert(((const uint16_t*)mock_dac_dma_data)[7] != FSK_TX_DAC_MIDPOINT); assert(FskTx_HandleUartCommand("MOD OOK",reply,sizeof(reply))==FSK_TX_ERROR_BUSY); assert(FskTx_HandleUartCommand("SWEEP OFF",reply,sizeof(reply))==FSK_TX_OK);
 assert(mock_dac_start_dma_count==1U); assert(mock_dac_stop_dma_count==1U);
 assert(mock_tim_start_count==1U); assert(mock_tim_stop_count==2U);
 FskTx_GetStatus(&status); assert(status.render_call_count > 0U); assert(status.render_uart_budget_cycles > 0U); assert(status.render_cycle_counter_available == 0U); assert(status.render_max_cycles == 0U);
 assert(FskTx_HandleUartCommand("STATUS",reply,sizeof(reply))==FSK_TX_OK); assert(strstr(reply,"mod=FSK") != NULL); assert(strstr(reply," ccr=") != NULL); complete_line(reply);
 assert(FskTx_HandleUartCommand("HELP",reply,sizeof(reply))==FSK_TX_OK); assert(strstr(reply,"CARRIER") != NULL); assert(strstr(reply,"UART DIAG") != NULL); complete_line(reply);
 puts("PASS: HAL-mock C waveform validates OOK midpoint/1800 Hz LUT, FSK 1700/1900 Hz DMA halves/ALT, and complete UART responses"); return 0;
}
