transcript on
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vlog ca_cell.v
vlog rng64.v
vlog modulo_by_6.v
vlog electronic_die.v
vlog tb_electronic_die.v
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
