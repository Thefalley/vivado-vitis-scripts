# open_sim.tcl - Create a local Vivado project and launch behavioral
# simulation of bram_stream_tb in the GUI. Used locally only, not on
# the server. Invoke with:
#
#   vivado -source sim/open_sim.tcl
#
# Vivado opens in GUI mode, creates a throwaway project under
# sim_gui_proj/, adds the sources and the testbench, and calls
# launch_simulation which pops up an xsim GUI window with the wave
# viewer. The script pre-adds every signal in the TB to the wave
# window and runs for 2500 ns so the user sees a populated waveform
# straight away.

set proj_dir C:/project/vivado/P_100_bram_stream/sim_gui_proj
set src_dir  C:/project/vivado/P_100_bram_stream/src
set sim_dir  C:/project/vivado/P_100_bram_stream/sim

file delete -force $proj_dir

create_project bram_stream_sim $proj_dir -part xc7z020clg484-1 -force
set_property target_language VHDL [current_project]

add_files -norecurse $src_dir/HsSkidBuf_dest.vhd
add_files -norecurse $src_dir/bram_sp.vhd
add_files -norecurse $src_dir/bram_stream.vhd

add_files -fileset sim_1 -norecurse $sim_dir/bram_stream_tb.vhd
set_property file_type {VHDL 2008} [get_files bram_stream_tb.vhd]
set_property top bram_stream_tb [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Start the behavioural sim; opens xsim GUI
launch_simulation

# Populate the wave window with every signal in the TB
add_wave -r /bram_stream_tb/*
run 2500 ns
