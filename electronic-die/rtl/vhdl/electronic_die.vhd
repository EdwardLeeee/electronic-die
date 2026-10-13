library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity electronic_die is
    generic (
        SEED : std_logic_vector(63 downto 0) := std_logic_vector(to_unsigned(122059, 64))
    );
    port (
        clk            : in  std_logic;
        en             : in  std_logic;
        tossing_result : out std_logic_vector(2 downto 0)
    );
end entity electronic_die;

architecture rtl of electronic_die is
    signal init_done  : std_logic := '0';
    signal rng_value  : std_logic_vector(63 downto 0);
    signal mod_value  : std_logic_vector(2 downto 0);
    signal result_reg : std_logic_vector(2 downto 0) := "001";
begin
    rng_inst : entity work.rng64(structure)
        port map (
            seed    => SEED,
            clk     => clk,
            sel     => init_done,
            rng_out => rng_value
        );

    modulo_inst : entity work.modulo_by_6(rtl)
        port map (
            rng_value => rng_value,
            die_value => mod_value
        );

    -- The first rising edge loads the seed into the RNG.
    -- Later, the RNG keeps running; en controls only the output register.
    process (clk)
    begin
        if rising_edge(clk) then
            if init_done = '0' then
                init_done <= '1';
            elsif en = '1' then
                result_reg <= mod_value;
            end if;
        end if;
    end process;

    tossing_result <= result_reg;
end architecture rtl;
