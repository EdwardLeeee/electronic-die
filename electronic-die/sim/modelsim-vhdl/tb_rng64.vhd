library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_rng64 is
end entity tb_rng64;

architecture simulation of tb_rng64 is
    signal clk     : std_logic := '0';
    signal sel     : std_logic := '0';
    signal seed    : std_logic_vector(63 downto 0);
    signal rng_out : std_logic_vector(63 downto 0);
begin
    clk <= not clk after 50 ns; -- 100 ns period
    sel <= '0', '1' after 100 ns;

    read_seed : process
        file source_data : text open read_mode is "source_data.txt";
        variable input_line : line;
        variable temp       : std_logic_vector(63 downto 0);
    begin
        readline(source_data, input_line);
        read(input_line, temp);
        seed <= temp;
        wait;
    end process;

    dut : entity work.rng64(structure)
        port map (
            seed    => seed,
            clk     => clk,
            sel     => sel,
            rng_out => rng_out
        );

    write_output : process (rng_out)
        file output_data : text open write_mode is "output_data.txt";
        variable output_line : line;
    begin
        if rng_out /= (rng_out'range => 'U') then
            write(output_line, rng_out);
            writeline(output_data, output_line);
        end if;
    end process;
end architecture simulation;
