################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
LD_SRCS += \
../src/lscript.ld 

C_SRCS += \
../src/crc32.c \
../src/dpu_exec.c \
../src/dpu_exec_tiled.c \
../src/dpu_exec_v4.c \
../src/eth_server.c \
../src/main.c \
../src/mem_pool.c \
../src/platform_eth.c 

OBJS += \
./src/crc32.o \
./src/dpu_exec.o \
./src/dpu_exec_tiled.o \
./src/dpu_exec_v4.o \
./src/eth_server.o \
./src/main.o \
./src/mem_pool.o \
./src/platform_eth.o 

C_DEPS += \
./src/crc32.d \
./src/dpu_exec.d \
./src/dpu_exec_tiled.d \
./src/dpu_exec_v4.d \
./src/eth_server.d \
./src/main.d \
./src/mem_pool.d \
./src/platform_eth.d 


# Each subdirectory must supply rules for building sources it contributes
src/%.o: ../src/%.c
	@echo 'Building file: $<'
	@echo 'Invoking: ARM v7 gcc compiler'
	arm-none-eabi-gcc -Wall -O0 -g3 -c -fmessage-length=0 -MT"$@" -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -IC:/project/vivado/P_30_A/vitis_ws_new/dpu_platform/export/dpu_platform/sw/dpu_platform/standalone_domain/bspinclude/include -MMD -MP -MF"$(@:%.o=%.d)" -MT"$(@)" -o "$@" "$<"
	@echo 'Finished building: $<'
	@echo ' '


