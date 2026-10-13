-- Electronic die with a replaceable, optionally pipelined mod-6 stage.
-- VHDL-93 counterpart of electronic-die/rtl/verilog/electronic_die_fast.v
-- (CORE 0 and 2; the popcount core exists in Verilog only).
-- Contract: docs/verification.md, section 4.
--   CORE = 0: original mod operator (modulo_by_6) plus STAGES output registers
--   CORE = 2: mod6_residue with STAGES pipeline registers
-- en only gates the commit of the pipeline output into result_reg.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity electronic_die_fast is
    generic (
        SEED   : std_logic_vector(63 downto 0) := std_logic_vector(to_unsigned(122059, 64));
        CORE   : natural := 2;
        STAGES : natural := 2
    );
    port (
        clk            : in  std_logic;
        en             : in  std_logic;
        tossing_result : out std_logic_vector(2 downto 0)
    );
end entity;

architecture rtl of electronic_die_fast is
    signal init_done  : std_logic := '0';
    signal rng_value  : std_logic_vector(63 downto 0);
    signal die_value  : std_logic_vector(2 downto 0);
    signal result_reg : std_logic_vector(2 downto 0) := "001";
    type valid_array is array (0 to STAGES) of std_logic;
    signal valid      : valid_array := (others => '0');
begin
    assert CORE = 0 or CORE = 2
        report "electronic_die_fast (VHDL): CORE must be 0 or 2" severity failure;

    rng_inst : entity work.rng64(structure)
        port map (seed => SEED, clk => clk, sel => init_done, rng_out => rng_value);

    g_percent : if CORE = 0 generate
        type die_array is array (0 to STAGES) of std_logic_vector(2 downto 0);
        signal d : die_array := (others => "001");
    begin
        modulo_inst : entity work.modulo_by_6(rtl)
            port map (rng_value => rng_value, die_value => d(0));
        g_delay : for s in 1 to STAGES generate
            process (clk)
            begin
                if rising_edge(clk) then
                    d(s) <= d(s - 1);
                end if;
            end process;
        end generate;
        die_value <= d(STAGES);
    end generate;

    g_residue : if CORE /= 0 generate
        signal rem6 : std_logic_vector(2 downto 0);
    begin
        mod_inst : entity work.mod6_residue(rtl)
            generic map (WIDTH => 64, STAGES => STAGES)
            port map (clk => clk, x => rng_value, rem6 => rem6);
        die_value <= std_logic_vector(unsigned(rem6) + 1);
    end generate;

    valid(0) <= init_done;
    g_valid : for s in 1 to STAGES generate
        process (clk)
        begin
            if rising_edge(clk) then
                valid(s) <= valid(s - 1);
            end if;
        end process;
    end generate;

    process (clk)
    begin
        if rising_edge(clk) then
            if init_done = '0' then
                init_done <= '1';
            end if;
            if en = '1' and valid(STAGES) = '1' then
                result_reg <= die_value;
            end if;
        end if;
    end process;

    tossing_result <= result_reg;
end architecture;
