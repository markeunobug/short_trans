#include "rx_trace.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t reg[128], capture[24640];
    size_t seek, writes;
    int selected, fail;
    uint8_t arm_status;
} mock_t;
static void cs(void *ctx, bool selected) { ((mock_t *)ctx)->selected = selected; }
static fpga_rx_spi_result_t transfer(void *ctx,const uint8_t *tx,uint8_t *rx,size_t n,uint32_t timeout)
{
    mock_t *m=ctx;
    uint8_t a=tx[0]&127;
    (void)timeout;
    assert(m->selected);
    if (m->fail) return FPGA_RX_SPI_IO_ERROR;
    memset(rx,0,n);
    for(size_t i=1;i<n;i++) {
        if(tx[0]&128) {
            rx[i]=(a==0x42)?m->capture[m->seek++]:m->reg[a];
        } else {
            m->reg[a]=tx[i];m->writes++;
            if(a==0x3a) m->seek=(m->seek&0xff00)|tx[i];
            if(a==0x3b) m->seek=(m->seek&255)|((size_t)tx[i]<<8);
            if(a==0x33) {
                if(tx[i]==1) m->reg[0x37]=m->arm_status;
                if(tx[i]==4) m->reg[0x37]=12;
            }
        }
        if(a!=0x42) a=(a+1)&127;
    }
    return FPGA_RX_SPI_OK;
}
static size_t decode(const uint8_t *in,size_t n,uint8_t *out)
{
    size_t i=1,j=0;
    assert(in[0]==0 && in[n-1]==0);
    while(i<n-1) {
        unsigned code=in[i++]; assert(code && i+code-1<=n-1);
        for(unsigned k=1;k<code;k++) out[j++]=in[i++];
        if(code!=255 && i<n-1) out[j++]=0;
    }
    return j;
}
int main(int argc,char **argv)
{
    mock_t m={0};
    fpga_rx_spi_t dev;
    fpga_rx_spi_bus_t bus={transfer,cs,&m,100};
    uint8_t out[384],raw[384];size_t n,k;
    m.reg[0]=0xa7;m.reg[1]=0x14;m.reg[0x32]=0xd1;m.arm_status=1;
    m.reg[0x37]=6;m.reg[0x38]=8;m.reg[0x3c]=1;m.reg[0x3e]=5;
    for(k=0;k<sizeof m.capture;k++) m.capture[k]=(uint8_t)k;
    assert(fpga_rx_spi_init(&dev,&bus)==FPGA_RX_SPI_OK);
    assert(rx_trace_crc16((const uint8_t *)"123456789",9)==0x29b1);
    assert(rx_trace_command(&dev,"STATUS",out,sizeof out)==0);
    m.reg[1]=0x13;
    n=rx_trace_command(&dev,"TRACE STATUS",out,sizeof out);
    assert(n && strstr((char *)out,"status=6"));
    m.reg[1]=0x14;
    n=rx_trace_command(&dev,"TRACE STATUS",out,sizeof out);
    assert(n && strstr((char *)out,"id=1 count=8"));
    n=rx_trace_command(&dev,"TRACE READ 1 60 192",out,sizeof out);
    k=decode(out,n,raw);assert(k==204 && memcmp(raw,"DTB1",4)==0);
    for(k=0;k<192;k++) assert(raw[10+k]==(uint8_t)(60+k));
    assert(rx_trace_crc16(raw,202)==(uint16_t)(raw[202]|((unsigned)raw[203]<<8)));
    n=rx_trace_command(&dev,"TRACE READ 1 60 192",out,sizeof out);
    decode(out,n,raw);assert(raw[10]==60 && raw[201]==251);
    const char *bad[]={"TRACE READ 2 0 1","TRACE READ 1 0 0","TRACE READ 1 0 193",
        "TRACE READ 1 447 2","TRACE READ 1 4294967295 1","TRACE READ 1 -1 1",
        "TRACE ARM 0 128","TRACE ARM 128 1","TRACE ARM 1 512","TRACE ARM 1 2 extra"};
    for(k=0;k<sizeof bad/sizeof bad[0];k++) {
        assert(rx_trace_command(&dev,bad[k],out,sizeof out)>0);assert(memcmp(out,"ERR",3)==0);
    }
    assert(rx_trace_command(&dev,"TRACE ARM 16 128",out,sizeof out)>0);
    assert(m.reg[0x34]==16 && m.reg[0x35]==128 && m.reg[0x37]==1);
    rx_trace_command(&dev,"TRACE ARM 1 0",out,sizeof out);assert(memcmp(out,"ERR",3)==0);
    rx_trace_command(&dev,"TRACE TRIGGER",out,sizeof out);assert(m.reg[0x33]==2);
    rx_trace_command(&dev,"TRACE STOP",out,sizeof out);assert(m.reg[0x37]==12);
    m.arm_status=6;
    rx_trace_command(&dev,"TRACE ARM 16 0",out,sizeof out);assert(memcmp(out,"OK TRACE ACK",12)==0);
    m.reg[1]=0x12;size_t writes=m.writes;
    rx_trace_command(&dev,"TRACE ARM 1 0",out,sizeof out);
    assert(memcmp(out,"ERR TRACE UNSUPPORTED",21)==0 && m.writes==writes);
    m.reg[1]=0x14;m.fail=1;
    rx_trace_command(&dev,"TRACE STATUS",out,sizeof out);assert(memcmp(out,"ERR",3)==0);
    m.fail=0;
    if(argc==3) {
        FILE *input=fopen(argv[1],"rb"); assert(input);
        size_t total=fread(m.capture,1,sizeof m.capture,input);fclose(input);assert(total==448);
        m.reg[0x37]=6;
        FILE *output=fopen(argv[2],"wb"); assert(output);
        for(size_t offset=0;offset<total;) {
            char cmd[64];size_t len=total-offset;if(len>192)len=192;
            snprintf(cmd,sizeof cmd,"TRACE READ 1 %u %u",(unsigned)offset,(unsigned)len);
            n=rx_trace_command(&dev,cmd,out,sizeof out);assert(out[0]==0);
            assert(fwrite(out,1,n,output)==n);offset+=len;
        }
        fclose(output);
    }
    puts("rx_trace_test: PASS");return 0;
}
