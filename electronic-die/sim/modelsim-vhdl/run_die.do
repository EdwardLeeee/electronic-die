transcript on
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vcom -2008 ca_cell.vhd
vcom -2008 rng64.vhd
vcom -2008 modulo_by_6.vhd
vcom -2008 electronic_die.vhd
vcom -2008 tb_electronic_die.vhd
vsim -voptargs=+acc work.tb_electronic_die
add wave -divider {Electronic Die Inputs and Output}
add wave sim:/tb_electronic_die/clk
add wave sim:/tb_electronic_die/en
add wave -radix unsigned sim:/tb_electronic_die/tossing_result
add wave -divider {Internal Signals}
add wave sim:/tb_electronic_die/dut/init_done
add wave -radix binary sim:/tb_electronic_die/dut/rng_value
add wave -radix unsigned sim:/tb_electronic_die/dut/mod_value
run 320 ns
