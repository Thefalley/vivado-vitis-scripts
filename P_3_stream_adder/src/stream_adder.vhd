library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- stream_adder: Recibe AXI-Stream, suma un valor configurable via AXI-Lite,
--               y envia el resultado por AXI-Stream.
--
-- Arquitectura:
--   s_axis -> [SkidBuf IN] -> [SUMA + add_value] -> [SkidBuf OUT] -> m_axis
--
-- AXI-Lite registros (via axi_lite_cfg, 32 registros):
--   reg0 (0x00): add_value - valor a sumar a cada dato
--   reg1..31:    reservados (port_not_used)

entity stream_adder is
    generic (
        DATA_WIDTH : integer := 32
    );
    port (
        clk           : in  std_logic;
        resetn        : in  std_logic;

        -- AXI-Lite Slave (configuracion, 32 registros, addr 7 bits)
        S_AXI_AWADDR  : in  std_logic_vector(6 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector((DATA_WIDTH/8) - 1 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(6 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic;

        -- AXI-Stream Slave (entrada desde DMA MM2S)
        s_axis_tdata   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        s_axis_tlast   : in  std_logic;
        s_axis_tvalid  : in  std_logic;
        s_axis_tready  : out std_logic;

        -- AXI-Stream Master (salida hacia DMA S2MM)
        m_axis_tdata   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        m_axis_tlast   : out std_logic;
        m_axis_tvalid  : out std_logic;
        m_axis_tready  : in  std_logic
    );
end stream_adder;

architecture rtl of stream_adder is

    -- Registro de configuracion desde AXI-Lite
    signal add_value : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- Puertos no usados del axi_lite_cfg (declarados para conexion)
    signal pnu_01, pnu_02, pnu_03, pnu_04 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_05, pnu_06, pnu_07, pnu_08 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_09, pnu_10, pnu_11, pnu_12 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_13, pnu_14, pnu_15, pnu_16 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_17, pnu_18, pnu_19, pnu_20 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_21, pnu_22, pnu_23, pnu_24 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_25, pnu_26, pnu_27, pnu_28 : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal pnu_29, pnu_30                 : std_logic_vector(DATA_WIDTH - 1 downto 0);

    -- Senales entre skid_in y logica de suma
    signal skid_in_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal skid_in_tlast  : std_logic;
    signal skid_in_tvalid : std_logic;
    signal skid_in_tready : std_logic;

    -- Senales entre logica de suma y skid_out
    signal sum_tdata  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal sum_tlast  : std_logic;
    signal sum_tvalid : std_logic;
    signal sum_tready : std_logic;

    -- Dummy dest para skid buffer
    signal zero_dest     : std_logic_vector(1 downto 0) := "00";
    signal open_dest_in  : std_logic_vector(1 downto 0);
    signal open_dest_out : std_logic_vector(1 downto 0);

begin

    -----------------------------------------------------------------
    -- AXI-Lite: axi_lite_cfg (basado en S00_AXI_32_REG)
    -----------------------------------------------------------------
    axil_inst : entity work.axi_lite_cfg
        generic map (
            C_S_AXI_DATA_WIDTH => DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => 7
        )
        port map (
            add_value        => add_value,
            port_not_used_01 => pnu_01,
            port_not_used_02 => pnu_02,
            port_not_used_03 => pnu_03,
            port_not_used_04 => pnu_04,
            port_not_used_05 => pnu_05,
            port_not_used_06 => pnu_06,
            port_not_used_07 => pnu_07,
            port_not_used_08 => pnu_08,
            port_not_used_09 => pnu_09,
            port_not_used_10 => pnu_10,
            port_not_used_11 => pnu_11,
            port_not_used_12 => pnu_12,
            port_not_used_13 => pnu_13,
            port_not_used_14 => pnu_14,
            port_not_used_15 => pnu_15,
            port_not_used_16 => pnu_16,
            port_not_used_17 => pnu_17,
            port_not_used_18 => pnu_18,
            port_not_used_19 => pnu_19,
            port_not_used_20 => pnu_20,
            port_not_used_21 => pnu_21,
            port_not_used_22 => pnu_22,
            port_not_used_23 => pnu_23,
            port_not_used_24 => pnu_24,
            port_not_used_25 => pnu_25,
            port_not_used_26 => pnu_26,
            port_not_used_27 => pnu_27,
            port_not_used_28 => pnu_28,
            port_not_used_29 => pnu_29,
            port_not_used_30 => pnu_30,
            S_AXI_ACLK    => clk,
            S_AXI_ARESETN => resetn,
            S_AXI_AWADDR  => S_AXI_AWADDR,
            S_AXI_AWPROT  => S_AXI_AWPROT,
            S_AXI_AWVALID => S_AXI_AWVALID,
            S_AXI_AWREADY => S_AXI_AWREADY,
            S_AXI_WDATA   => S_AXI_WDATA,
            S_AXI_WSTRB   => S_AXI_WSTRB,
            S_AXI_WVALID  => S_AXI_WVALID,
            S_AXI_WREADY  => S_AXI_WREADY,
            S_AXI_BRESP   => S_AXI_BRESP,
            S_AXI_BVALID  => S_AXI_BVALID,
            S_AXI_BREADY  => S_AXI_BREADY,
            S_AXI_ARADDR  => S_AXI_ARADDR,
            S_AXI_ARPROT  => S_AXI_ARPROT,
            S_AXI_ARVALID => S_AXI_ARVALID,
            S_AXI_ARREADY => S_AXI_ARREADY,
            S_AXI_RDATA   => S_AXI_RDATA,
            S_AXI_RRESP   => S_AXI_RRESP,
            S_AXI_RVALID  => S_AXI_RVALID,
            S_AXI_RREADY  => S_AXI_RREADY
        );

    -----------------------------------------------------------------
    -- Skid Buffer INPUT: s_axis -> skid_in
    -----------------------------------------------------------------
    skid_in_inst : entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH => DATA_WIDTH,
            DEST_WIDTH     => 2
        )
        port map (
            clk          => clk,
            s_hs_tdata   => s_axis_tdata,
            s_hs_tdest   => zero_dest,
            s_hs_tlast   => s_axis_tlast,
            s_hs_tvalid  => s_axis_tvalid,
            s_hs_tready  => s_axis_tready,
            m_hs_tdata   => skid_in_tdata,
            m_hs_tdest   => open_dest_in,
            m_hs_tlast   => skid_in_tlast,
            m_hs_tvalid  => skid_in_tvalid,
            m_hs_tready  => skid_in_tready
        );

    -----------------------------------------------------------------
    -- LOGICA DE SUMA (combinacional)
    -----------------------------------------------------------------
    sum_tdata      <= std_logic_vector(unsigned(skid_in_tdata) + unsigned(add_value));
    sum_tlast      <= skid_in_tlast;
    sum_tvalid     <= skid_in_tvalid;
    skid_in_tready <= sum_tready;

    -----------------------------------------------------------------
    -- Skid Buffer OUTPUT: sum -> m_axis
    -----------------------------------------------------------------
    skid_out_inst : entity work.HsSkidBuf_dest
        generic map (
            HS_TDATA_WIDTH => DATA_WIDTH,
            DEST_WIDTH     => 2
        )
        port map (
            clk          => clk,
            s_hs_tdata   => sum_tdata,
            s_hs_tdest   => zero_dest,
            s_hs_tlast   => sum_tlast,
            s_hs_tvalid  => sum_tvalid,
            s_hs_tready  => sum_tready,
            m_hs_tdata   => m_axis_tdata,
            m_hs_tdest   => open_dest_out,
            m_hs_tlast   => m_axis_tlast,
            m_hs_tvalid  => m_axis_tvalid,
            m_hs_tready  => m_axis_tready
        );

end rtl;
