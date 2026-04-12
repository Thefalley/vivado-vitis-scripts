library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
-- use work.MathUtils.all;

entity HsSkidBuf_dest is
    generic (
        HS_TDATA_WIDTH  : integer := 32;
        BYTE_WIDTH      : integer := 8;
        INTERFACE_NUM   : integer := 4;
        DEST_WIDTH      : integer := 2
    );
    port (
        clk          : in  std_logic;

        s_hs_tdata   : in  std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        s_hs_tdest   : in  std_logic_vector(DEST_WIDTH - 1 downto 0);
        s_hs_tlast   : in  std_logic;
        s_hs_tvalid  : in  std_logic;
        s_hs_tready  : out std_logic;

        m_hs_tdata   : out std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
        m_hs_tdest   : out std_logic_vector(DEST_WIDTH - 1 downto 0);
        m_hs_tlast   : out std_logic;
        m_hs_tvalid  : out std_logic;
        m_hs_tready  : in  std_logic
    );
end HsSkidBuf_dest;

architecture arch_HsSkidBuf_dest of HsSkidBuf_dest is

    -- Señales internas
    signal m_hs_tdata_next : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal m_hs_tdest_next : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal m_hs_tlast_next : std_logic;

    signal skid_tdata      : std_logic_vector(HS_TDATA_WIDTH - 1 downto 0);
    signal skid_tdest      : std_logic_vector(DEST_WIDTH - 1 downto 0);
    signal skid_tlast      : std_logic;

    signal skid_ce          : std_logic;
    signal m_hs_ce          : std_logic;

    signal is_skid          : std_logic := '0';
    signal is_skid_next     : std_logic;

    signal m_hs_tvalid_next : std_logic;

    signal s_hs_tready_next : std_logic;

    -- auxiliar signal m_hs_tvalid
    signal aux_m_hs_tvalid : std_logic := '0';
    signal aux_s_hs_tready : std_logic := '0';
begin

    m_hs_tvalid <= aux_m_hs_tvalid;
    s_hs_tready <= aux_s_hs_tready;

    -- Lógica combinacional para `m_hs_ce` y `skid_ce`
    m_hs_ce <= ((not aux_m_hs_tvalid) or m_hs_tready);
    skid_ce <= (not ((not aux_m_hs_tvalid) or m_hs_tready)) and (s_hs_tvalid and aux_s_hs_tready);

    -- Proceso combinacional para calcular el siguiente estado
    process(skid_ce, is_skid, aux_m_hs_tvalid, m_hs_tready)  
    begin
        is_skid_next <= is_skid; -- Mantener el estado por defecto
        if skid_ce = '1' then
            is_skid_next <= '1'; -- Cambiar a estado activo si skid_ce es 1
        elsif (is_skid = '1' and ((not aux_m_hs_tvalid) or m_hs_tready) = '1') then
            is_skid_next <= '0'; -- Cambiar a estado inactivo si ambas condiciones se cumplen
        end if;
    end process;

    -- Proceso secuencial para registrar el estado en el flanco de reloj
    process(clk)
    begin
        if rising_edge(clk) then
            is_skid <= is_skid_next; -- Actualizar el estado al siguiente
        end if;
    end process;

    -- Lógica combinacional para seleccionar datos
    process(is_skid, skid_tdata, skid_tdest, skid_tlast, s_hs_tdata, 
            s_hs_tdest, s_hs_tlast, s_hs_tvalid, aux_s_hs_tready)
    begin
        if is_skid = '1' then
            m_hs_tdata_next <= skid_tdata;
            m_hs_tdest_next <= skid_tdest;
            m_hs_tlast_next <= skid_tlast;
            m_hs_tvalid_next <= '1';
        else
            m_hs_tdata_next <= s_hs_tdata;
            m_hs_tdest_next <= s_hs_tdest;
            m_hs_tlast_next <= s_hs_tlast;
            m_hs_tvalid_next <= s_hs_tvalid and aux_s_hs_tready;
        end if;
    end process;

    -- NEXT_tready signal
    s_hs_tready_next <= m_hs_tready and (not is_skid);

    -- Proceso secuencial para s_hs_tready
    process(clk)
    begin
        if rising_edge(clk) then
            aux_s_hs_tready <= s_hs_tready_next;
        end if;
    end process;

    -- Proceso secuencial para actualizar las señales de salida
    process(clk)
    begin
        if rising_edge(clk) then
            if ((not aux_m_hs_tvalid) or m_hs_tready) = '1' then
                aux_m_hs_tvalid <= m_hs_tvalid_next;
                if m_hs_tvalid_next = '1' then
                    m_hs_tdata <= m_hs_tdata_next;
                    m_hs_tdest <= m_hs_tdest_next;
                    m_hs_tlast <= m_hs_tlast_next;
                end if;
            end if;
        end if;
    end process;

    -- Proceso secuencial para llenar el skid buffer
    process(clk)
    begin
        if rising_edge(clk) then
            if skid_ce = '1' then
                skid_tdata <= s_hs_tdata;
                skid_tdest <= s_hs_tdest;
                skid_tlast <= s_hs_tlast;
            end if;
        end if;
    end process;

end arch_HsSkidBuf_dest;
