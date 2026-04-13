library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_cmd_gen_s2mm is
     generic (
         CMD_WIDTH : integer := 72
     );
     port (
        s_axi_clk       : in std_logic;
        s_axi_resetn    : in std_logic;

        base_address    : in std_logic_vector(31 downto 0); -- Base address input
        burst_length    : in std_logic_vector(22 downto 0); -- Length of burst in bytes
        send_comand     : in std_logic; -- External pulse signal to trigger command generation

        s_axis_tdata    : out std_logic_vector(CMD_WIDTH-1 downto 0);
        s_axis_tkeep    : out std_logic_vector(CMD_WIDTH/8-1 downto 0);
        s_axis_tvalid   : out std_logic;
        s_axis_tlast    : out std_logic;
        s_axis_tready   : in std_logic;
        cmd_issue       : out std_logic
     );
end axis_cmd_gen_s2mm;

architecture impl of axis_cmd_gen_s2mm is
    signal cmd      : std_logic_vector(CMD_WIDTH-1 downto 0);
    signal btt      : std_logic_vector(22 downto 0);
    signal b_addr   : std_logic_vector(31 downto 0);
begin
    -- Assign burst length and base address dynamically
    btt <= burst_length;
    b_addr  <= base_address;
    cmd <= "0000" & "0000" & b_addr & '0' & '1' & "000000" & '1' & btt;

    -- AXIS signal generation based on external pulse
    process(s_axi_clk, s_axi_resetn, send_comand, s_axis_tready)
    begin
        if rising_edge(s_axi_clk) then
            if s_axi_resetn = '0' then
                s_axis_tdata  <= (others => '0'); 
                s_axis_tvalid <= '0';  
                s_axis_tlast  <= '0'; 
                cmd_issue     <= '0';
            elsif send_comand = '1' then
                s_axis_tdata  <= cmd; 
                s_axis_tvalid <= '1';  
                s_axis_tlast  <= '1';
                cmd_issue     <= '0';
            elsif s_axis_tready = '1' then
                s_axis_tdata  <= (others => '0'); 
                s_axis_tvalid <= '0'; 
                s_axis_tlast  <= '0'; 
                cmd_issue     <= '1';
            end if;        
        end if;
    end process;

    s_axis_tkeep <= (others => '1'); -- Enable all bytes
end impl;
