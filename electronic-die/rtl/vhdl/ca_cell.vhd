library ieee;
use ieee.std_logic_1164.all;

entity ca_cell is
    port (
        adr  : in  std_logic_vector(3 downto 0);--4bit neghbor state
        clk  : in  std_logic;
        --load seed or not, sel ='0'
        -- if sel='0', y <=init;else y<= next_state
        sel  : in  std_logic;
        init : in  std_logic;
        y    : out std_logic
    );
end entity ca_cell;

architecture rtl of ca_cell is
    signal next_state : std_logic;
begin
    -- Chapter 8 LUT: adr = a & b & c & d.
    with adr select
        next_state <= '0' when "0000",
                      '1' when "0001",
                      '1' when "0010",
                      '0' when "0011",
                      '0' when "0100",
                      '0' when "0101",
                      '0' when "0110",
                      '1' when "0111",
                      '1' when "1000",
                      '1' when "1001",
                      '1' when "1010",
                      '0' when "1011",
                      '0' when "1100",
                      '1' when "1101",
                      '0' when "1110",
                      '1' when "1111",
                      '1' when others;

    process (clk)
    begin
        if rising_edge(clk) then
            if sel = '0' then
                y <= init;
            else
                y <= next_state;
            end if;
        end if;
    end process;
end architecture rtl;
