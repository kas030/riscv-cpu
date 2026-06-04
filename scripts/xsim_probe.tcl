run 1ms
puts "PROBE led=[get_value /tb_myCPU/led]"
puts "PROBE cycles=[get_value /tb_myCPU/cnt_cycles]"
puts "PROBE if_pc=[get_value /tb_myCPU/uut/student_top_inst/Core_cpu/IF_pc]"
puts "PROBE branch_taken=[get_value /tb_myCPU/uut/student_top_inst/Core_cpu/BranchTaken]"
puts "PROBE branch_mispredict=[get_value /tb_myCPU/uut/student_top_inst/Core_cpu/BranchMispredict]"
quit
