-- x mod 6 for an unsigned WIDTH-bit x, as a balanced tree of mod-3 adders.
-- VHDL-93 counterpart of electronic-die/rtl/verilog/mod6_residue.v (Quartus II 9.0 reads VHDL-93).
--
--   x = 2*h + b0 with h = x >> 1      =>   x mod 6 = b0 + 2*(h mod 3)
--   h = sum_i d_i * 4^i, 4 = 1 (mod 3) =>   h mod 3 = (sum_i d_i) mod 3
--
-- STAGES pipeline registers (0 .. LOG) sit at evenly spaced tree depths, so
-- rem6 is x mod 6 for the x presented STAGES clocks earlier.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mod6_residue is
    generic (
        WIDTH  : positive := 64;
        STAGES : natural  := 0
    );
    port (
        clk : in  std_logic;
        x   : in  std_logic_vector(WIDTH - 1 downto 0);
        rem6 : out std_logic_vector(2 downto 0)
    );
end entity;

architecture rtl of mod6_residue is
    function clog2 (n : positive) return natural is
        variable r : natural := 0;
        variable v : natural := n - 1;
    begin
        while v > 0 loop
            r := r + 1;
            v := v / 2;
        end loop;
        return r;
    end function;

    constant DIGITS : positive := WIDTH / 2;
    constant LOG    : natural  := clog2(DIGITS);
    constant LEAVES : positive := 2 ** LOG;

    -- true when a register follows the nodes at depth d (1 = fed by digits, LOG = root)
    function is_cut (d : natural) return boolean is
    begin
        for k in 1 to STAGES loop
            if d = (k * LOG + STAGES) / (STAGES + 1) then
                return true;
            end if;
        end loop;
        return false;
    end function;

    -- (a + b) mod 3 for a, b in 0..3, written as the 16-entry table it becomes
    -- in hardware (one 4-input lookup per output bit).
    function mod3add (a, b : unsigned(1 downto 0)) return unsigned is
        variable ab : std_logic_vector(3 downto 0);
    begin
        ab := std_logic_vector(a & b);
        case ab is
            when "0000" => return "00";
            when "0001" => return "01";
            when "0010" => return "10";
            when "0011" => return "00";
            when "0100" => return "01";
            when "0101" => return "10";
            when "0110" => return "00";
            when "0111" => return "01";
            when "1000" => return "10";
            when "1001" => return "00";
            when "1010" => return "01";
            when "1011" => return "10";
            when "1100" => return "00";
            when "1101" => return "01";
            when "1110" => return "10";
            when "1111" => return "00";
            when others => return "XX";     -- metavalues in simulation only
        end case;
    end function;

    type node_array is array (1 to 2 * LEAVES - 1) of unsigned(1 downto 0);
    signal node : node_array;
    signal h    : unsigned(2 * LEAVES - 1 downto 0);
    type bit_array is array (0 to STAGES) of std_logic;
    signal b0   : bit_array;
begin
    assert WIDTH >= 4 and STAGES <= LOG
        report "mod6_residue: need WIDTH >= 4 and STAGES <= " & integer'image(LOG) severity failure;

    h <= resize(unsigned(x(WIDTH - 1 downto 1)), 2 * LEAVES);

    g_digit : for i in 0 to LEAVES - 1 generate
        node(LEAVES + i) <= h(2 * i + 1 downto 2 * i);
    end generate;

    g_level : for l in 0 to LOG - 1 generate
        g_node : for i in natural range 0 to 2 ** l - 1 generate
            constant J : positive := 2 ** l + i;
            signal sum : unsigned(1 downto 0);
        begin
            sum <= mod3add(node(2 * J), node(2 * J + 1));
            g_reg : if is_cut(LOG - l) generate
                process (clk)
                begin
                    if rising_edge(clk) then
                        node(J) <= sum;
                    end if;
                end process;
            end generate;
            g_comb : if not is_cut(LOG - l) generate
                node(J) <= sum;
            end generate;
        end generate;
    end generate;

    b0(0) <= x(0);
    g_b0 : for s in 1 to STAGES generate
        process (clk)
        begin
            if rising_edge(clk) then
                b0(s) <= b0(s - 1);
            end if;
        end process;
    end generate;

    rem6 <= std_logic_vector(node(1)) & b0(STAGES);
end architecture;
