connect
after 3000
puts "Targets before:"
targets
catch {targets 1; rst -system}
after 5000
puts "Targets after reset:"
targets
