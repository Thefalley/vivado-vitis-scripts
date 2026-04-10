# debug_read.tcl — Lee buffers src/dst de DDR para ver que valores fallaron
connect
after 2000
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}

set SRC_ADDR 0x01000000
set DST_ADDR 0x01100000

puts "\nLeyendo 256 resultados de DDR..."
set src_data [mrd -value $SRC_ADDR 256]
set dst_data [mrd -value $DST_ADDR 256]

# Tabla expected (full INT8 sweep, validada ONNX Runtime)
set expected {
    -128 -128 -128 -128 -128 -127 -127 -127 -127 -127
    -127 -126 -126 -126 -126 -126 -126 -125 -125 -125
    -125 -125 -125 -124 -124 -124 -124 -124 -124 -123
    -123 -123 -123 -123 -123 -122 -122 -122 -122 -122
    -122 -121 -121 -121 -121 -121 -121 -121 -120 -120
    -120 -120 -120 -120 -119 -119 -119 -119 -119 -119
    -118 -118 -118 -118 -118 -118 -117 -117 -117 -117
    -117 -117 -116 -116 -116 -116 -116 -116 -115 -115
    -115 -115 -115 -115 -114 -114 -114 -114 -114 -114
    -113 -113 -113 -113 -113 -113 -112 -112 -112 -112
    -112 -112 -111 -111 -111 -111 -111 -111 -110 -110
    -110 -110
    -108 -107 -105 -103 -102 -100  -99  -97  -95  -94
     -92  -90  -89  -87  -85  -84
     -82  -80  -79  -77  -76  -74  -72  -71  -69  -67
     -66  -64  -62  -61  -59  -57  -56  -54  -53  -51
     -49  -48  -46  -44  -43  -41  -39  -38  -36  -34
     -33  -31  -30  -28  -26  -25  -23  -21  -20  -18
     -16  -15  -13  -11  -10   -8   -7   -5   -3   -2
       0    2    3    5    7    8   10   12   13   15
      16   18   20   21   23   25   26   28   30   31
      33   35   36   38   39   41   43   44   46   48
      49   51   53   54   56   58   59   61   62   64
      66   67   69   71   72   74   76   77   79   81
      82   84   85   87   89   90   92   94   95   97
      99  100  102  103  105  107  108  110  112  113
     115  117  118  120  122  123  125  126
}

puts "\n  idx | x_in | got  | exp  | OK?"
puts "  ----+------+------+------+----"

set errors 0
for {set i 0} {$i < 256} {incr i} {
    set x [expr {$i - 128}]
    set raw [lindex $dst_data $i]
    # Interpretar como signed byte
    set got [expr {$raw > 127 ? $raw - 256 : $raw}]
    set exp [lindex $expected $i]

    if {$got != $exp} {
        incr errors
        puts [format "  %3d | %4d | %4d | %4d | FAIL" $i $x $got $exp]
    }
}

puts "\n  Errors: $errors / 256"
