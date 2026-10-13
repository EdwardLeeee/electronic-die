-- Self-checking testbench for the electronic die, original timing (VHDL-2008, GHDL).
--   -gDUT=structural|behavioral   electronic_die(rtl) | electronic_die_behavior(behavior)
--   -gSEED=<64 binary digits>     must match the seed used for the vectors
--   -gSTATES=<file> -gDIE=<file>  from model/ca_rng.py vectors
--   -gSTEPS=<n>                   rising edges to check
-- Contract: docs/verification.md, section 2:
--   R(0) = R(1) = 1;  R(k) = die(state(k-2)) if en_k = '1' else R(k-1), k >= 2
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_die_check is
    generic (
        DUT    : string  := "structural";
        SEED   : std_logic_vector(63 downto 0) := std_logic_vector(to_unsigned(122059, 64));
        STATES : string  := "states.txt";
        DIE    : string  := "die.txt";
        STEPS  : integer := 256
    );
end entity;

architecture sim of tb_die_check is
    signal clk            : std_logic := '0';
    signal en             : std_logic := '1';   -- high from time 0: edge 1 must not update
    signal tossing_result : std_logic_vector(2 downto 0);
    signal done           : boolean := false;

    type state_array is array (0 to STEPS) of std_logic_vector(63 downto 0);
    type die_array   is array (0 to STEPS) of std_logic_vector(2 downto 0);

    -- en schedule by edge number: 1..64 high, 65..96 low, 97..128 alternating,
    -- then a 16-bit LFSR (x^16+x^14+x^13+x^11+1), seeded from SEED.
    procedure en_for_edge (e : in integer; lfsr : inout std_logic_vector(15 downto 0); en_v : out std_logic) is
    begin
        if e <= 64 then
            en_v := '1';
        elsif e <= 96 then
            en_v := '0';
        elsif e <= 128 then
            if e mod 2 = 1 then en_v := '1'; else en_v := '0'; end if;
        else
            lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
            en_v := lfsr(0);
        end if;
    end procedure;
begin
    clock : process
    begin
        while not done loop
            wait for 5 ns;
            clk <= not clk;
        end loop;
        wait;
    end process;

    g_dut : if DUT = "structural" generate
        dut : entity work.electronic_die(rtl)
            generic map (SEED => SEED)
            port map (clk => clk, en => en, tossing_result => tossing_result);
    else generate
        dut : entity work.electronic_die_behavior(behavior)
            generic map (SEED => SEED)
            port map (clk => clk, en => en, tossing_result => tossing_result);
    end generate;

    check : process
        alias rng_state is << signal .tb_die_check.g_dut.dut.rng_value : std_logic_vector(63 downto 0) >>;
        file     f      : text;
        variable l      : line;
        variable ok     : boolean;
        variable state_vec : state_array;
        variable dies   : die_array;
        variable r      : std_logic_vector(2 downto 0) := "001";
        variable lfsr   : std_logic_vector(15 downto 0);
        variable errors : natural := 0;
        variable value  : integer;
        variable en_v   : std_logic;
    begin
        file_open(f, STATES, read_mode);
        for k in 0 to STEPS loop
            assert not endfile(f) report STATES & " has fewer than " & integer'image(STEPS + 1) & " lines" severity failure;
            readline(f, l);
            read(l, state_vec(k), ok);
            assert ok report string'("cannot parse ") & STATES & " line " & integer'image(k) severity failure;
        end loop;
        file_close(f);
        file_open(f, DIE, read_mode);
        for k in 0 to STEPS loop
            assert not endfile(f) report DIE & " has fewer than " & integer'image(STEPS + 1) & " lines" severity failure;
            readline(f, l);
            read(l, dies(k), ok);
            assert ok report string'("cannot parse ") & DIE & " line " & integer'image(k) severity failure;
        end loop;
        file_close(f);
        assert state_vec(0) = SEED report "vector seed does not match generic SEED" severity failure;

        lfsr := SEED(15 downto 0) xor x"ACE1";
        if lfsr = x"0000" then lfsr := x"ACE1"; end if;
        en_for_edge(1, lfsr, en_v);
        en <= en_v;

        for k in 1 to STEPS loop
            wait until falling_edge(clk);               -- edge k has happened
            if k >= 2 and en = '1' then r := dies(k - 2); end if;
            value := to_integer(unsigned(tossing_result));
            if tossing_result /= r then
                errors := errors + 1;
                report "FAIL edge " & integer'image(k) & " (en=" & std_logic'image(en) & "): tossing_result=" &
                       integer'image(value) & " expected=" & integer'image(to_integer(unsigned(r))) severity error;
            end if;
            if value < 1 or value > 6 then
                errors := errors + 1;
                report "FAIL edge " & integer'image(k) & ": tossing_result=" & to_string(tossing_result) & " outside 1..6" severity error;
            end if;
            if rng_state /= state_vec(k - 1) then
                errors := errors + 1;
                report "FAIL edge " & integer'image(k) & ": CA state " & to_string(rng_state) &
                       " expected " & to_string(state_vec(k - 1)) severity error;
            end if;
            if errors >= 5 then
                report "too many mismatches" severity error;
                exit;
            end if;
            en_for_edge(k + 1, lfsr, en_v);
            en <= en_v;
        end loop;
        done <= true;
        if errors > 0 then
            report "FAIL: " & integer'image(errors) & " mismatches" severity error;
            finish(1);
        end if;
        report "PASS: electronic_die " & DUT & ", " & integer'image(STEPS) & " edges match the contract";
        finish(0);
    end process;
end architecture;
