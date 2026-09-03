create_clock -name FPGA_CLK -period 33.333 [get_ports {FPGA_CLK}]
create_clock -name ACLK_FPGA -period 40.690 [get_ports {ACLK_FPGA}]
create_clock -name ADC_BCLK -period 325.521 [get_ports {ADC_BCLK}]
derive_clock_uncertainty

# The ADC I2S clock, board MCLK and 30 MHz system clock are unrelated. Data
# crosses ADC_BCLK to FPGA_CLK only through the Gray-pointer sample FIFO, and
# the MCLK monitor crosses through a two-flop toggle synchronizer.
set_clock_groups -asynchronous \
    -group [get_clocks {FPGA_CLK}] \
    -group [get_clocks {ACLK_FPGA}] \
    -group [get_clocks {ADC_BCLK}]

# TLV320ADC6120 datasheet sections 7.8/7.9: in ASI master mode BCLK-to-
# SDOUT and BCLK-to-FSYNC delays are 3 ns minimum and 18 ns maximum. The ADC
# launches on the opposite BCLK edge from this receiver's rising-edge sample.
set_input_delay -clock ADC_BCLK -clock_fall -min 3 \
    [get_ports {ADC_SDOUT ADC_FSYNC}]
set_input_delay -clock ADC_BCLK -clock_fall -max 18 \
    [get_ports {ADC_SDOUT ADC_FSYNC}]

# SPI1 is oversampled by FPGA_CLK; its three input pins terminate at explicit
# synchronizer flops. SPI3 is reserved and unused in V1.0.
set_false_path -from [get_ports {SPI1_SCK SPI1_NSS SPI1_MOSI}]
set_false_path -from [get_ports {SPI3_SCK SPI3_NSS SPI3_MOSI}]
set_false_path -from [get_ports {ADC_SDA}]

# These protocol outputs operate far below clk_sys. Constrain internal launch
# to pin delay without inventing an unrelated external capture clock.
set_max_delay 100 -to [get_ports {ADC_SCL ADC_SDA SPI1_MISO}]
set_min_delay 0 -to [get_ports {ADC_SCL ADC_SDA SPI1_MISO}]
