@echo off
REM Simulacion directa con xvhdl + xelab + xsim
set VIVADO_DIR=C:\AMDDesignTools\2025.2\Vivado\bin
set SRC_DIR=%~dp0..\src
set SIM_DIR=%~dp0

echo === Compilando VHDL ===
"%VIVADO_DIR%\xvhdl.bat" "%SRC_DIR%\mult_4dsp.vhd" || exit /b 1
"%VIVADO_DIR%\xvhdl.bat" "%SRC_DIR%\mult_2dsp.vhd" || exit /b 1
"%VIVADO_DIR%\xvhdl.bat" "%SRC_DIR%\mult_1dsp.vhd" || exit /b 1
"%VIVADO_DIR%\xvhdl.bat" "%SIM_DIR%\mult_tb.vhd" || exit /b 1

echo === Elaborando ===
"%VIVADO_DIR%\xelab.bat" mult_tb -debug typical -s mult_sim || exit /b 1

echo === Simulando ===
"%VIVADO_DIR%\xsim.bat" mult_sim -runall || exit /b 1

echo === DONE ===
