-------------------------------------------------------------------------------
-- conv_simple_top.vhd — Top-level: AXI-Lite + BRAM + conv_simple
-------------------------------------------------------------------------------
-- Conecta:
--   axi_lite_conv (32 registros) ← ARM configura
--   conv_simple (motor conv)     ← lee/escribe BRAM
--   BRAM dual-port (8KB)         ← port A: conv, port B: AXI-Lite window
--
-- MEMORY MAP (desde ARM, base + offset):
--   0x0000-0x007F: registros AXI-Lite (32 x 4 bytes)
--   0x2000-0x3FFF: ventana BRAM (8192 bytes, word-addressed)
--
-- El ARM escribe datos (weights, input, bias) en la ventana BRAM,
-- configura los registros, pulsa start, y lee el output de la BRAM.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity conv_simple_top is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 15  -- 0x0000-0x7FFF (regs + BRAM)
    );
    port (
        S_AXI_ACLK    : in  std_logic;
        S_AXI_ARESETN : in  std_logic;
        S_AXI_AWADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector(3 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic
    );
end entity conv_simple_top;

architecture rtl of conv_simple_top is

    -- =====================================================================
    -- BRAM: 8192 bytes = 2048 words x 32 bits, dual-port
    -- Port A: conv_simple (byte-addressed read/write)
    -- Port B: AXI-Lite (word-addressed read/write from ARM)
    -- =====================================================================
    constant BRAM_DEPTH : natural := 2048;  -- 2048 x 32-bit = 8KB
    constant BRAM_AW    : natural := 11;    -- log2(2048)

    type bram_t is array(0 to BRAM_DEPTH-1) of std_logic_vector(31 downto 0);
    signal bram : bram_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of bram : signal is "block";

    -- Port B (AXI side): word-addressed
    signal bram_b_addr : unsigned(BRAM_AW-1 downto 0);
    signal bram_b_dout : std_logic_vector(31 downto 0);
    signal bram_b_din  : std_logic_vector(31 downto 0);
    signal bram_b_we   : std_logic_vector(3 downto 0);
    signal bram_b_en   : std_logic;

    -- Port A (conv side): byte-addressed, muxed to word
    signal bram_a_word_addr : unsigned(BRAM_AW-1 downto 0);
    signal bram_a_dout      : std_logic_vector(31 downto 0);
    signal bram_a_byte_sel  : unsigned(1 downto 0);  -- byte lane within word
    signal bram_a_byte_sel_r: unsigned(1 downto 0);  -- registered for read

    -- =====================================================================
    -- AXI-Lite register outputs
    -- =====================================================================
    signal reg_ctrl      : std_logic_vector(31 downto 0);
    signal reg_c_in_out  : std_logic_vector(31 downto 0);
    signal reg_h_w_in    : std_logic_vector(31 downto 0);
    signal reg_conv_cfg  : std_logic_vector(31 downto 0);
    signal reg_x_zp      : std_logic_vector(31 downto 0);
    signal reg_M0        : std_logic_vector(31 downto 0);
    signal reg_shift_yzp : std_logic_vector(31 downto 0);
    signal reg_addr_in   : std_logic_vector(31 downto 0);
    signal reg_addr_wt   : std_logic_vector(31 downto 0);
    signal reg_addr_bias : std_logic_vector(31 downto 0);
    signal reg_addr_out  : std_logic_vector(31 downto 0);
    signal status_word   : std_logic_vector(31 downto 0);

    -- =====================================================================
    -- Conv engine signals
    -- =====================================================================
    signal conv_start    : std_logic;
    signal conv_start_r  : std_logic;  -- edge detect
    signal conv_done     : std_logic;
    signal conv_busy     : std_logic;
    signal conv_dbg      : std_logic_vector(4 downto 0);

    signal mem_rd_addr   : unsigned(15 downto 0);
    signal mem_rd_en     : std_logic;
    signal mem_rd_data   : std_logic_vector(7 downto 0);
    signal mem_wr_addr   : unsigned(15 downto 0);
    signal mem_wr_data   : std_logic_vector(7 downto 0);
    signal mem_wr_en     : std_logic;

    signal dbg_oh, dbg_ow : unsigned(9 downto 0);

    -- =====================================================================
    -- AXI address decode: bit 13 selects BRAM vs registers
    -- 0x0000-0x007F: registers (addr[13]=0)
    -- 0x2000-0x3FFF: BRAM     (addr[13]=1)
    -- =====================================================================
    signal is_bram_wr    : std_logic;
    signal is_bram_rd    : std_logic;

    -- AXI-Lite sub-bus for registers (7-bit address)
    signal reg_awaddr    : std_logic_vector(6 downto 0);
    signal reg_araddr    : std_logic_vector(6 downto 0);
    signal reg_awvalid   : std_logic;
    signal reg_wvalid    : std_logic;
    signal reg_awready   : std_logic;
    signal reg_wready    : std_logic;
    signal reg_bresp     : std_logic_vector(1 downto 0);
    signal reg_bvalid    : std_logic;
    signal reg_arvalid   : std_logic;
    signal reg_arready   : std_logic;
    signal reg_rdata     : std_logic_vector(31 downto 0);
    signal reg_rresp     : std_logic_vector(1 downto 0);
    signal reg_rvalid    : std_logic;

    -- AXI response mux state
    signal axi_wr_to_bram : std_logic;
    signal axi_rd_to_bram : std_logic;
    signal bram_rd_valid   : std_logic;
    signal bram_rd_data_r  : std_logic_vector(31 downto 0);

begin

    -- =====================================================================
    -- AXI ADDRESS DECODE
    -- =====================================================================
    is_bram_wr <= S_AXI_AWADDR(13);
    is_bram_rd <= S_AXI_ARADDR(13);

    -- =====================================================================
    -- AXI-Lite REGISTER SLAVE (for config registers)
    -- Pass through the AXI bus with 7-bit address
    -- =====================================================================
    reg_awaddr  <= S_AXI_AWADDR(6 downto 0);
    reg_araddr  <= S_AXI_ARADDR(6 downto 0);

    u_regs : entity work.axi_lite_conv
        generic map (
            C_S_AXI_DATA_WIDTH => 32,
            C_S_AXI_ADDR_WIDTH => 7
        )
        port map (
            reg_ctrl         => reg_ctrl,
            reg_c_in_out     => reg_c_in_out,
            reg_h_w_in       => reg_h_w_in,
            reg_conv_cfg     => reg_conv_cfg,
            reg_x_zp         => reg_x_zp,
            reg_M0           => reg_M0,
            reg_shift_yzp    => reg_shift_yzp,
            reg_addr_in      => reg_addr_in,
            reg_addr_wt      => reg_addr_wt,
            reg_addr_bias    => reg_addr_bias,
            reg_addr_out     => reg_addr_out,
            status_in        => status_word,
            reg_reserved_12  => open,
            reg_reserved_13  => open,
            reg_reserved_14  => open,
            reg_reserved_15  => open,
            reg_reserved_16  => open,
            reg_reserved_17  => open,
            reg_reserved_18  => open,
            reg_reserved_19  => open,
            reg_reserved_20  => open,
            reg_reserved_21  => open,
            reg_reserved_22  => open,
            reg_reserved_23  => open,
            reg_reserved_24  => open,
            reg_reserved_25  => open,
            reg_reserved_26  => open,
            reg_reserved_27  => open,
            reg_reserved_28  => open,
            reg_reserved_29  => open,
            reg_reserved_30  => open,
            -- AXI bus
            S_AXI_ACLK    => S_AXI_ACLK,
            S_AXI_ARESETN => S_AXI_ARESETN,
            S_AXI_AWADDR  => reg_awaddr,
            S_AXI_AWPROT  => S_AXI_AWPROT,
            S_AXI_AWVALID => reg_awvalid,
            S_AXI_AWREADY => reg_awready,
            S_AXI_WDATA   => S_AXI_WDATA,
            S_AXI_WSTRB   => S_AXI_WSTRB,
            S_AXI_WVALID  => reg_wvalid,
            S_AXI_WREADY  => reg_wready,
            S_AXI_BRESP   => reg_bresp,
            S_AXI_BVALID  => reg_bvalid,
            S_AXI_BREADY  => S_AXI_BREADY,
            S_AXI_ARADDR  => reg_araddr,
            S_AXI_ARPROT  => S_AXI_ARPROT,
            S_AXI_ARVALID => reg_arvalid,
            S_AXI_ARREADY => reg_arready,
            S_AXI_RDATA   => reg_rdata,
            S_AXI_RRESP   => reg_rresp,
            S_AXI_RVALID  => reg_rvalid,
            S_AXI_RREADY  => S_AXI_RREADY
        );

    -- Route AXI signals based on address decode
    reg_awvalid <= S_AXI_AWVALID when is_bram_wr = '0' else '0';
    reg_wvalid  <= S_AXI_WVALID  when is_bram_wr = '0' else '0';
    reg_arvalid <= S_AXI_ARVALID when is_bram_rd = '0' else '0';

    -- =====================================================================
    -- BRAM: TRUE DUAL-PORT, single process (Vivado inference template)
    -- Port A: conv_simple (byte read/write)
    -- Port B: AXI-Lite (word read/write)
    -- =====================================================================
    bram_b_addr <= unsigned(S_AXI_AWADDR(12 downto 2)) when is_bram_wr = '1'
                   else unsigned(S_AXI_ARADDR(12 downto 2));
    bram_b_din  <= S_AXI_WDATA;
    bram_b_en <= '1' when (is_bram_wr = '1' and S_AXI_AWVALID = '1'
                           and S_AXI_WVALID = '1' and conv_busy = '0')
                 else '0';
    bram_b_we <= S_AXI_WSTRB when bram_b_en = '1' else "0000";

    p_bram : process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            -- PORT A: conv_simple (byte-level access)
            if mem_rd_en = '1' then
                bram_a_dout       <= bram(to_integer(unsigned(mem_rd_addr(12 downto 2))));
                bram_a_byte_sel_r <= mem_rd_addr(1 downto 0);
            end if;
            if mem_wr_en = '1' then
                case mem_wr_addr(1 downto 0) is
                    when "00" => bram(to_integer(unsigned(mem_wr_addr(12 downto 2))))(7 downto 0)   <= mem_wr_data;
                    when "01" => bram(to_integer(unsigned(mem_wr_addr(12 downto 2))))(15 downto 8)  <= mem_wr_data;
                    when "10" => bram(to_integer(unsigned(mem_wr_addr(12 downto 2))))(23 downto 16) <= mem_wr_data;
                    when "11" => bram(to_integer(unsigned(mem_wr_addr(12 downto 2))))(31 downto 24) <= mem_wr_data;
                    when others => null;
                end case;
            end if;
            -- PORT B: AXI-Lite (word-level access)
            bram_b_dout <= bram(to_integer(bram_b_addr));
            if bram_b_en = '1' then
                for i in 0 to 3 loop
                    if bram_b_we(i) = '1' then
                        bram(to_integer(bram_b_addr))(i*8+7 downto i*8)
                            <= bram_b_din(i*8+7 downto i*8);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- =====================================================================
    -- AXI RESPONSE MUX: registers vs BRAM
    -- Simple: registers handle their own handshake.
    -- BRAM writes/reads use a simple FSM.
    -- =====================================================================
    p_axi_mux : process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_wr_to_bram <= '0';
                axi_rd_to_bram <= '0';
                bram_rd_valid  <= '0';
                bram_rd_data_r <= (others => '0');
            else
                -- Write response for BRAM
                if is_bram_wr = '1' and S_AXI_AWVALID = '1' and S_AXI_WVALID = '1' then
                    axi_wr_to_bram <= '1';
                elsif S_AXI_BREADY = '1' and axi_wr_to_bram = '1' then
                    axi_wr_to_bram <= '0';
                end if;

                -- Read response for BRAM
                if is_bram_rd = '1' and S_AXI_ARVALID = '1' and bram_rd_valid = '0' then
                    axi_rd_to_bram <= '1';
                    bram_rd_valid  <= '0';
                elsif axi_rd_to_bram = '1' and bram_rd_valid = '0' then
                    -- 1-cycle BRAM latency passed, data ready
                    bram_rd_data_r <= bram_b_dout;
                    bram_rd_valid  <= '1';
                    axi_rd_to_bram <= '0';
                elsif bram_rd_valid = '1' and S_AXI_RREADY = '1' then
                    bram_rd_valid <= '0';
                end if;
            end if;
        end if;
    end process;

    -- AXI output mux
    S_AXI_AWREADY <= reg_awready when is_bram_wr = '0'
                     else (S_AXI_AWVALID and S_AXI_WVALID);
    S_AXI_WREADY  <= reg_wready when is_bram_wr = '0'
                     else (S_AXI_AWVALID and S_AXI_WVALID);
    S_AXI_BRESP   <= reg_bresp when axi_wr_to_bram = '0' else "00";
    S_AXI_BVALID  <= reg_bvalid when axi_wr_to_bram = '0' else axi_wr_to_bram;

    S_AXI_ARREADY <= reg_arready when is_bram_rd = '0'
                     else (S_AXI_ARVALID and not bram_rd_valid);
    S_AXI_RDATA   <= reg_rdata when bram_rd_valid = '0' else bram_rd_data_r;
    S_AXI_RRESP   <= reg_rresp when bram_rd_valid = '0' else "00";
    S_AXI_RVALID  <= reg_rvalid when bram_rd_valid = '0' else bram_rd_valid;

    -- =====================================================================
    -- CONV_SIMPLE ENGINE
    -- =====================================================================

    -- Start edge detect (ARM writes 1 to reg_ctrl[0])
    p_start : process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                conv_start_r <= '0';
                conv_start   <= '0';
            else
                conv_start_r <= reg_ctrl(0);
                conv_start   <= reg_ctrl(0) and not conv_start_r;  -- rising edge
            end if;
        end if;
    end process;

    -- Status word for ARM readback
    status_word <= x"000000" & '0'  -- bits [31:7] = 0
                 & conv_dbg          -- bits [6:2]
                 & conv_busy         -- bit  [1]
                 & conv_done;        -- bit  [0]

    u_conv : entity work.conv_simple
        port map (
            clk     => S_AXI_ACLK,
            rst_n   => S_AXI_ARESETN,
            start   => conv_start,
            done    => conv_done,
            busy    => conv_busy,
            -- Config from registers
            cfg_c_in    => unsigned(reg_c_in_out(9 downto 0)),
            cfg_c_out   => unsigned(reg_c_in_out(25 downto 16)),
            cfg_h_in    => unsigned(reg_h_w_in(9 downto 0)),
            cfg_w_in    => unsigned(reg_h_w_in(25 downto 16)),
            cfg_ksize   => unsigned(reg_conv_cfg(3 downto 0)),
            cfg_stride  => unsigned(reg_conv_cfg(7 downto 4)),
            cfg_pad     => unsigned(reg_conv_cfg(11 downto 8)),
            cfg_x_zp    => signed(reg_x_zp(8 downto 0)),
            cfg_M0      => unsigned(reg_M0),
            cfg_n_shift => unsigned(reg_shift_yzp(5 downto 0)),
            cfg_y_zp    => signed(reg_shift_yzp(15 downto 8)),
            cfg_addr_input   => unsigned(reg_addr_in(15 downto 0)),
            cfg_addr_weights => unsigned(reg_addr_wt(15 downto 0)),
            cfg_addr_bias    => unsigned(reg_addr_bias(15 downto 0)),
            cfg_addr_output  => unsigned(reg_addr_out(15 downto 0)),
            -- Memory interface
            mem_rd_addr => mem_rd_addr,
            mem_rd_en   => mem_rd_en,
            mem_rd_data => mem_rd_data,
            mem_wr_addr => mem_wr_addr,
            mem_wr_data => mem_wr_data,
            mem_wr_en   => mem_wr_en,
            -- Debug
            dbg_state => conv_dbg,
            dbg_oh    => dbg_oh,
            dbg_ow    => dbg_ow
        );

    -- Extract byte from word (registered byte_sel for read latency alignment)
    with bram_a_byte_sel_r select mem_rd_data <=
        bram_a_dout(7 downto 0)   when "00",
        bram_a_dout(15 downto 8)  when "01",
        bram_a_dout(23 downto 16) when "10",
        bram_a_dout(31 downto 24) when "11",
        (others => '0')           when others;

end architecture rtl;
