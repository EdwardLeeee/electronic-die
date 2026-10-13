transcript on
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vcom -2008 ca_cell.vhd
vcom -2008 rng64.vhd
vcom -2008 tb_rng64.vhd
vsim -voptargs=+acc work.tb_rng64
add wave -divider {RNG Test Bench}
add wave sim:/tb_rng64/clk
add wave sim:/tb_rng64/sel
add wave -radix binary sim:/tb_rng64/seed
add wave -radix binary sim:/tb_rng64/rng_out
run 3250 ns
