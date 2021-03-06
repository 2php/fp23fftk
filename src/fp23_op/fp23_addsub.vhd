-------------------------------------------------------------------------------
--
-- Title       : fp23_addsub
-- Design      : FFT
-- Author      : Kapitanov Alexander
-- Company     : 
-- E-mail      : sallador@bk.ru
--
-------------------------------------------------------------------------------
--
-- Description : floating point adder/subtractor
--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--
--	The MIT License (MIT)
--	Copyright (c) 2016 Kapitanov Alexander 													 
--		                                          				 
-- Permission is hereby granted, free of charge, to any person obtaining a copy 
-- of this software and associated documentation files (the "Software"), 
-- to deal in the Software without restriction, including without limitation 
-- the rights to use, copy, modify, merge, publish, distribute, sublicense, 
-- and/or sell copies of the Software, and to permit persons to whom the 
-- Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in 
-- all copies or substantial portions of the Software.
--
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
-- THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS 
-- IN THE SOFTWARE.
--                                        
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library work;
use work.reduce_pack.or_reduce;
use work.fp_m1_pkg.fp23_data;

library unisim;
use unisim.vcomponents.DSP48E1;
use unisim.vcomponents.DSP48E2;

entity fp23_addsub is
	generic (
		USE_MLT : boolean:=FALSE;   --! Use DSP48E1/2 blocks or not
		XSERIES : string:="7SERIES" --! Xilinx series: ULTRA / 7SERIES
	);	
	port (
		aa 		: in  fp23_data;	--! Summand/Minuend A   
		bb 		: in  fp23_data;	--! Summand/Substrahend B     
		cc 		: out fp23_data;	--! Sum/Dif C        
		addsub	: in  std_logic;	--! '0' - Add, '1' - Sub
		reset	: in  std_logic;	--! '0' - Reset
		enable 	: in  std_logic;	--! Input data enable
		valid	: out std_logic;	--! Output data valid          
		clk 	: in  std_logic		--! Clock	         
	);
end fp23_addsub;

architecture fp23_addsub of fp23_addsub is 

type std_logic_array_5xn is array (5 downto 0) of std_logic_vector(5 downto 0);

signal aa_z			   	: fp23_data;	  
signal bb_z				: fp23_data;
signal comp				: std_logic_vector(22 downto 0); 

signal muxa             : fp23_data;
signal muxb             : fp23_data;

signal exp_dif			: std_logic_vector(5 downto 0);

signal impl_a			: std_logic;
signal impl_b			: std_logic; 

signal msb_dec			: std_logic_vector(15 downto 0);
signal man_az			: std_logic_vector(16 downto 0);
signal subtract         : std_logic;

signal msb_num			: std_logic_vector(4 downto 0);

signal expc				: std_logic_vector(5 downto 0);
signal frac           	: std_logic_vector(15 downto 0);

signal set_zero			: std_logic;

signal expaz			: std_logic_array_5xn;
signal sign_c			: std_logic_vector(5 downto 0);

signal dout_val_v		: std_logic_vector(7 downto 0);

signal exp_a0			: std_logic;
signal exp_b0			: std_logic;
signal exp_ab			: std_logic;
signal exp_zz			: std_logic_vector(5 downto 0);

signal new_man			: std_logic_vector(15 downto 0);

begin	

-- add or sub operation --
aa_z <= aa when rising_edge(clk);
pr_addsub: process(clk) is
begin
	if rising_edge(clk) then
		if (addsub = '0') then
			bb_z <= bb;
		else
			bb_z <= (bb.exp, not bb.sig, bb.man);
		end if;
	end if;
end process;

exp_a0 <= or_reduce(aa.exp) when rising_edge(clk);
exp_b0 <= or_reduce(bb.exp) when rising_edge(clk);

exp_ab <= not (exp_a0 or exp_b0) when rising_edge(clk);
exp_zz <= exp_zz(exp_zz'left-1 downto 0) & exp_ab when rising_edge(clk);

-- check difference (least/most attribute) --

pr_ex: process(clk) is
begin
	if rising_edge(clk) then
		comp <= ('0' & aa.exp & aa.man) - ('0' & bb.exp & bb.man);
	end if;
end process; 

---- data switch multiplexer --
pr_mux: process(clk) is
begin
	if rising_edge(clk) then
		if (comp(22) = '1') then
			muxa <= bb_z;
			muxb <= aa_z; 
		else
			muxa <= aa_z;
			muxb <= bb_z;
		end if;
	end if;
end process;

---- implied '1' for fraction --
pr_imp: process(clk) is
begin
	if rising_edge(clk) then
		if (comp(22) = '1') then
			impl_a <= exp_b0;
			impl_b <= exp_a0; 
		else
			impl_a <= exp_a0;
			impl_b <= exp_b0;
		end if;
	end if;
end process;

---- Find exponent ----
pr_dif: process(clk) is
begin
	if rising_edge(clk) then 
		exp_dif <= muxa.exp - muxb.exp;
		subtract <= muxa.sig xor muxb.sig;
	end if;
end process;

man_az <= impl_a & muxa.man when rising_edge(clk);	


xUSE_DSP48: if (USE_MLT = TRUE) generate

	constant CONST_ONE		: std_logic_vector(15 downto 0):=x"8000";
	
	signal dsp_aa			: std_logic_vector(29 downto 0);
	signal dsp_bb			: std_logic_vector(17 downto 0);
	signal dsp_cc			: std_logic_vector(47 downto 0);
	signal sum_man			: std_logic_vector(47 downto 0);
	
	signal shift_man		: std_logic_vector(15 downto 0);
	signal alu_mode			: std_logic_vector(3 downto 0):=x"0";	

	signal dsp_mlt			: std_logic;
	signal dsp_res			: std_logic;
begin
	
	pr_mlt: process(clk) is
	begin
		if rising_edge(clk) then
			if (exp_dif(5 downto 4) = "00") then
				dsp_res <= '0';
			else
				dsp_res <= '1';
			end if;
		end if;
	end process;
	
	---- Shift vector for fraction ----
	shift_man <= STD_LOGIC_VECTOR(SHR(UNSIGNED(CONST_ONE), UNSIGNED(exp_dif(4 downto 0)))) when rising_edge(clk);	

	pr_manz: process(clk) is
	begin
		if rising_edge(clk) then 
			alu_mode <= "00" & subtract & subtract;
		end if;
	end process;

	---- Find fraction by using DSP48 ----
	dsp_aa(16 downto 00) <= impl_b & muxb.man;
	dsp_aa(29 downto 17) <= (others=>'0');
	dsp_bb <= "00" & shift_man;

	dsp_cc(14 downto 00) <= (others =>'0');
	dsp_cc(31 downto 15) <= man_az when rising_edge(clk);
	dsp_cc(47 downto 32) <= (others =>'0');

	xDSP48E1: if (XSERIES = "7SERIES") generate
		align_add: DSP48E1
			generic map (
				ALUMODEREG		=> 1,
				ADREG			=> 0,
				AREG			=> 2,
				BCASCREG		=> 0,
				BREG			=> 0,
				CREG			=> 1,
				DREG			=> 0,
				MREG			=> 1,
				PREG			=> 1
			)		
			port map (     
				P               => sum_man, 
				A               => dsp_aa,
				ACIN			=> (others=>'0'),
				ALUMODE			=> alu_mode,
				B               => dsp_bb, 
				BCIN            => (others=>'0'), 
				C               => dsp_cc,
				CARRYCASCIN		=> '0',
				CARRYIN         => '0', 
				CARRYINSEL      => (others=>'0'),
				CEA1            => '1',
				CEA2            => '1',
				CEAD            => '1',
				CEALUMODE       => '1',
				CEB1            => '1',
				CEB2            => '1',
				CEC             => '1',
				CECARRYIN       => '1',
				CECTRL          => '1',
				CED				=> '1',
				CEINMODE		=> '1',
				CEM             => '1',
				CEP             => '1',
				CLK             => clk,
				D               => (others=>'0'),
				INMODE			=> "00000",
				MULTSIGNIN		=> '0',
				OPMODE          => "0110101",
				PCIN            => (others=>'0'),
				RSTA            => reset,
				RSTALLCARRYIN	=> reset,
				RSTALUMODE   	=> reset,
				RSTB            => reset,
				RSTC            => reset,
				RSTCTRL         => reset,
				RSTD			=> reset,
				RSTINMODE		=> reset,
				RSTM            => dsp_res,
				RSTP            => reset 
			);
	end generate;

	xDSP48E2: if (XSERIES = "ULTRA") generate
		align_add: DSP48E2
			generic map (
				ALUMODEREG		=> 1,
				ADREG			=> 0,
				AREG			=> 2,
				BCASCREG		=> 0,
				BREG			=> 0,
				CREG			=> 1,
				DREG			=> 0,
				MREG			=> 1,
				PREG			=> 1
			)		
			port map (     
				P               => sum_man, 
				A               => dsp_aa,
				ACIN			=> (others=>'0'),
				ALUMODE			=> alu_mode,
				B               => dsp_bb, 
				BCIN            => (others=>'0'), 
				C               => dsp_cc,
				CARRYCASCIN		=> '0',
				CARRYIN         => '0', 
				CARRYINSEL      => (others=>'0'),
				CEA1            => '1',
				CEA2            => '1',
				CEAD            => '1',
				CEALUMODE       => '1',
				CEB1            => '1',
				CEB2            => '1',
				CEC             => '1',
				CECARRYIN       => '1',
				CECTRL          => '1',
				CED				=> '1',
				CEINMODE		=> '1',
				CEM             => '1',
				CEP             => '1',
				CLK             => clk,
				D               => (others=>'0'),
				INMODE			=> "00000",
				MULTSIGNIN		=> '0',
				OPMODE          => "000110101",
				PCIN            => (others=>'0'),
				RSTA            => reset,
				RSTALLCARRYIN	=> reset,
				RSTALUMODE   	=> reset,
				RSTB            => reset,
				RSTC            => reset,
				RSTCTRL         => reset,
				RSTD			=> reset,
				RSTINMODE		=> reset,
				RSTM            => dsp_res,
				RSTP            => reset 
			);
	end generate;
	
	msb_dec <= sum_man(32 downto 17);
	new_man <= sum_man(31 downto 16) when rising_edge(clk);
	
end generate;

xUSE_LOGIC: if (USE_MLT = FALSE) generate

	signal norm_man			: std_logic_vector(16 downto 0);
	signal diff_man			: std_logic_vector(16 downto 0);
	signal diff_exp			: std_logic_vector(1 downto 0);
	signal add1				: std_logic;
	signal add2				: std_logic;
	
	signal sum_mt			: std_logic_vector(17 downto 0);
	signal man_shift		: std_logic_vector(16 downto 0);
	
	signal man_az1			: std_logic_vector(16 downto 0);
	signal man_az2			: std_logic_vector(16 downto 0);

begin

	man_shift <= impl_b & muxb.man when rising_edge(clk);
	norm_man <= STD_LOGIC_VECTOR(SHR(UNSIGNED(man_shift), UNSIGNED(exp_dif(3 downto 0)))) when rising_edge(clk);	

	diff_exp <= exp_dif(5 downto 4) when rising_edge(clk);

	pr_norm_man: process(clk) is
	begin
		if rising_edge(clk) then
			if (diff_exp = "00") then
				diff_man <= norm_man;
			else
				diff_man <= (others => '0');
			end if;
		end if;
	end process;

	add1 <= not subtract when rising_edge(clk); 
	add2 <= add1 when rising_edge(clk); 
	
	-- sum of fractions --
	pr_man: process(clk) is
	begin
		if rising_edge(clk) then
			man_az1 <= man_az;
			man_az2 <= man_az1;
			if (add2 = '1') then
				sum_mt <= ('0' & man_az2) + ('0' & diff_man);
			else
				sum_mt <= ('0' & man_az2) - ('0' & diff_man);
			end if;
		end if;
	end process;	
	
	msb_dec <= sum_mt(17 downto 2);
	new_man <= sum_mt(16 downto 1) when rising_edge(clk);
end generate;

---- find MSB (highest '1' position) ----
pr_align: process(clk) is 
begin
	if rising_edge(clk) then
		if    (msb_dec(15-00)='1') then msb_num <= "00000";
		elsif (msb_dec(15-01)='1') then msb_num <= "00001";
		elsif (msb_dec(15-02)='1') then msb_num <= "00010";
		elsif (msb_dec(15-03)='1') then msb_num <= "00011";
		elsif (msb_dec(15-04)='1') then msb_num <= "00100";
		elsif (msb_dec(15-05)='1') then msb_num <= "00101";
		elsif (msb_dec(15-06)='1') then msb_num <= "00110";
		elsif (msb_dec(15-07)='1') then msb_num <= "00111";
		elsif (msb_dec(15-08)='1') then msb_num <= "01000";
		elsif (msb_dec(15-09)='1') then msb_num <= "01001";
		elsif (msb_dec(15-10)='1') then msb_num <= "01010";
		elsif (msb_dec(15-11)='1') then msb_num <= "01011";
		elsif (msb_dec(15-12)='1') then msb_num <= "01100";
		elsif (msb_dec(15-13)='1') then msb_num <= "01101";
		elsif (msb_dec(15-14)='1') then msb_num <= "01110";
		elsif (msb_dec(15-15)='1') then msb_num <= "01111";
		else msb_num <= "11111";
		end if;
	end if;
end process;

frac <= STD_LOGIC_VECTOR(SHL(UNSIGNED(new_man), UNSIGNED(msb_num(4 downto 0)))) when rising_edge(clk);	

set_zero <= msb_num(4);

---- exponent increment ----	
pr_expx: process(clk) is
begin
	if rising_edge(clk) then 
		---- Set ones (error of rounding fp data ----
		if (set_zero = '0') then
			if (expaz(4) < ('0' & msb_num)) then
				expc <= "000000";
			else
				expc <= expaz(4) - msb_num + '1';
			end if;
		else
			expc <= "000000";
		end if;		
	end if;
end process;

---- exp & sign delay ----
pr_expz: process(clk) is
begin
	if rising_edge(clk) then
		expaz <= expaz(expaz'left-1 downto 0) & muxa.exp;
		sign_c <= sign_c(sign_c'left-1 downto 0) & muxa.sig;
	end if;
end process;

---- output product ----
pr_dout: process(clk) is
begin 		
	if rising_edge(clk) then
		if (exp_zz(exp_zz'left) = '1') then
			cc <= ("000000", '0', x"0000");
		else
			cc <= (expc, sign_c(sign_c'left), frac);
		end if;
	end if;
end process;

dout_val_v <= dout_val_v(dout_val_v'left-1 downto 0) & enable when rising_edge(clk);
valid <= dout_val_v(dout_val_v'left) when rising_edge(clk);

end fp23_addsub;