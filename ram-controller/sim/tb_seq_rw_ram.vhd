-- Self-checking testbench for the HW3 RAM controller seq_rw_ram (VHDL-2008, GHDL --std=08).
-- Contract: docs/verification.md, section 3, re-derived from ram-controller/rtl/seq_rw_ram.vhd.
--
-- Clock: 10 ns, first rising edge at 5 ns. Every stimulus change and every check happens on a
-- falling edge, so the bench never races the DUT at a rising edge. A command is normally pulsed for
-- exactly one clock: driven at a falling edge, sampled by the FSM at the next rising edge (called e0
-- of the burst) and released at the falling edge after e0.
--
-- Timing of the RTL, with e0 the rising edge that samples the command while the FSM is idle:
--   write burst  between e(k) and e(k+1), k = 0..7, the FSM is in S_W(k+1): W_En = 1, W_Addr = k,
--                R_Addr = 000; at e(k+1) mem[k] <= Data_Input. Idle again after e8.
--   read burst   between e(k) and e(k+1) the FSM is in S_R(k+1): R_Addr = k, W_En = 0;
--                at e(k+1) Data_Output <= mem[k], so mem[k] is visible between e(k+1) and e(k+2).
--   idle         R_Addr = 000, so Data_Output reloads mem[0] at every idle edge, e0 included.
--   RAM          synchronous write and synchronous read; reading the address written at the same
--                edge returns the old contents (so after e1 of a write burst Data_Output still
--                holds the old mem[0], after e2 the new one).
--   commands     Read, Write and ID are looked at only in S_IDLE, by level: a command that is still
--                asserted at e9 (the first idle edge after e8) starts the next burst there, and a
--                command asserted while a burst is running is neither honoured nor remembered.
-- Note on contract check 4: "Data_Output shows mem[0] only after e1, not after e0" cannot be
-- observed, because the idle reload already presents mem[0] after e0. The observable latency
-- statement is: after e1 Data_Output is still mem[0] (not mem[1]); mem[1] appears after e2.
--
-- Input conventions: while idle the bench keeps ID = ID_CODE with Read = Write = 0 (the code alone
-- must not start anything); inside a burst without a command it drives a wrong ID (the FSM must not
-- look at ID there); a command is always driven together with ID = ID_CODE. Data_Input carries
-- poison bytes whenever no write may happen; they must never be read back.
--
-- Every mismatch is reported with severity error (the run continues) and counted. The run ends
-- with "PASS: <n> checks" and finish(0), or "FAIL: <m> of <n> checks" and finish(1).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_seq_rw_ram is
end entity;

architecture sim of tb_seq_rw_ram is
    -- The DUT is instantiated with its default generic, so this bench also pins the default code.
    constant ID_CODE : std_logic_vector(16 downto 0) := std_logic_vector(to_unsigned(22059, 17));

    type byte_array is array (0 to 7) of std_logic_vector(7 downto 0);
    type set_table  is array (natural range <>) of byte_array;
    constant ZEROS : byte_array := (others => (others => '0'));
    -- Data sets: all bytes non-zero, distinct, and disjoint between sets, so a wrong address,
    -- a stale entry or a one-clock shift always shows up as a different byte.
    constant SET_A : byte_array := (x"3C", x"A5", x"5A", x"C3", x"0F", x"F0", x"69", x"96");
    constant SET_B : byte_array := (x"01", x"02", x"04", x"08", x"10", x"20", x"40", x"80");
    constant SET_C : byte_array := (x"D1", x"E2", x"33", x"44", x"55", x"66", x"77", x"8F");
    constant SET_D : byte_array := (x"1F", x"2E", x"3D", x"4C", x"5B", x"6A", x"79", x"88");
    constant SETS  : set_table(0 to 3) := (SET_A, SET_B, SET_C, SET_D);
    -- Values on Data_Input while no write may happen; they must never be read back.
    constant POISON_CMD  : std_logic_vector(7 downto 0) := x"EE";  -- present at e0 of a write burst
    constant POISON_IDLE : std_logic_vector(7 downto 0) := x"DD";  -- present after e8 and while idle

    signal clk         : std_logic := '0';
    signal Read        : std_logic := '0';
    signal Write       : std_logic := '0';
    signal ID          : std_logic_vector(16 downto 0) := ID_CODE;
    signal Data_Input  : std_logic_vector(7 downto 0)  := POISON_IDLE;
    signal Data_Output : std_logic_vector(7 downto 0);
    signal done        : boolean := false;

    function addr (k : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(k, 3));
    end function;

    function img (k : integer) return string is
    begin
        return integer'image(k);
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

    dut : entity work.seq_rw_ram
        port map (clk => clk, Read => Read, Write => Write, ID => ID,
                  Data_Input => Data_Input, Data_Output => Data_Output);

    check_proc : process
        -- Controller outputs, observed through VHDL-2008 external names (instance label dut).
        alias w_en   is << signal .tb_seq_rw_ram.dut.W_En   : std_logic >>;
        alias w_addr is << signal .tb_seq_rw_ram.dut.W_Addr : std_logic_vector(2 downto 0) >>;
        alias r_addr is << signal .tb_seq_rw_ram.dut.R_Addr : std_logic_vector(2 downto 0) >>;

        variable cycle    : natural := 0;      -- rising edges seen so far
        variable n_checks : natural := 0;
        variable n_fail   : natural := 0;
        variable shadow   : byte_array := ZEROS;  -- expected RAM contents (RTL initialises mem to 0)

        -- Advance to the next falling edge; one rising edge has happened in between.
        procedure tick is
        begin
            wait until falling_edge(clk);
            cycle := cycle + 1;
        end procedure;

        procedure check (what : string; actual, expected : std_logic_vector) is
        begin
            n_checks := n_checks + 1;
            if actual /= expected then
                n_fail := n_fail + 1;
                report "FAIL cycle " & img(cycle) & " @" & img(now / 1 ns) & " ns " & what &
                       ": expected " & to_string(expected) & " got " & to_string(actual)
                    severity error;
            end if;
        end procedure;

        procedure check (what : string; actual, expected : std_logic) is
        begin
            n_checks := n_checks + 1;
            if actual /= expected then
                n_fail := n_fail + 1;
                report "FAIL cycle " & img(cycle) & " @" & img(now / 1 ns) & " ns " & what &
                       ": expected " & std_logic'image(expected) & " got " & std_logic'image(actual)
                    severity error;
            end if;
        end procedure;

        -- Command inputs for the next rising edge (see the input conventions in the header).
        procedure drive (r, w : boolean; in_burst : boolean) is
        begin
            Read  <= '1' when r else '0';
            Write <= '1' when w else '0';
            ID    <= ID_CODE when (r or w or not in_burst) else not ID_CODE;
        end procedure;

        -- n idle clocks. Precondition: the FSM is idle, so every edge reloads mem[0].
        procedure idle (tag : string; n : positive) is
        begin
            for i in 1 to n loop
                tick;
                check(tag & " idle clock " & img(i) & " W_En",   w_en,   '0');
                check(tag & " idle clock " & img(i) & " W_Addr", w_addr, "000");
                check(tag & " idle clock " & img(i) & " R_Addr", r_addr, "000");
                check(tag & " idle clock " & img(i) & " Data_Output (idle reload of mem[0])",
                      Data_Output, shadow(0));
            end loop;
        end procedure;

        -- Write burst: command pulse at e0, then data(k) driven after e(k) so it is sampled at e(k+1).
        --   also_read            Read asserted together with Write at e0 (contract check 3).
        --   read_at / write_at   k in 0..7 pulses Read / Write (with the right ID) for the single
        --                        clock sampled at e(k+1), while the FSM is in S_W(k+1); the FSM must
        --                        ignore it and not remember it.
        --   hold_read / hold_write  Read / Write (with the right ID) asserted on every clock after e0
        --                        and left asserted on return, so the FSM samples it at e9 and the
        --                        caller's next burst starts there (level-sensitive sampling).
        procedure write_burst (tag : string; data : byte_array; also_read : boolean := false;
                               read_at, write_at : integer := -1;
                               hold_read, hold_write : boolean := false) is
        begin
            check(tag & " W_En before the command", w_en, '0');
            drive(also_read, true, false);
            Data_Input <= POISON_CMD;
            tick;                                   -- e0: command sampled in S_IDLE
            for k in 0 to 7 loop                    -- after e(k): FSM in S_W(k+1)
                check(tag & " W_En after e" & img(k),   w_en,   '1');
                check(tag & " W_Addr after e" & img(k), w_addr, addr(k));
                check(tag & " R_Addr after e" & img(k), r_addr, "000");
                if k <= 1 then
                    -- e0: idle reload of mem[0]; e1: mem[0] is being written at this edge and the
                    -- synchronous read still returns the old contents (write-side latency).
                    check(tag & " Data_Output after e" & img(k) & " (old mem[0])", Data_Output, shadow(0));
                else
                    check(tag & " Data_Output after e" & img(k) & " (new mem[0])", Data_Output, data(0));
                end if;
                Data_Input <= data(k);              -- sampled at e(k+1)
                drive(hold_read or k = read_at, hold_write or k = write_at, true);
                tick;                               -- e(k+1): mem[k] <= data(k)
            end loop;
            shadow     := data;
            Data_Input <= POISON_IDLE;
            drive(hold_read, hold_write, false);    -- idle: pulses released, held commands kept
            check(tag & " W_En after e8",   w_en,   '0');
            check(tag & " W_Addr after e8", w_addr, "000");
            check(tag & " R_Addr after e8", r_addr, "000");
            check(tag & " Data_Output after e8 (new mem[0])", Data_Output, data(0));
        end procedure;

        -- Read burst: command pulse at e0; Data_Output after e(k+1) must equal expected(k).
        -- read_at / write_at / hold_read / hold_write as in write_burst (FSM in S_R(k+1) at e(k+1)).
        procedure read_burst (tag : string; expected : byte_array;
                              read_at, write_at : integer := -1;
                              hold_read, hold_write : boolean := false) is
        begin
            drive(true, false, false);
            tick;                                   -- e0
            check(tag & " R_Addr after e0", r_addr, "000");
            check(tag & " W_En after e0",   w_en,   '0');
            check(tag & " Data_Output after e0 (idle reload of mem[0] at e0)", Data_Output, expected(0));
            for k in 0 to 7 loop
                drive(hold_read or k = read_at, hold_write or k = write_at, true);
                tick;                               -- e(k+1): Data_Output <= mem[k]
                check(tag & " Data_Output after e" & img(k + 1) & " = mem[" & img(k) & "]",
                      Data_Output, expected(k));
                check(tag & " W_En after e" & img(k + 1),   w_en,   '0');
                check(tag & " W_Addr after e" & img(k + 1), w_addr, "000");
                if k < 7 then
                    check(tag & " R_Addr after e" & img(k + 1), r_addr, addr(k + 1));
                else
                    check(tag & " R_Addr after e8 (idle)", r_addr, "000");
                end if;
            end loop;
            drive(hold_read, hold_write, false);    -- idle: pulses released, held commands kept
        end procedure;

        -- Hold a command for n clocks with a wrong ID: the FSM must stay idle on every clock.
        -- The wrong ID flips one bit of ID_CODE per clock (bit first_bit, then step by step), so a
        -- call with n = 17 covers every one of the 17 bits for that command.
        procedure wrong_id (tag : string; use_write : boolean; n : positive; first_bit : natural; step : integer;
                            also_read : boolean := false) is
            variable bad : std_logic_vector(16 downto 0);
            variable b   : integer;
        begin
            for i in 0 to n - 1 loop
                b      := (first_bit + i * step) mod 17;
                bad    := ID_CODE;
                bad(b) := not bad(b);
                drive(not use_write or also_read, use_write, false);
                ID         <= bad;
                Data_Input <= std_logic_vector(to_unsigned(16#B0# + i, 8));
                tick;
                check(tag & " clock " & img(i + 1) & " (bit " & img(b) & " flipped) W_En",   w_en,   '0');
                check(tag & " clock " & img(i + 1) & " (bit " & img(b) & " flipped) W_Addr", w_addr, "000");
                check(tag & " clock " & img(i + 1) & " (bit " & img(b) & " flipped) R_Addr", r_addr, "000");
                check(tag & " clock " & img(i + 1) & " Data_Output (idle reload of mem[0])",
                      Data_Output, shadow(0));
            end loop;
            drive(false, false, false);
            Data_Input <= POISON_IDLE;
        end procedure;
        procedure wrong_id_far (tag : string; use_write : boolean) is
            type id_table is array (0 to 3) of std_logic_vector(16 downto 0);
            constant FAR : id_table := ((others => '0'), (others => '1'), not ID_CODE,
                                        ID_CODE(15 downto 0) & ID_CODE(16));
        begin
            for i in FAR'range loop
                drive(not use_write, use_write, false);
                ID         <= FAR(i);
                Data_Input <= std_logic_vector(to_unsigned(16#C0# + i, 8));
                tick;
                check(tag & " pattern " & img(i) & " W_En",   w_en,   '0');
                check(tag & " pattern " & img(i) & " W_Addr", w_addr, "000");
                check(tag & " pattern " & img(i) & " R_Addr", r_addr, "000");
                check(tag & " pattern " & img(i) & " Data_Output (idle reload of mem[0])",
                      Data_Output, shadow(0));
            end loop;
            drive(false, false, false);
            Data_Input <= POISON_IDLE;
        end procedure;
    begin
        -- Power-up: idle, RAM contents are zero (RTL initial value).
        idle("power-up", 3);
        read_burst("power-up read (all zero)", ZEROS);
        idle("after power-up read", 2);

        -- Check 1: write eight distinct bytes, read them back, W_En exactly during the 8 write clocks.
        write_burst("check1 write A", SET_A);
        idle("check1 after write", 3);
        read_burst("check1 read A", SET_A);
        idle("check1 after read", 2);

        -- Check 2: a wrong ID keeps the FSM idle, for Write and separately for Read; 17 clocks each,
        -- flipping a different bit of ID_CODE on every clock; a later valid read still returns A.
        wrong_id("check2 wrong-ID Write", true,  17, 0,  1);   -- bits 0..16
        idle("check2 after wrong-ID Write", 2);
        wrong_id("check2 wrong-ID Read",  false, 17, 16, -1);  -- bits 16..0
        idle("check2 after wrong-ID Read", 2);
        read_burst("check2 valid read after wrong IDs (old data A)", SET_A);
        idle("check2 after read", 2);
        -- Check 2, continued: Read and Write together with a wrong ID (step 3 visits all 17 bits),
        -- and wrong IDs that differ from the code in many bits.
        wrong_id("check2 wrong-ID Read+Write together", true, 17, 5, 3, also_read => true);
        idle("check2 after wrong-ID Read+Write", 2);
        wrong_id_far("check2 far wrong-ID Write", true);
        wrong_id_far("check2 far wrong-ID Read", false);
        idle("check2 after far wrong IDs", 2);
        -- Check 2, continued: after a wrong-ID clock the FSM is still in S_IDLE, not merely quiet:
        -- a valid command on the very next clock (command line kept high while the ID changes
        -- from wrong to right) starts its burst at that clock, with no idle gap in between.
        wrong_id("check2 single wrong-ID Read clock", false, 1, 3, 1);
        read_burst("check2 valid read right after a wrong-ID clock (old data A)", SET_A);
        idle("check2 after immediate read", 2);
        wrong_id("check2 single wrong-ID Write clock", true, 1, 9, 1);
        write_burst("check2 valid write D right after a wrong-ID clock", SET_D);
        idle("check2 after immediate write", 2);
        read_burst("check2 read D", SET_D);
        idle("check2 after read D", 2);

        -- Check 3: Read and Write both high with the right ID: a write burst, no read burst
        -- (R_Addr = 000 during the burst and for 10 idle clocks after it), new data readable.
        write_burst("check3 Read+Write together, write B", SET_B, also_read => true);
        idle("check3 no read burst follows", 10);
        read_burst("check3 read B", SET_B);
        idle("check3 after read", 2);

        -- Check 4: read latency. Back-to-back read bursts of set C: before e0 of the second burst
        -- Data_Output still holds mem[7]; after e0 it is mem[0] (idle reload, see header); after
        -- e1 it is still mem[0] and not mem[1] (read_burst's "after e1 = mem[0]" check); mem[1]
        -- appears only after e2. The write-side form is checked inside every write burst.
        write_burst("check4 write C", SET_C);
        idle("check4 after write", 2);
        read_burst("check4 first read C", SET_C);
        check("check4 Data_Output before e0 of the second read (mem[7] of the first)", Data_Output, SET_C(7));
        read_burst("check4 second read C back to back (e0 = e9 of the first)", SET_C);
        idle("check4 after second read", 2);

        -- Extra: a command pulsed while a burst is running is ignored and not remembered. Each of
        -- S_W1..S_W8 and S_R1..S_R8 sees a Write pulse and a Read pulse once (sampled at e(k+1));
        -- the burst checks prove it was ignored, the idle clocks after e8 prove no burst follows.
        for k in 0 to 7 loop
            write_burst("extra Write pulse at e" & img(k + 1) & " of a write burst", SETS(k mod 4), write_at => k);
            idle("extra after Write pulse at e" & img(k + 1) & " of a write burst", 10);
        end loop;
        for k in 0 to 7 loop
            write_burst("extra Read pulse at e" & img(k + 1) & " of a write burst", SETS(k mod 4), read_at => k);
            idle("extra after Read pulse at e" & img(k + 1) & " of a write burst", 10);
        end loop;
        for k in 0 to 7 loop
            read_burst("extra Write pulse at e" & img(k + 1) & " of a read burst", shadow, write_at => k);
            idle("extra after Write pulse at e" & img(k + 1) & " of a read burst", 10);
        end loop;
        for k in 0 to 7 loop
            read_burst("extra Read pulse at e" & img(k + 1) & " of a read burst", shadow, read_at => k);
            idle("extra after Read pulse at e" & img(k + 1) & " of a read burst", 10);
        end loop;

        -- Extra: commands are sampled by level and only in S_IDLE. A command held through a burst
        -- neither restarts it nor is lost: it starts the next burst at e9. Same kind of command
        -- (held Write across a write burst, held Read across a read burst) and queued cross
        -- commands (Read during a write burst, Write during a read burst).
        write_burst("extra held Write, first write burst", SET_A, hold_write => true);
        write_burst("extra held Write, second write burst (e0 = e9 of the first)", SET_B);
        idle("extra after held Write", 3);
        read_burst("extra held Read, first read burst", SET_B, hold_read => true);
        read_burst("extra held Read, second read burst (e0 = e9 of the first)", SET_B);
        idle("extra after held Read", 3);
        write_burst("extra queued Read during write C", SET_C, hold_read => true);
        read_burst("extra queued read C (e0 = e9 of the write)", SET_C);
        idle("extra after queued read", 3);
        read_burst("extra queued Write during read C", SET_C, hold_write => true);
        write_burst("extra queued write D (e0 = e9 of the read)", SET_D);
        idle("extra after queued write", 3);

        -- Extra: pulsed commands are re-sampled as soon as the FSM is back in idle: a write burst
        -- whose e0 is e9 of the preceding read burst, then a read burst whose e0 is e9 of that write.
        read_burst("extra read D", SET_D);
        write_burst("extra write A right after a read burst", SET_A);
        read_burst("extra read A right after a write burst", SET_A);
        idle("extra final idle", 3);

        done <= true;
        if n_fail > 0 then
            report "FAIL: " & img(n_fail) & " of " & img(n_checks) & " checks" severity error;
            finish(1);
        end if;
        report "PASS: " & img(n_checks) & " checks";
        finish(0);
    end process;
end architecture;
