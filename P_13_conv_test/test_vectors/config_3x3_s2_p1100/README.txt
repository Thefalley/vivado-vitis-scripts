Configuration: k3x3_s2_p1100
Directory: config_3x3_s2_p1100

Kernel: 3x3
Stride: 2
Pads: [1, 1, 0, 0]
Group: 1

Total layers with this config: 7
Conv indices: [1, 8, 17, 38, 60, 92, 101]

Channel dimensions across layers:
  [  1] conv2d_1/Conv2D_quant                    c_in= 32 c_out= 64
  [  8] conv2d_8/Conv2D_quant                    c_in= 64 c_out=128
  [ 17] conv2d_17/Conv2D_quant                   c_in=128 c_out=256
  [ 38] conv2d_38/Conv2D_quant                   c_in=256 c_out=512
  [ 60] conv2d_59/Conv2D_quant                   c_in=512 c_out=1024
  [ 92] conv2d_94/Conv2D_quant                   c_in=128 c_out=256
  [101] conv2d_102/Conv2D_quant                  c_in=256 c_out=512
