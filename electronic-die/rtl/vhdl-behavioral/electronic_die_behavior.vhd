library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rng64_behavior is
    port (
        clk     : in  std_logic;
        sel     : in  std_logic;
        seed    : in  std_logic_vector(63 downto 0);
        rng_out : out std_logic_vector(63 downto 0)
    );
end entity;

architecture behavior of rng64_behavior is
    signal state : std_logic_vector(63 downto 0) := (others => '0');

    function ca_next(s : std_logic_vector(63 downto 0)) return std_logic_vector is
        variable n   : std_logic_vector(63 downto 0);
        variable adr : std_logic_vector(3 downto 0);
        variable im1 : integer;
        variable ip1 : integer;
        variable ip2 : integer;
    begin
        for i in 0 to 63 loop
            if i = 0 then
                im1 := 63;
            else
                im1 := i - 1;
            end if;

            if i = 63 then
                ip1 := 0;
            else
                ip1 := i + 1;
            end if;

            if i >= 62 then
                ip2 := i - 62;
            else
                ip2 := i + 2;
            end if;

            adr := s(i) & s(im1) & s(ip2) & s(ip1);
            case adr is
                when "0000" => n(i) := '0';
                when "0001" => n(i) := '1';
                when "0010" => n(i) := '1';
                when "0011" => n(i) := '0';
                when "0100" => n(i) := '0';
                when "0101" => n(i) := '0';
                when "0110" => n(i) := '0';
                when "0111" => n(i) := '1';
                when "1000" => n(i) := '1';
                when "1001" => n(i) := '1';
                when "1010" => n(i) := '1';
                when "1011" => n(i) := '0';
                when "1100" => n(i) := '0';
                when "1101" => n(i) := '1';
                when "1110" => n(i) := '0';
                when others => n(i) := '1';
            end case;
        end loop;
        return n;
    end function;
begin
    process (clk)
    begin
        if rising_edge(clk) then
            if sel = '0' then
                state <= seed;
            else
                state <= ca_next(state);
            end if;
        end if;
    end process;

    rng_out <= state;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity electronic_die_behavior is
    generic (
        SEED : std_logic_vector(63 downto 0) := std_logic_vector(to_unsigned(122059, 64))
    );
    port (
        clk            : in  std_logic;
        en             : in  std_logic;
        tossing_result : out std_logic_vector(2 downto 0)
    );
end entity;

architecture behavior of electronic_die_behavior is
    signal rng_value  : std_logic_vector(63 downto 0);
    signal result_reg : std_logic_vector(2 downto 0) := "001";
    signal init_done  : std_logic := '0';

    function mod6(value : std_logic_vector(63 downto 0)) return integer is
        variable remainder : integer range 0 to 5 := 0;
        variable next_rem  : integer range 0 to 11 := 0;
    begin
        for i in value'range loop
            next_rem := remainder * 2;
            if value(i) = '1' then
                next_rem := next_rem + 1;
            end if;
            if next_rem >= 6 then
                next_rem := next_rem - 6;
            end if;
            remainder := next_rem;
        end loop;
        return remainder;
    end function;
begin
    rng_inst : entity work.rng64_behavior(behavior)
        port map (
            clk     => clk,
            sel     => init_done,
            seed    => SEED,
            rng_out => rng_value
        );

    process (clk)
    begin
        if rising_edge(clk) then
            if init_done = '0' then
                init_done <= '1';
            elsif en = '1' then
                result_reg <= std_logic_vector(to_unsigned(mod6(rng_value) + 1, 3));
            end if;
        end if;
    end process;

    tossing_result <= result_reg;
end architecture;
