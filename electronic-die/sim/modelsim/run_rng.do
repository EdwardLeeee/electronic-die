transcript on
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vlog ca_cell.v
vlog rng64.v
vlog tb_rng64.v
vsim -voptargs=+acc work.tb_rng64
add wave -divider {RNG Test Bench}
add wave sim:/tb_rng64/clk
add wave sim:/tb_rng64/sel
add wave -radix binary sim:/tb_rng64/seed
add wave -radix binary sim:/tb_rng64/rng_out
run 3250 ns
