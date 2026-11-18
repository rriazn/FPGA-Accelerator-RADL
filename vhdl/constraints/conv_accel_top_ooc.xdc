# Timing constraints for conv_accel_top synthesized on its own (out of context), not for the block design
# not run in Vivado yet, check the messages of the first run
# in the block design this file is not needed: the PS7 IP creates the clock constraint of FCLK_CLK0 and the pin constraints
# the accelerator has no pins of its own, all its ports are internal AXI nets
# use: docs/plans/vivado-block-design.md, section 4a (add as a constraint file used for synthesis only)

# 100 MHz to start with, 5.000 for the 200 MHz of D5
create_clock -name aclk -period 10.000 [get_ports aclk]

# boundary budget of the AXI ports towards the interconnect registers, an assumption, not a measured value
# without it the paths from the ports into the design are not timed in an out of context run
set_input_delay  -clock aclk 2.000 [get_ports -filter {DIRECTION == IN  && NAME != "aclk"}]
set_output_delay -clock aclk 2.000 [get_ports -filter {DIRECTION == OUT}]
