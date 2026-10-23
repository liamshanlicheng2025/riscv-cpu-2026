if {[catch {
set report_dir "/tmp/opencode/cpu-synth/build/synth/opt"
set clock_port "clock"
set clock_period 2
read_liberty "/opt/asap7/lib/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
read_liberty "/opt/asap7/lib/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"
read_liberty "/tmp/opencode/cpu-synth/build/synth/opt/ram/fakeram_asap7_1024x19.lib"
read_liberty "/tmp/opencode/cpu-synth/build/synth/opt/ram/fakeram_asap7_1024x8.lib"
read_liberty "/tmp/opencode/cpu-synth/build/synth/opt/ram/fakeram_asap7_128x37.lib"
read_liberty "/tmp/opencode/cpu-synth/build/synth/opt/ram/fakeram_asap7_256x21.lib"
read_liberty "/tmp/opencode/cpu-synth/build/synth/opt/ram/fakeram_asap7_256x8.lib"
set_cmd_units -time ns -capacitance fF
read_verilog "/tmp/opencode/cpu-synth/build/synth/opt/mapped.v"
link_design student_top
source "/tmp/opencode/cpu-synth/scripts/timing.tcl"
} message]} {
  puts stderr "Timing analysis failed: $message"
  exit 1
}
exit 0
