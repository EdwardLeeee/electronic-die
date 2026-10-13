library ieee;
use ieee.std_logic_1164.all;

entity rng64 is
    port (
        seed    : in  std_logic_vector(63 downto 0);
        clk     : in  std_logic;
        sel     : in  std_logic;
        rng_out : out std_logic_vector(63 downto 0)
    );
end entity rng64;

architecture structure of rng64 is
    type ca_input_array is array (63 downto 0) of std_logic_vector(3 downto 0);-- 64 entity , each 4bit
    signal ca_input  : ca_input_array;
    signal ca_output : std_logic_vector(63 downto 0);
begin
    -- Periodic 1D CA: d1=0, d2=-1, d3=+2, d4=+1.
    process (ca_output)
        variable j : integer;
        variable k : integer;
        variable l : integer;
    begin
        for i in 63 downto 0 loop
            j := i - 1;-- definite on professor's ppt (d2)
            if j < 0 then -- 0 -1 =>63
                j := 63;
            end if;

            k := i + 2;-- definite on professor's ppt (d3)
            if k > 63 then
                k := k - 64;--go back to left
            end if;

            l := i + 1;-- definite on professor's ppt (d4)
            if l > 63 then
                l := l - 64;-- go back to left
            end if;

            ca_input(i) <= ca_output(i) & ca_output(j) & ca_output(k) & ca_output(l);
        end loop;
    end process;
  -- build 64 ca_cells
    ca_generate : for n in 63 downto 0 generate
        ca_array : entity work.ca_cell(rtl)
            port map (
                adr  => ca_input(n),
                clk  => clk,
                sel  => sel,
                init => seed(n),
                y    => ca_output(n)
            );
    end generate ca_generate;

    rng_out <= ca_output;
end architecture structure;
