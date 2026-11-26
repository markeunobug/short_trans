project_open rx_cyclone10 -revision rx_cyclone10
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -from_clock FPGA_CLK -to_clock FPGA_CLK \
    -npaths 10 -detail full_path \
    -file output_files/rx_cyclone10_critical_paths.txt
delete_timing_netlist
project_close
