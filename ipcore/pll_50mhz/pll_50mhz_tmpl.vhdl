-- Created by IP Generator (Version 2025.2 build 211867)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT pll_50mhz
  PORT (
    clkin1 : IN STD_LOGIC;  -- 50.0MHz
    pll_lock : OUT STD_LOGIC;
    clkout0 : OUT STD_LOGIC;  -- 50.0MHz
    clkout1 : OUT STD_LOGIC  -- 14.743589743589743MHz
  );
END COMPONENT;


the_instance_name : pll_50mhz
  PORT MAP (
    clkin1 => clkin1,
    pll_lock => pll_lock,
    clkout0 => clkout0,
    clkout1 => clkout1
  );
