-- Equivalence of mod6_residue (VHDL) with numeric_std's mod operator.
--   -gWIDTH=<w> -gSTAGES=<s> [-gN=<random values>]
-- WIDTH <= 20: every input value.  Otherwise directed corner cases followed by
-- N xorshift64 values.  One input per clock; rem6 is checked STAGES clocks later.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_mod6_equiv is
    generic (
        WIDTH  : positive := 64;
        STAGES : natural  := 0;
        N      : natural  := 20000
    );
end entity;

architecture sim of tb_mod6_equiv is
    signal clk  : std_logic := '0';
    signal x    : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal rem6 : std_logic_vector(2 downto 0);
    signal done : boolean := false;
begin
    clock : process
    begin
        while not done loop
            wait for 5 ns;
            clk <= not clk;
        end loop;
        wait;
    end process;

    dut : entity work.mod6_residue(rtl)
        generic map (WIDTH => WIDTH, STAGES => STAGES)
        port map (clk => clk, x => x, rem6 => rem6);

    check : process
        constant EXHAUSTIVE : boolean := WIDTH <= 20;
        constant DIRECTED   : natural := 4 * WIDTH + 4;
        type hist_array is array (0 to STAGES) of unsigned(WIDTH - 1 downto 0);
        variable hist   : hist_array := (others => (others => '0'));
        variable v      : unsigned(WIDTH - 1 downto 0);
        variable rng    : unsigned(63 downto 0) := x"9E3779B97F4A7C15";
        variable want   : natural;
        variable total  : natural;
        variable errors : natural := 0;
        constant ONES   : unsigned(WIDTH - 1 downto 0) := (others => '1');
        constant ONE    : unsigned(WIDTH - 1 downto 0) := to_unsigned(1, WIDTH);
    begin
        if EXHAUSTIVE then total := 2 ** WIDTH; else total := DIRECTED + N; end if;
        for idx in 0 to total + STAGES - 1 loop
            wait until falling_edge(clk);
            if idx >= total then
                v := (others => '0');
            elsif EXHAUSTIVE then
                v := to_unsigned(idx, WIDTH);
            elsif idx < WIDTH then
                v := shift_left(ONE, idx);
            elsif idx < 2 * WIDTH then
                v := not shift_left(ONE, idx - WIDTH);
            elsif idx < 3 * WIDTH then
                v := shift_right(ONES, idx - 2 * WIDTH);
            elsif idx < 4 * WIDTH then
                v := shift_left(ONES, idx - 3 * WIDTH);
            elsif idx = 4 * WIDTH then
                v := (others => '0');
            elsif idx = 4 * WIDTH + 1 then
                v := ONES;
            elsif idx = 4 * WIDTH + 2 then
                v := ONES - (ONES mod 6);
            elsif idx = 4 * WIDTH + 3 then
                v := ONES - (ONES mod 6) - 1;
            else
                rng := rng xor shift_left(rng, 13);
                rng := rng xor shift_right(rng, 7);
                rng := rng xor shift_left(rng, 17);
                v := resize(rng, WIDTH);
            end if;
            x <= std_logic_vector(v);
            for k in STAGES downto 1 loop
                hist(k) := hist(k - 1);
            end loop;
            hist(0) := v;
            wait for 1 ns;
            if idx >= STAGES then
                want := to_integer(hist(STAGES) mod 6);
                if to_integer(unsigned(rem6)) /= want then
                    errors := errors + 1;
                    if errors <= 5 then
                        report "FAIL: x=" & to_hstring(hist(STAGES)) & " rem6=" & to_string(rem6) &
                               " expected " & integer'image(want) severity error;
                    end if;
                end if;
            end if;
        end loop;
        done <= true;
        if errors > 0 then
            report "FAIL: " & integer'image(errors) & " of " & integer'image(total) & " values wrong" severity error;
            finish(1);
        end if;
        if EXHAUSTIVE then
            report "PASS: mod6_residue (VHDL) WIDTH=" & integer'image(WIDTH) & " STAGES=" & integer'image(STAGES) &
                   ": " & integer'image(total) & " values (every input) equal x mod 6";
        else
            report "PASS: mod6_residue (VHDL) WIDTH=" & integer'image(WIDTH) & " STAGES=" & integer'image(STAGES) &
                   ": " & integer'image(total) & " values (directed + random) equal x mod 6";
        end if;
        finish(0);
    end process;
end architecture;
