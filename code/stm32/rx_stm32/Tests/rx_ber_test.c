#include "rx_ber.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t regs[128], records[8][64], snapshot[32], count, enabled, busy;
    uint8_t offset, head, selected, obs_page;
    uint8_t obs[96], events[1024];
    int obs_corrupt_once;
    uint32_t popped, committed;
    unsigned writes, reads, record_reads, fail_on, calls;
    int corrupt_once, commit_on_pop;
} mock_t;

static void put32(uint8_t *p, uint32_t value)
{
    p[0]=(uint8_t)value; p[1]=(uint8_t)(value>>8);
    p[2]=(uint8_t)(value>>16); p[3]=(uint8_t)(value>>24);
}
static void snapshot(mock_t *m)
{
    memset(m->snapshot,0,32);
    memcpy(m->snapshot,"BS01",4);
    m->snapshot[4]=(uint8_t)(16U | m->enabled | (m->busy?2U:0U) |
                            (m->count?4U:0U) | (m->count==8?8U:0U));
    m->snapshot[5]=m->count;m->snapshot[6]=8;m->snapshot[7]=64;
    put32(m->snapshot+16,m->committed);put32(m->snapshot+24,m->popped);
}
static void cs(void *context, bool selected)
{
    ((mock_t *)context)->selected=(uint8_t)selected;
}
static fpga_rx_spi_result_t transfer(void *context,const uint8_t *tx,
                                    uint8_t *rx,size_t n,uint32_t timeout)
{
    mock_t *m=context; uint8_t a=tx[0]&127U;
    (void)timeout;
    assert(m->selected);
    assert(n<=65U);
    memset(rx,0,n);
    m->calls++;
    if(m->fail_on && m->calls==m->fail_on) {
        /* Emulate a failed SPI transfer which clocked some stream bytes. */
        if(a==0x4eU)m->offset=(uint8_t)(m->offset+3U);
        return FPGA_RX_SPI_IO_ERROR;
    }
    if((tx[0]&128U) && a==0x4eU && m->offset<64U)m->record_reads++;
    for(size_t i=1;i<n;i++) {
        if(tx[0]&128U) {
            m->reads++;
            if(a==0x4eU) {
                if(m->offset>=0xa0U) {
                    rx[i]=m->obs[m->offset-0xa0U];
                    if(m->obs_corrupt_once && m->offset==0xb0U){rx[i]^=1U;m->obs_corrupt_once=0;}
                    if(m->offset<0xffU)m->offset++;
                } else if(m->offset>=0x40U && m->offset<0x80U) {
                    rx[i]=m->events[m->obs_page*64U+m->offset-0x40U];
                    if(m->offset<0x7fU)m->offset++;
                } else if(m->offset>=0x80U && m->offset<0xa0U)
                    rx[i]=m->snapshot[m->offset++ - 0x80U];
                else {
                    assert(m->offset<64U);
                    rx[i]=m->records[m->head][m->offset];
                    if(m->corrupt_once && m->offset==20U) {
                        rx[i]^=1U;m->corrupt_once=0;
                    }
                    if(m->offset<63U)m->offset++;
                }
            } else if(a==0x4bU)rx[i]=16U;
            else rx[i]=m->regs[a];
        } else {
            m->writes++;
            /* No BER operation may access normal frame controls/data. */
            assert(a==0x4dU || a==0x4aU);
            if(a==0x4dU) {
                m->offset=tx[i];if(tx[i]==0x80U)snapshot(m);
            } else if(tx[i]==1U)m->enabled=1;
            else if(tx[i]==2U){m->enabled=0;if(m->obs[8]&1U)m->obs[8]=6U;}
            else if(tx[i]==4U){m->count=0;m->head=0;m->popped=0;}
            else if(tx[i]==0x10U){m->obs[8]=5U;m->obs[4]++;}
            else if(tx[i]==8U){
                assert(m->count);m->count--;m->head=(m->head+1U)&7U;
                if(m->commit_on_pop){m->count++;m->committed++;}
                m->popped++;m->offset=0;
            } else if(tx[i]==0x20U)m->obs[8]=6U;
            else if(tx[i]>=0x80U && tx[i]<=0x8fU)m->obs_page=tx[i]-0x80U;
        }
        if(a!=0x4eU)a=(a+1U)&127U;
    }
    return FPGA_RX_SPI_OK;
}
static void init(mock_t *m, fpga_rx_spi_t *dev)
{
    memset(m,0,sizeof(*m));m->regs[0]=0xa7;m->regs[1]=0x14;
    m->regs[0x49]=0xb1;m->regs[0x4f]=1;
    memcpy(m->obs,"BO01",4);m->obs[8]=4;
    for(unsigned j=0;j<1024;j++)m->events[j]=(uint8_t)(j*3U);
    for(unsigned i=0;i<8;i++) {
        memcpy(m->records[i],"BR01",4);put32(m->records[i]+4,i+1U);
        m->records[i][8]=0x48;m->records[i][9]=1;
        m->records[i][10]=0x71;m->records[i][11]=41;
        for(unsigned j=16;j<57;j++)m->records[i][j]=(uint8_t)(j+i);
    }
    fpga_rx_spi_bus_t bus={transfer,cs,m,100};
    assert(fpga_rx_spi_init(dev,&bus)==FPGA_RX_SPI_OK);
}
static void command(fpga_rx_spi_t *dev,const char *cmd,uint8_t *out,const char *prefix)
{
    size_t n=rx_ber_command(dev,cmd,out,384);
    assert(n && n<384U && out[n]==0);
    assert(strncmp((char *)out,prefix,strlen(prefix))==0);
    assert(out[n-2]=='\r' && out[n-1]=='\n');
}
int main(void)
{
    mock_t m;fpga_rx_spi_t dev;uint8_t out[384],original[384];unsigned old;
    init(&m,&dev);
    assert(rx_ber_crc16((const uint8_t *)"123456789",9)==0x29b1);
    assert(rx_ber_command(&dev,"READ",out,sizeof(out))==0);
    command(&dev,"BER",out,"ERR BER COMMAND");
    command(&dev,"BER POP -1",out,"ERR BER ARG");
    command(&dev,"BER POP 4294967296",out,"ERR BER ARG");
    command(&dev,"BER POP 1 2",out,"ERR BER ARG");
    old=m.writes;
    assert(rx_ber_command(&dev,"BER START",out,32)>0);
    assert(strcmp((char *)out,"ERR BER CAPACITY\r\n")==0 && m.writes==old);
    command(&dev,"BER STATUS",out,"OK BER STATUS ");
    command(&dev,"BER HEALTH",out,"OK BER HEALTH 42483031A714");
    command(&dev,"BER READ",out,"OK BER EMPTY");
    command(&dev,"BER START",out,"OK BER ACK");assert(m.enabled);
    command(&dev,"BER START",out,"ERR BER BUSY_OR_UNAVAILABLE");
    command(&dev,"BER CLEAR",out,"ERR BER BUSY");
    command(&dev,"BER STOP",out,"OK BER ACK");assert(!m.enabled);
    m.count=2;m.committed=2;
    command(&dev,"BER READ",out,"OK BER RECORD ");memcpy(original,out,sizeof(out));
    assert(m.record_reads==2 && m.count==2);
    command(&dev,"BER READ",out,"OK BER RECORD ");assert(strcmp((char *)out,(char *)original)==0);
    /* Validate serial CRC against the exact raw record. */
    {char suffix[20];snprintf(suffix,sizeof(suffix)," crc=%04X\r\n",rx_ber_crc16(m.records[0],64));
     assert(strstr((char *)out,suffix)!=NULL);}
    m.corrupt_once=1;command(&dev,"BER READ",out,"ERR BER SPI");assert(m.count==2);
    command(&dev,"BER READ",out,"OK BER RECORD ");assert(strcmp((char *)out,(char *)original)==0);
    m.fail_on=m.calls+6U;command(&dev,"BER READ",out,"ERR BER SPI");
    m.fail_on=0;command(&dev,"BER READ",out,"OK BER RECORD ");
    assert(strcmp((char *)out,(char *)original)==0 && !m.selected);
    command(&dev,"BER POP 2",out,"ERR BER ID");assert(m.count==2 && m.popped==0);
    m.commit_on_pop=1;command(&dev,"BER POP 1",out,"OK BER ACK");
    assert(m.count==2 && m.popped==1 && m.head==1);
    command(&dev,"BER POP 1",out,"ERR BER ID");assert(m.popped==1);
    m.commit_on_pop=0;command(&dev,"BER POP 2",out,"OK BER ACK");assert(m.count==1);
    command(&dev,"BER CLEAR",out,"OK BER ACK");assert(m.count==0);
    m.busy=1;command(&dev,"BER CLEAR",out,"ERR BER BUSY");m.busy=0;
    m.regs[0x49]=0;command(&dev,"BER STATUS",out,"ERR BER UNSUPPORTED");
    init(&m,&dev);m.fail_on=1;command(&dev,"BER STATUS",out,"ERR BER SPI");assert(!m.selected);
    init(&m,&dev);
    old=m.writes;command(&dev,"BER OBS INFO",out,"ERR BER UNSUPPORTED");assert(m.writes==old);
    m.regs[0x4f]=2;
    command(&dev,"BER OBS INFO",out,"OK BER OBS INFO 424F3031");
    old=m.writes;assert(rx_ber_command(&dev,"BER OBS ARM",out,192U)>0);
    assert(strcmp((char*)out,"ERR BER CAPACITY\r\n")==0 && m.writes==old);
    command(&dev,"BER OBS ARM",out,"OK BER OBS ARM 01000000");
    command(&dev,"BER OBS ARM",out,"ERR BER OBS BUSY");
    command(&dev,"BER OBS READ",out,"ERR BER OBS BUSY");
    command(&dev,"BER OBS STOP",out,"OK BER ACK");
    command(&dev,"BER OBS READ",out,"OK BER OBS READ 424F3031");
    m.obs_corrupt_once=1;command(&dev,"BER OBS READ",out,"ERR BER SPI");
    command(&dev,"BER OBS READ",out,"OK BER OBS READ 424F3031");
    command(&dev,"BER OBS PAGE 15",out,"OK BER OBS PAGE ");assert(m.obs_page==15);
    old=m.writes;command(&dev,"BER OBS PAGE 16",out,"ERR BER ARG");assert(m.writes==old);
    command(&dev,"BER OBS PAGE -1",out,"ERR BER ARG");
    command(&dev,"BER OBS PAGE 0 1",out,"ERR BER ARG");
    assert(m.count==0 && m.popped==0 && m.record_reads==0);
    puts("PASS rx_ber: CRC/capacity/parser/START-STOP/read-retry/SPI-failure/ID-POP/concurrent-commit, no normal FIFO accesses");
    return 0;
}
