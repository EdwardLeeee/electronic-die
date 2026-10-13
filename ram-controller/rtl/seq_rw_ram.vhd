library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity seq_rw_ram is
    generic (
        -- Activation code: the controller leaves IDLE only when ID matches it.
        ID_CODE : std_logic_vector(16 downto 0) := std_logic_vector(to_unsigned(22059, 17))
    );
    port (
        clk         : in  std_logic;
        Read        : in  std_logic;
        Write       : in  std_logic;
        ID          : in  std_logic_vector(16 downto 0);
        Data_Input  : in  std_logic_vector(7 downto 0);
        Data_Output : out std_logic_vector(7 downto 0)
    );
end seq_rw_ram;

architecture behavioral of seq_rw_ram is

    -- FSM states (Idle + 8 read states + 8 write states)
    type state_t is (
        S_IDLE,
        S_R1, S_R2, S_R3, S_R4, S_R5, S_R6, S_R7, S_R8,
        S_W1, S_W2, S_W3, S_W4, S_W5, S_W6, S_W7, S_W8
    );
    signal state, next_state : state_t := S_IDLE;-- delcare as state_t

    -- Internal controller outputs (would have been wires in the
    -- two-file version)
    signal W_En   : std_logic;
    signal R_Addr : std_logic_vector(2 downto 0);
    signal W_Addr : std_logic_vector(2 downto 0);
    
    -- MAKE them visible on waveform plot
    attribute keep : boolean;
    attribute keep of W_En   : signal is true;
    attribute keep of W_Addr : signal is true;
    attribute keep of R_Addr : signal is true;

    -- 8-entry, 8-bit RAM. 
    -- The RAM consists of 8 entries, where each entry has 1 byte.
    type ram_t is array (0 to 7) of std_logic_vector(7 downto 0);
    signal mem : ram_t := (others => (others => '0')); --others means all entity inside

begin
    ----------------------------------------------------------------
    -- Controller: state register
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Controller: next-state logic
    ----------------------------------------------------------------
    process(state, Read, Write, ID)
    begin
        case state is
            when S_IDLE =>
                if Write = '1' and ID = ID_CODE then
                    next_state <= S_W1;
                elsif Read = '1' and ID = ID_CODE then
                    next_state <= S_R1;
                else
                    next_state <= S_IDLE;
                end if;

            when S_W1 => next_state <= S_W2;
            when S_W2 => next_state <= S_W3;
            when S_W3 => next_state <= S_W4;
            when S_W4 => next_state <= S_W5;
            when S_W5 => next_state <= S_W6;
            when S_W6 => next_state <= S_W7;
            when S_W7 => next_state <= S_W8;
            when S_W8 => next_state <= S_IDLE;

            when S_R1 => next_state <= S_R2;
            when S_R2 => next_state <= S_R3;
            when S_R3 => next_state <= S_R4;
            when S_R4 => next_state <= S_R5;
            when S_R5 => next_state <= S_R6;
            when S_R6 => next_state <= S_R7;
            when S_R7 => next_state <= S_R8;
            when S_R8 => next_state <= S_IDLE;

            when others => next_state <= S_IDLE;
        end case;
    end process;

    ----------------------------------------------------------------
    -- Controller: output logic (Moore)
    ----------------------------------------------------------------
    process(state)
    begin
        -- Defaults
        R_Addr <= "000";
        W_Addr <= "000";
        W_En   <= '0';

        case state is
            when S_IDLE => null;  -- defaults

            when S_W1 => W_Addr <= "000"; W_En <= '1';
            when S_W2 => W_Addr <= "001"; W_En <= '1';
            when S_W3 => W_Addr <= "010"; W_En <= '1';
            when S_W4 => W_Addr <= "011"; W_En <= '1';
            when S_W5 => W_Addr <= "100"; W_En <= '1';
            when S_W6 => W_Addr <= "101"; W_En <= '1';
            when S_W7 => W_Addr <= "110"; W_En <= '1';
            when S_W8 => W_Addr <= "111"; W_En <= '1';

            when S_R1 => R_Addr <= "000";
            when S_R2 => R_Addr <= "001";
            when S_R3 => R_Addr <= "010";
            when S_R4 => R_Addr <= "011";
            when S_R5 => R_Addr <= "100";
            when S_R6 => R_Addr <= "101";
            when S_R7 => R_Addr <= "110";
            when S_R8 => R_Addr <= "111";

            when others => null;
        end case;
    end process;

    ----------------------------------------------------------------
    -- 2-port RAM (synchronous write & synchronous read)
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if W_En = '1' then
            -- binary changes into unsigned first and changes into integer which is the index for mem 
                mem(to_integer(unsigned(W_Addr))) <= Data_Input;
            end if;
            Data_Output <= mem(to_integer(unsigned(R_Addr)));
        end if;
    end process;

end behavioral;
