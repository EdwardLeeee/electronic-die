-- Self-checking testbench for the 64-cell CA RNG (VHDL-2008, GHDL).
--   -gDUT=structural  : rng64(structure)        electronic-die/rtl/vhdl
--   -gDUT=behavioral  : rng64_behavior(behavior) electronic-die/rtl/vhdl-behavioral
--   -gSTATES=<file>   : expected states from model/ca_rng.py vectors (line 0 = seed)
--   -gSTEPS=<n>       : CA steps to check
-- Contract: docs/verification.md, section 1.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_rng64_check is
    generic (
        DUT    : string  := "structural";
        STATES : string  := "states.txt";
        STEPS  : integer := 256
    );
end entity;

architecture sim of tb_rng64_check is
    signal clk     : std_logic := '0';
    signal sel     : std_logic := '0';
    signal seed    : std_logic_vector(63 downto 0) := (others => '0');
    signal rng_out : std_logic_vector(63 downto 0);
    signal done    : boolean := false;
begin
    clock : process
    begin
        while not done loop
            wait for 5 ns;
            clk <= not clk;          -- rising edges at 5, 15, 25, ... ns
        end loop;
        wait;
    end process;

    g_dut : if DUT = "structural" generate
        dut : entity work.rng64(structure)
            port map (seed => seed, clk => clk, sel => sel, rng_out => rng_out);
    else generate
        dut : entity work.rng64_behavior(behavior)
            port map (clk => clk, sel => sel, seed => seed, rng_out => rng_out);
    end generate;

    check : process
        file     f        : text;
        variable l        : line;
        variable expected : std_logic_vector(63 downto 0);
        variable ok       : boolean;
        variable errors   : natural := 0;
    begin
        file_open(f, STATES, read_mode);
        readline(f, l);
        read(l, expected, ok);
        assert ok report "cannot parse line 0 of " & STATES severity failure;
        seed <= expected;

        -- Edge 1 samples sel = '0' and loads the seed; later edges advance.
        for k in 1 to STEPS + 1 loop
            if k >= 2 then
                assert not endfile(f) report STATES & " has fewer than " & integer'image(STEPS + 1) & " lines" severity failure;
                readline(f, l);
                read(l, expected, ok);
                assert ok report "cannot parse line " & integer'image(k - 1) severity failure;
            end if;
            wait until falling_edge(clk);
            if rng_out /= expected then
                errors := errors + 1;
                report "FAIL edge " & integer'image(k) & ": rng_out=" & to_string(rng_out) &
                       " expected=" & to_string(expected) severity error;
                if errors >= 5 then
                    report "too many mismatches" severity error;
                    exit;
                end if;
            end if;
            sel <= '1';
        end loop;
        file_close(f);
        done <= true;
        if errors > 0 then
            report "FAIL: " & integer'image(errors) & " mismatches" severity error;
            finish(1);
        end if;
        report "PASS: rng64 " & DUT & ", " & integer'image(STEPS) & " steps match the model";
        finish(0);
    end process;
end architecture;
