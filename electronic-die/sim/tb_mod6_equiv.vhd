-- Equivalence of mod6_residue (VHDL) with numeric_std's mod operator.
--   -gWIDTH=<w> -gSTAGES=<s> [-gN=<random values>]
-- WIDTH <= 20: every input value, in a scrambled order (a bijection, so bit 0 is
-- not periodic and a pipeline-latency error cannot hide).  Otherwise directed corner cases (single bits
-- set or cleared, runs of ones, 0, all ones, 0101..., 1010..., 110110..., the
-- largest multiples of 6) followed by N random values built from as many
-- xorshift64 words as WIDTH needs.  One input per clock; rem6 is compared as a
-- vector STAGES clocks later, so U or X outputs fail.
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

    -- Bijection on WIDTH-bit values: odd multiply, xorshift, odd multiply.
    function scramble (i : natural) return unsigned is
        variable y : unsigned(WIDTH - 1 downto 0);
    begin
        y := resize(to_unsigned(i, WIDTH) * resize(unsigned'(x"9E3779B97F4A7C15"), WIDTH), WIDTH);
        y := y xor shift_right(y, WIDTH / 2);
        return resize(y * resize(unsigned'(x"BF58476D1CE4E5B9"), WIDTH), WIDTH);
    end function;
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
        constant DIRECTED   : natural := 4 * WIDTH + 7;
        type hist_array is array (0 to STAGES) of unsigned(WIDTH - 1 downto 0);
        variable hist   : hist_array := (others => (others => '0'));
        variable v      : unsigned(WIDTH - 1 downto 0);
        variable rng    : unsigned(63 downto 0) := x"9E3779B97F4A7C15";
        variable want   : natural;
        variable patt   : unsigned(WIDTH - 1 downto 0);
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
                v := scramble(idx);
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
            elsif idx <= 4 * WIDTH + 6 then
                for b in 0 to WIDTH - 1 loop       -- 0101..., 1010..., 110110...
                    if idx = 4 * WIDTH + 4 then
                        patt(b) := '1' when b mod 2 = 0 else '0';
                    elsif idx = 4 * WIDTH + 5 then
                        patt(b) := '1' when b mod 2 = 1 else '0';
                    else
                        patt(b) := '0' when b mod 3 = 0 else '1';
                    end if;
                end loop;
                v := patt;
            else
                for w in 0 to (WIDTH - 1) / 64 loop
                    rng := rng xor shift_left(rng, 13);
                    rng := rng xor shift_right(rng, 7);
                    rng := rng xor shift_left(rng, 17);
                    for b in 0 to 63 loop
                        if 64 * w + b < WIDTH then
                            v(64 * w + b) := rng(b);
                        end if;
                    end loop;
                end loop;
            end if;
            x <= std_logic_vector(v);
            for k in STAGES downto 1 loop
                hist(k) := hist(k - 1);
            end loop;
            hist(0) := v;
            wait for 1 ns;
            if idx >= STAGES then
                want := to_integer(hist(STAGES) mod 6);
                if rem6 /= std_logic_vector(to_unsigned(want, 3)) then
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
