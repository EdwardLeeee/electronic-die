library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_rng64_behavior is
end entity;

architecture simulation of tb_rng64_behavior is
    signal clk     : std_logic := '0';
    signal sel     : std_logic := '0';
    signal seed    : std_logic_vector(63 downto 0) := std_logic_vector(to_unsigned(122059, 64));
    signal rng_out : std_logic_vector(63 downto 0);
begin
    dut : entity work.rng64_behavior(behavior)
        port map (
            clk     => clk,
            sel     => sel,
            seed    => seed,
            rng_out => rng_out
        );

    clk <= not clk after 50 ns;

    process
        file out_file : text open write_mode is "rng_output_vhdl.txt";
        variable row  : line;
    begin
        wait for 100 ns;
        sel <= '1';

        for i in 0 to 31 loop
            wait until rising_edge(clk);
            write(row, rng_out);
            writeline(out_file, row);
        end loop;

        wait;
    end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity tb_electronic_die_behavior is
end entity;

architecture simulation of tb_electronic_die_behavior is
    signal clk            : std_logic := '0';
    signal en             : std_logic := '0';
    signal tossing_result : std_logic_vector(2 downto 0);
begin
    dut : entity work.electronic_die_behavior(behavior)
        port map (
            clk            => clk,
            en             => en,
            tossing_result => tossing_result
        );

    clk <= not clk after 10 ns;

    process
    begin
        wait for 35 ns;
        en <= '1';
        wait for 80 ns;
        en <= '0';
        wait for 60 ns;
        en <= '1';
        wait for 80 ns;
        en <= '0';
        wait for 65 ns;
        wait;
    end process;
end architecture;
