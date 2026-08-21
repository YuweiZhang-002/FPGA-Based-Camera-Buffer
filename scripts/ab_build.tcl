# Reproducible plain-vs-ILA build orchestrator.
#
# Run from the project root:
#   vivado.bat -mode batch -nolog -nojournal -source scripts/ab_build.tcl
#
# Both builds consume the same sources_1/constrs_1 snapshot.  Source hashes are
# recorded before and after the builds; a changed snapshot fails the run.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set run_id [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
if {[info exists ::env(AB_RUN_ID)] && $::env(AB_RUN_ID) ne ""} {
    set run_id $::env(AB_RUN_ID)
}
set output_dir [file normalize [file join $project_root build ab_build $run_id]]
set plain_dir [file join $output_dir plain]
set ila_dir [file join $output_dir ila]
file mkdir $plain_dir
file mkdir $ila_dir

proc walk_source_files {root} {
    set result {}
    foreach item [glob -nocomplain -directory $root * .*] {
        set tail [file tail $item]
        if {$tail in {. ..}} {
            continue
        }
        set normalized [file normalize $item]
        if {[file isdirectory $normalized]} {
            if {$tail in {__pycache__ .git .Xil}} {
                continue
            }
            set result [concat $result [walk_source_files $normalized]]
        } elseif {![string match -nocase "*.pyc" $normalized]} {
            lappend result $normalized
        }
    }
    return [lsort -dictionary -unique $result]
}

proc sha256_file {path} {
    # Windows certutil in this Vivado environment returns ERROR_FILE_INVALID
    # for a zero-byte file.  Use the standard SHA-256 digest of the empty
    # string instead of treating an empty Python package marker as a build
    # snapshot failure.
    if {[file size $path] == 0} {
        return "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
    }
    set output [exec certutil -hashfile $path SHA256]
    if {![regexp -nocase {[0-9a-f]{64}} $output digest]} {
        error "Unable to parse SHA-256 for $path"
    }
    return [string toupper $digest]
}

proc csv_quote {value} {
    return "\"[string map [list "\"" "\"\""] $value]\""
}

proc write_source_manifest {project_root destination} {
    set roots [list \
        [file join $project_root prg_cam.srcs sources_1] \
        [file join $project_root prg_cam.srcs constrs_1]]
    set handle [open $destination w]
    puts $handle "relative_path,size_bytes,sha256"
    foreach root $roots {
        foreach path [walk_source_files $root] {
            set relative [string map {"\\" "/"} \
                [file join [file tail $root] \
                    [string range $path [expr {[string length $root] + 1}] end]]]
            set size [file size $path]
            puts $handle "[csv_quote $relative],$size,[sha256_file $path]"
        }
    }
    close $handle
}

proc copy_if_exists {source destination_dir} {
    if {[file exists $source]} {
        file copy -force $source [file join $destination_dir [file tail $source]]
    }
}

proc run_child_vivado {vivado project_root script_name log_file} {
    set script_path [file normalize [file join $project_root scripts $script_name]]
    puts "AB_BUILD_START script=$script_path"
    set command [list $vivado -mode batch -nolog -nojournal -source $script_path]
    set status [catch {exec {*}$command >$log_file 2>@1} result options]
    if {$status != 0} {
        puts stderr $result
        return -options $options \
            "Child Vivado build failed: $script_name; see $log_file"
    }
    puts "AB_BUILD_DONE script=$script_path"
}

set pre_manifest [file join $output_dir source_manifest_before.csv]
set post_manifest [file join $output_dir source_manifest_after.csv]
write_source_manifest $project_root $pre_manifest

set metadata [open [file join $output_dir build_metadata.txt] w]
puts $metadata "run_id=$run_id"
puts $metadata "vivado=[version -short]"
puts $metadata "part=xc7a50ticsg324-1L"
puts $metadata "top=Camera_Ethernet_Top"
puts $metadata "srcset=sources_1"
puts $metadata "constrset=constrs_1"
if {![catch {exec git -C $project_root rev-parse HEAD} git_head]} {
    puts $metadata "git_head=[string trim $git_head]"
}
if {![catch {exec git -C $project_root branch --show-current} git_branch]} {
    puts $metadata "git_branch=[string trim $git_branch]"
}
close $metadata

set vivado [info nameofexecutable]

run_child_vivado $vivado $project_root rebuild_gui_ethernet.tcl \
    [file join $plain_dir build.log]
foreach path [list \
    [file join $project_root build gui_ethernet_rebuild Camera_Ethernet_Top.bit] \
    [file join $project_root build gui_ethernet_rebuild Camera_Ethernet_Top_routed.dcp] \
    [file join $project_root build gui_ethernet_rebuild timing_summary.rpt] \
    [file join $project_root build gui_ethernet_rebuild drc.rpt] \
    [file join $project_root build gui_ethernet_rebuild cdc.rpt] \
    [file join $project_root build gui_ethernet_rebuild reset_exception_coverage.rpt]] {
    copy_if_exists $path $plain_dir
}

run_child_vivado $vivado $project_root build_ethernet_ila.tcl \
    [file join $ila_dir build.log]
foreach path [list \
    [file join $project_root build ethernet_ila Camera_Ethernet_Top_ila.bit] \
    [file join $project_root build ethernet_ila Camera_Ethernet_Top_ila.ltx] \
    [file join $project_root build ethernet_ila Camera_Ethernet_Top_ila_routed.dcp] \
    [file join $project_root build ethernet_ila timing_summary.rpt] \
    [file join $project_root build ethernet_ila drc.rpt] \
    [file join $project_root build ethernet_ila utilization.rpt]] {
    copy_if_exists $path $ila_dir
}

write_source_manifest $project_root $post_manifest

set before_handle [open $pre_manifest r]
set before_data [read $before_handle]
close $before_handle
set after_handle [open $post_manifest r]
set after_data [read $after_handle]
close $after_handle

set artifact_manifest [open [file join $output_dir artifact_manifest.csv] w]
puts $artifact_manifest "variant,relative_path,size_bytes,sha256"
foreach variant_dir [list $plain_dir $ila_dir] {
    set variant [file tail $variant_dir]
    foreach path [walk_source_files $variant_dir] {
        if {[file tail $path] eq "build.log"} {
            continue
        }
        set relative [string map {"\\" "/"} \
            [string range $path [expr {[string length $variant_dir] + 1}] end]]
        puts $artifact_manifest \
            "$variant,[csv_quote $relative],[file size $path],[sha256_file $path]"
    }
}
close $artifact_manifest

if {$before_data ne $after_data} {
    puts "SOURCE_SNAPSHOT_STABLE=FAIL"
    error "sources_1/constrs_1 changed during A/B build; manifests retained"
}

puts "SOURCE_SNAPSHOT_STABLE=PASS"
puts "AB_BUILD_RESULT=PASS"
puts "AB_BUILD_OUTPUT=$output_dir"
exit
