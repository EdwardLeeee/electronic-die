library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity modulo_by_6 is
    port (
        rng_value : in  std_logic_vector(63 downto 0);
        die_value : out std_logic_vector(2 downto 0)
    );
end entity modulo_by_6;

architecture rtl of modulo_by_6 is
    signal remainder_64 : unsigned(63 downto 0);
begin
    -- The homework explicitly requests the VHDL mod operator.
    -- +1 converts the range 0..5 into the die range 1..6.
    remainder_64 <= unsigned(rng_value) mod to_unsigned(6, 64);
    die_value    <= std_logic_vector(resize(remainder_64, 3) + to_unsigned(1, 3));
end architecture rtl;
