
signal signed dato_in_reg(31 downto 0) <= (others => '0');
signal signed dato_out(31 downto 0) <= (others => '0');
-- multiplicacion register input

process (clk)
begin
    if rising_edge(clk) then
        if rst = '1' then
            dato_in_reg <= (others => '0');
        else
            if valid_in = '1' then
                dato_in_reg <= dato_in;
            end if;
        end if;

end process;

-- multiplciajon combinacional
process (dato_in_reg)
begin
    dato_out <= dato_in_reg * to_signed(2, dato_out'length); -- Ejemplo de multiplicación (este puede ser suma o multiplicacion tambien pero qeuiro ver el path timing de esto en vivado cual seria el limite si esto sreia demasiado apra vivado o no)
end process;

-- multiplicacion register output   
process (clk)
begin
    if rising_edge(clk) then
        if rst = '1' then
            dato_in_reg <= (others => '0');
        else
            if valid_in = '1' then
                dato_in_reg <= dato_in;
            end if;
        end if;

end process;