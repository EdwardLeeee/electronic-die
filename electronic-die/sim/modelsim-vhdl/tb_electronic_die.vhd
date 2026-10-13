library ieee;
use ieee.std_logic_1164.all;

entity tb_electronic_die is
end entity tb_electronic_die;

architecture simulation of tb_electronic_die is
    signal clk            : std_logic := '0';
    signal en             : std_logic := '0';
    signal tossing_result : std_logic_vector(2 downto 0);
begin
    clk <= not clk after 10 ns; -- 20 ns period

    -- Toggle en to prove that the register holds its previous value when en='0'.
    en <= '0', '1' after 35 ns, '0' after 115 ns,
          '1' after 175 ns, '0' after 255 ns;

    dut : entity work.electronic_die(rtl)
        port map (
            clk            => clk,
            en             => en,
            tossing_result => tossing_result
        );
end architecture simulation;
