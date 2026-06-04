proc probe {tag} {
    puts "PROBE $tag led=[get_value /tb_myCPU/led] seg=[get_value /tb_myCPU/seg] cycles=[get_value /tb_myCPU/cnt_cycles] if_pc=[get_value /tb_myCPU/uut/student_top_inst/Core_cpu/IF_pc]"
}

run 1ms
probe 1ms
run 1ms
probe 2ms
run 1ms
probe 3ms
run 2ms
probe 5ms
run 5ms
probe 10ms
run 10ms
probe 20ms
quit
