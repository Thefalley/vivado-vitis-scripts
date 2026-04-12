-------------------------------------------------------------------------------
-- i2c_init.vhd - Fixed-sequence I2C master for ADV7511 initialization
--
-- After reset, waits ~100 ms then sends a sequence of register writes
-- to configure the ADV7511 HDMI transmitter. Each write is:
--   START -> slave_addr(W) -> reg_addr -> reg_data -> STOP
--
-- I2C clock: ~100 kHz derived from the system clock.
-- ADV7511 address: 0x39 (7-bit) -> 0x72 (8-bit write)
--
-- Once all registers are written, the "done" output goes high and
-- the state machine idles.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_init is
    generic (
        CLK_FREQ_HZ  : natural := 100_000_000;  -- system clock frequency
        I2C_FREQ_HZ  : natural := 100_000        -- I2C SCL frequency
    );
    port (
        clk   : in    std_logic;
        rst   : in    std_logic;
        -- I2C bus (directly drive/sense FPGA pins with open-drain emulation)
        scl   : inout std_logic;
        sda   : inout std_logic;
        -- Status
        done  : out   std_logic
    );
end entity i2c_init;

architecture rtl of i2c_init is

    ---------------------------------------------------------------------------
    -- I2C timing: quarter-period count for clock generation
    -- SCL period = CLK_FREQ / I2C_FREQ clocks
    -- We use quarter-period steps: SCL high/low each last 2 quarter-periods
    ---------------------------------------------------------------------------
    constant QUARTER : natural := CLK_FREQ_HZ / (I2C_FREQ_HZ * 4);

    -- Startup delay: ~100 ms
    constant STARTUP_CNT : natural := CLK_FREQ_HZ / 10;  -- 100 ms

    -- ADV7511 I2C write address (7-bit 0x39 << 1 = 0x72)
    constant SLAVE_WR_ADDR : std_logic_vector(7 downto 0) := x"72";

    ---------------------------------------------------------------------------
    -- Register initialization table
    -- Each entry: (register address, data)
    ---------------------------------------------------------------------------
    type reg_entry_t is record
        addr : std_logic_vector(7 downto 0);
        data : std_logic_vector(7 downto 0);
    end record;

    type reg_table_t is array(natural range <>) of reg_entry_t;

    constant REG_TABLE : reg_table_t := (
        (x"41", x"10"),  -- Power up
        (x"98", x"03"),  -- Required (ADI recommended)
        (x"9A", x"E0"),  -- Required
        (x"9C", x"30"),  -- Required
        (x"9D", x"01"),  -- Required
        (x"A2", x"A4"),  -- Required
        (x"A3", x"A4"),  -- Required
        (x"AF", x"06"),  -- HDMI mode, not DVI
        (x"15", x"00"),  -- Input: 24-bit RGB 4:4:4
        (x"16", x"30"),  -- Output: RGB 4:4:4, 8-bit color depth
        (x"48", x"08"),  -- Right justified
        (x"D6", x"C0")   -- HPD always high (override HPD)
    );

    constant NUM_REGS : natural := REG_TABLE'length;

    ---------------------------------------------------------------------------
    -- FSM states
    ---------------------------------------------------------------------------
    type state_t is (
        S_STARTUP,       -- Wait ~100 ms after power-up
        S_IDLE,          -- Between register writes / final idle
        S_START,         -- Generate START condition
        S_SEND_BYTE,     -- Shift out 8 bits of a byte
        S_RECV_ACK,      -- Clock in ACK bit from slave
        S_STOP,          -- Generate STOP condition
        S_DONE           -- All registers written
    );

    signal state     : state_t := S_STARTUP;
    signal timer     : natural range 0 to STARTUP_CNT := 0;
    signal qtr_cnt   : natural range 0 to QUARTER := 0;
    signal bit_cnt   : natural range 0 to 7 := 0;

    -- Current register index
    signal reg_idx   : natural range 0 to NUM_REGS := 0;

    -- Sub-phase within a register write: 0=addr, 1=reg, 2=data
    signal byte_phase : natural range 0 to 2 := 0;

    -- Byte being shifted out
    signal shift_reg : std_logic_vector(7 downto 0) := (others => '0');

    -- I2C internal drive signals (active-low open-drain emulation)
    signal scl_drv   : std_logic := '1';  -- '0' = drive low, '1' = release (high-Z)
    signal sda_drv   : std_logic := '1';

    -- Quarter-period phase for bit-level timing
    -- 0: SCL low, set SDA
    -- 1: SCL rising
    -- 2: SCL high (sample point)
    -- 3: SCL falling
    signal qtr_phase : natural range 0 to 3 := 0;

    -- Tick: one pulse per quarter-period
    signal qtr_tick  : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Open-drain emulation: drive low or release to high-Z (pulled up externally)
    ---------------------------------------------------------------------------
    scl <= '0' when scl_drv = '0' else 'Z';
    sda <= '0' when sda_drv = '0' else 'Z';

    ---------------------------------------------------------------------------
    -- Quarter-period tick generator
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                qtr_cnt  <= 0;
                qtr_tick <= '0';
            else
                if qtr_cnt = QUARTER - 1 then
                    qtr_cnt  <= 0;
                    qtr_tick <= '1';
                else
                    qtr_cnt  <= qtr_cnt + 1;
                    qtr_tick <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Main FSM
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= S_STARTUP;
                timer      <= 0;
                reg_idx    <= 0;
                byte_phase <= 0;
                bit_cnt    <= 0;
                qtr_phase  <= 0;
                scl_drv    <= '1';
                sda_drv    <= '1';
                shift_reg  <= (others => '0');
                done       <= '0';
            else
                case state is

                    -------------------------------------------------------
                    -- STARTUP: wait ~100 ms for ADV7511 to be ready
                    -------------------------------------------------------
                    when S_STARTUP =>
                        scl_drv <= '1';
                        sda_drv <= '1';
                        if timer = STARTUP_CNT - 1 then
                            timer <= 0;
                            state <= S_IDLE;
                        else
                            timer <= timer + 1;
                        end if;

                    -------------------------------------------------------
                    -- IDLE: start next register write or finish
                    -------------------------------------------------------
                    when S_IDLE =>
                        scl_drv <= '1';
                        sda_drv <= '1';
                        if reg_idx = NUM_REGS then
                            state <= S_DONE;
                        else
                            -- Small gap between transactions (1 quarter period)
                            if qtr_tick = '1' then
                                byte_phase <= 0;
                                state      <= S_START;
                                qtr_phase  <= 0;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- START: SDA goes low while SCL is high
                    -- Phase 0: ensure SDA=1, SCL=1 (setup)
                    -- Phase 1: pull SDA low (START condition)
                    -- Phase 2: pull SCL low (prepare for first bit)
                    -------------------------------------------------------
                    when S_START =>
                        if qtr_tick = '1' then
                            case qtr_phase is
                                when 0 =>
                                    sda_drv   <= '1';
                                    scl_drv   <= '1';
                                    qtr_phase <= 1;
                                when 1 =>
                                    sda_drv   <= '0';  -- START: SDA falls while SCL high
                                    qtr_phase <= 2;
                                when 2 =>
                                    scl_drv   <= '0';  -- Pull SCL low
                                    qtr_phase <= 0;
                                    -- Load first byte (slave address)
                                    shift_reg  <= SLAVE_WR_ADDR;
                                    byte_phase <= 0;
                                    bit_cnt    <= 0;
                                    state      <= S_SEND_BYTE;
                                when others =>
                                    qtr_phase <= 0;
                            end case;
                        end if;

                    -------------------------------------------------------
                    -- SEND_BYTE: clock out 8 bits MSB first
                    -- Each bit uses 4 quarter-phases:
                    --   Q0: SCL low, set SDA to bit value
                    --   Q1: SCL high (rising edge)
                    --   Q2: SCL high (hold)
                    --   Q3: SCL low (falling edge)
                    -------------------------------------------------------
                    when S_SEND_BYTE =>
                        if qtr_tick = '1' then
                            case qtr_phase is
                                when 0 =>
                                    -- Set SDA while SCL is low
                                    sda_drv   <= shift_reg(7);
                                    scl_drv   <= '0';
                                    qtr_phase <= 1;
                                when 1 =>
                                    scl_drv   <= '1';  -- SCL high
                                    qtr_phase <= 2;
                                when 2 =>
                                    qtr_phase <= 3;    -- Hold SCL high
                                when 3 =>
                                    scl_drv <= '0';    -- SCL low
                                    if bit_cnt = 7 then
                                        -- All 8 bits sent, go get ACK
                                        bit_cnt   <= 0;
                                        qtr_phase <= 0;
                                        state     <= S_RECV_ACK;
                                    else
                                        bit_cnt   <= bit_cnt + 1;
                                        shift_reg <= shift_reg(6 downto 0) & '0';
                                        qtr_phase <= 0;
                                    end if;
                                when others =>
                                    qtr_phase <= 0;
                            end case;
                        end if;

                    -------------------------------------------------------
                    -- RECV_ACK: release SDA, clock once to read ACK
                    -- We don't actually check ACK (fire-and-forget init),
                    -- but we do the clock cycle properly.
                    -------------------------------------------------------
                    when S_RECV_ACK =>
                        if qtr_tick = '1' then
                            case qtr_phase is
                                when 0 =>
                                    sda_drv   <= '1';  -- Release SDA for ACK
                                    scl_drv   <= '0';
                                    qtr_phase <= 1;
                                when 1 =>
                                    scl_drv   <= '1';  -- SCL high (slave drives ACK)
                                    qtr_phase <= 2;
                                when 2 =>
                                    qtr_phase <= 3;
                                when 3 =>
                                    scl_drv <= '0';    -- SCL low
                                    qtr_phase <= 0;
                                    -- Decide what's next
                                    if byte_phase = 0 then
                                        -- Just sent slave addr, now send reg addr
                                        shift_reg  <= REG_TABLE(reg_idx).addr;
                                        byte_phase <= 1;
                                        bit_cnt    <= 0;
                                        state      <= S_SEND_BYTE;
                                    elsif byte_phase = 1 then
                                        -- Just sent reg addr, now send data
                                        shift_reg  <= REG_TABLE(reg_idx).data;
                                        byte_phase <= 2;
                                        bit_cnt    <= 0;
                                        state      <= S_SEND_BYTE;
                                    else
                                        -- All 3 bytes sent, generate STOP
                                        state <= S_STOP;
                                    end if;
                                when others =>
                                    qtr_phase <= 0;
                            end case;
                        end if;

                    -------------------------------------------------------
                    -- STOP: SDA goes high while SCL is high
                    -- Phase 0: ensure SDA=0, SCL=0
                    -- Phase 1: SCL goes high
                    -- Phase 2: SDA goes high (STOP condition)
                    -------------------------------------------------------
                    when S_STOP =>
                        if qtr_tick = '1' then
                            case qtr_phase is
                                when 0 =>
                                    sda_drv   <= '0';
                                    scl_drv   <= '0';
                                    qtr_phase <= 1;
                                when 1 =>
                                    scl_drv   <= '1';  -- SCL high
                                    qtr_phase <= 2;
                                when 2 =>
                                    sda_drv   <= '1';  -- STOP: SDA rises while SCL high
                                    qtr_phase <= 0;
                                    reg_idx   <= reg_idx + 1;
                                    state     <= S_IDLE;
                                when others =>
                                    qtr_phase <= 0;
                            end case;
                        end if;

                    -------------------------------------------------------
                    -- DONE: all init complete
                    -------------------------------------------------------
                    when S_DONE =>
                        done    <= '1';
                        scl_drv <= '1';
                        sda_drv <= '1';

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
