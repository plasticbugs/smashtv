# Every failing setup path on the machine clock, one line each, so they can be
# grouped by where they start and end (the top 200 are usually one bus):
#   docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build \
#       raetro/quartus:pocket quartus_sta -t projects/report_failing.tcl
# then  tools/group_paths.py projects/output_files/failing_paths.txt
cd projects
if {[catch {project_open smashtv_pocket -revision smashtv_pocket} err]} {
    puts "PROJECT OPEN FAILED: $err"; exit 1
}
create_timing_netlist -model slow
read_sdc
update_timing_netlist
# SKIP: a register pattern to leave out as a destination, for when one bus's
# thousands of paths hide everything else (set it with `-tclargs`? no: edit
# here).  Empty means nothing is left out.
set skip {*|stv_sound:u_snd|snd[*]*}
set all_to [all_registers]
if {$skip ne ""} { set all_to [remove_from_collection $all_to [get_registers $skip]] }
report_timing -setup -npaths 20000 -less_than_slack 0 -detail summary -to $all_to \
    -file output_files/failing_paths.txt
delete_timing_netlist
project_close
