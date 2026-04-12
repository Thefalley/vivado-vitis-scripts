library ieee;
use ieee.std_logic_1164.all;

entity irq_top is
    generic (
        C_S_AXI_DATA_WIDTH : integer := 32;
        C_S_AXI_ADDR_WIDTH : integer := 6
    );
    port (
        irq_out        : out std_logic;

        S_AXI_ACLK    : in  std_logic;
        S_AXI_ARESETN  : in  std_logic;
        S_AXI_AWADDR   : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWPROT   : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID  : in  std_logic;
        S_AXI_AWREADY  : out std_logic;
        S_AXI_WDATA    : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB    : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        S_AXI_WVALID   : in  std_logic;
        S_AXI_WREADY   : out std_logic;
        S_AXI_BRESP    : out std_logic_vector(1 downto 0);
        S_AXI_BVALID   : out std_logic;
        S_AXI_BREADY   : in  std_logic;
        S_AXI_ARADDR   : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARPROT   : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID  : in  std_logic;
        S_AXI_ARREADY  : out std_logic;
        S_AXI_RDATA    : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_RRESP    : out std_logic_vector(1 downto 0);
        S_AXI_RVALID   : out std_logic;
        S_AXI_RREADY   : in  std_logic
    );
end irq_top;

architecture rtl of irq_top is

    signal ctrl_s      : std_logic_vector(31 downto 0);
    signal threshold_s : std_logic_vector(31 downto 0);
    signal condition_s : std_logic_vector(31 downto 0);
    signal prescaler_s : std_logic_vector(31 downto 0);
    signal status_s    : std_logic_vector(31 downto 0);
    signal count_s     : std_logic_vector(31 downto 0);
    signal irq_count_s : std_logic_vector(31 downto 0);

begin

    u_cfg: entity work.axi_lite_cfg
        generic map (
            C_S_AXI_DATA_WIDTH => C_S_AXI_DATA_WIDTH,
            C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH
        )
        port map (
            ctrl_out      => ctrl_s,
            threshold_out => threshold_s,
            condition_out => condition_s,
            prescaler_out => prescaler_s,
            status_in     => status_s,
            count_in      => count_s,
            irq_count_in  => irq_count_s,
            S_AXI_ACLK    => S_AXI_ACLK,
            S_AXI_ARESETN => S_AXI_ARESETN,
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

    u_fsm: entity work.irq_fsm
        port map (
            clk       => S_AXI_ACLK,
            rst_n     => S_AXI_ARESETN,
            ctrl      => ctrl_s,
            threshold => threshold_s,
            condition => condition_s,
            prescaler => prescaler_s,
            status    => status_s,
            count_out => count_s,
            irq_count => irq_count_s,
            irq_out   => irq_out
        );

end rtl;
