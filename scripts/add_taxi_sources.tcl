# Add only the local dependency closure of taxi_eth_mac_mii_fifo.f.
# This script never accesses the network and never removes project files.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set lib_root [file normalize [file join $project_root prg_cam.srcs sources_1 lib]]
set entry_f [file normalize [file join $lib_root taxi-master eth rtl taxi_eth_mac_mii_fifo.f]]
set manifest_file [file normalize [file join $project_root docs taxi_compile_manifest.txt]]
set compile_order_report [file normalize [file join $project_root docs taxi_compile_order.rpt]]
set unresolved_report [file normalize [file join $project_root docs taxi_unresolved_references.rpt]]

if {![file isdirectory $lib_root]} {
    error "Local Taxi root does not exist: $lib_root"
}
if {![file exists $entry_f]} {
    error "Preferred Taxi entry does not exist: $entry_f"
}

set resolved_rtl {}
set resolved_filelists {}
set remaps {}
set missing {}
array set seen_rtl {}
array set seen_f {}

proc taxi_find_by_basename {dir basename} {
    set matches {}
    foreach item [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $item]} {
            set matches [concat $matches [taxi_find_by_basename $item $basename]]
        } elseif {[string equal -nocase [file tail $item] $basename]} {
            lappend matches [file normalize $item]
        }
    }
    return $matches
}

proc taxi_resolve_token {token base_dir lib_root} {
    set direct [file join $base_dir $token]
    if {[file exists $direct] && ![file isdirectory $direct]} {
        return [list resolved [file normalize $direct] ""]
    }

    set basename [file tail $token]
    set matches [lsort -unique [taxi_find_by_basename $lib_root $basename]]
    if {[llength $matches] == 1} {
        return [list remapped [lindex $matches 0] $direct]
    }
    if {[llength $matches] > 1} {
        return [list ambiguous $matches $direct]
    }
    return [list missing $token $direct]
}

proc taxi_parse_filelist {f_path lib_root} {
    global resolved_rtl resolved_filelists remaps missing seen_rtl seen_f

    set f_path [file normalize $f_path]
    if {[info exists seen_f($f_path)]} {
        return
    }
    set seen_f($f_path) 1
    lappend resolved_filelists $f_path

    set fh [open $f_path r]
    set content [read $fh]
    close $fh

    set base_dir [file dirname $f_path]
    foreach raw_line [split $content "\n"] {
        regsub {//.*$} $raw_line "" line
        regsub {#.*$} $line "" line
        set line [string trim $line]
        if {$line eq ""} {
            continue
        }

        foreach token [split $line] {
            set token [string trim $token " \t\r\n\"{}"]
            if {$token eq ""} {
                continue
            }
            if {[string match "+incdir+*" $token] || [string match "-*" $token]} {
                lappend missing [list unsupported_option $token $f_path]
                continue
            }

            lassign [taxi_resolve_token $token $base_dir $lib_root] status value attempted
            if {$status eq "missing"} {
                lappend missing [list missing $token $f_path $attempted]
                continue
            }
            if {$status eq "ambiguous"} {
                lappend missing [list ambiguous $token $f_path $value]
                continue
            }
            if {$status eq "remapped"} {
                lappend remaps [list $token $f_path $value]
            }

            set ext [string tolower [file extension $value]]
            if {$ext eq ".f"} {
                taxi_parse_filelist $value $lib_root
            } elseif {$ext in {".sv" ".v" ".vh" ".svh"}} {
                if {![info exists seen_rtl($value)]} {
                    set seen_rtl($value) 1
                    lappend resolved_rtl $value
                }
            } else {
                lappend missing [list unsupported_file $token $f_path $value]
            }
        }
    }
}

proc taxi_relative {path root} {
    set path [string map {\\ /} [file normalize $path]]
    set root [string trimright [string map {\\ /} [file normalize $root]] /]
    if {[string first "$root/" $path] == 0} {
        return [string range $path [expr {[string length $root] + 1}] end]
    }
    return $path
}

proc taxi_scan_definitions {files} {
    array set providers {}
    foreach path [lsort -unique $files] {
        if {![file exists $path] || [file isdirectory $path]} {
            continue
        }
        set ext [string tolower [file extension $path]]
        if {$ext ni {".sv" ".v"}} {
            continue
        }
        set fh [open $path r]
        set text [read $fh]
        close $fh
        set matches [regexp -all -inline -line {^[ \t]*(?:module|interface)[ \t]+([A-Za-z_][A-Za-z0-9_$]*)} $text]
        for {set i 1} {$i < [llength $matches]} {incr i 2} {
            set name [lindex $matches $i]
            if {![info exists providers($name)]} {
                set providers($name) {}
            }
            lappend providers($name) [file normalize $path]
        }
    }

    set duplicates {}
    foreach name [lsort [array names providers]] {
        set paths [lsort -unique $providers($name)]
        if {[llength $paths] > 1} {
            lappend duplicates [list $name $paths]
        }
    }
    return $duplicates
}

taxi_parse_filelist $entry_f $lib_root
set resolved_rtl [lsort -unique $resolved_rtl]
set resolved_filelists [lsort -unique $resolved_filelists]
set remaps [lsort -unique $remaps]
set missing [lsort -unique $missing]

file mkdir [file dirname $manifest_file]
set mf [open $manifest_file w]
puts $mf "Taxi local compile manifest"
puts $mf "entry=[taxi_relative $entry_f $project_root]"
puts $mf "lib_root=[string map {\\ /} $lib_root]"
puts $mf ""
puts $mf "FILELISTS ([llength $resolved_filelists])"
foreach path $resolved_filelists {
    puts $mf [taxi_relative $path $project_root]
}
puts $mf ""
puts $mf "RTL ([llength $resolved_rtl])"
foreach path $resolved_rtl {
    puts $mf [taxi_relative $path $project_root]
}
puts $mf ""
puts $mf "REMAPS ([llength $remaps])"
foreach item $remaps {
    puts $mf $item
}
puts $mf ""
puts $mf "MISSING_OR_AMBIGUOUS ([llength $missing])"
foreach item $missing {
    puts $mf $item
}
close $mf

puts "TAXI_ENTRY: [string map {\\ /} $entry_f]"
puts "TAXI_RESOLVED_FILELIST_COUNT: [llength $resolved_filelists]"
puts "TAXI_RESOLVED_RTL_COUNT: [llength $resolved_rtl]"
foreach path $resolved_rtl {
    puts "TAXI_RTL: [string map {\\ /} $path]"
}
foreach item $remaps {
    puts "TAXI_REMAP: $item"
}
foreach item $missing {
    puts "TAXI_MISSING: $item"
}

# Resolve everything before touching the Vivado project.  A partial dependency
# closure is never added, as it would leave misleading project state behind.
if {[llength $missing] != 0} {
    error "Taxi dependency resolution failed; see $manifest_file"
}

set project_xpr [file join $project_root prg_cam.xpr]
if {[llength [get_projects -quiet]] == 0} {
    open_project $project_xpr
}

# Check collisions between the resolved Taxi closure and the current active
# synthesis order before adding Taxi.  Auto-disabled legacy sources are not in
# the active compile order and therefore do not create false positives here.
set active_files [get_files -quiet -compile_order sources -used_in synthesis]
set duplicate_defs [taxi_scan_definitions [concat $active_files $resolved_rtl]]
if {[llength $duplicate_defs] != 0} {
    foreach item $duplicate_defs {
        puts "TAXI_DUPLICATE_DEFINITION: $item"
    }
    error "Duplicate module/interface definitions detected; no Taxi files added"
}

set to_add {}
foreach path $resolved_rtl {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] $path]] == 0} {
        lappend to_add $path
    }
}
if {[llength $to_add] != 0} {
    add_files -fileset sources_1 -norecurse $to_add
}

set sv_files {}
foreach path $resolved_rtl {
    if {[string equal -nocase [file extension $path] ".sv"]} {
        lappend sv_files $path
    }
}
if {[llength $sv_files] != 0} {
    set_property file_type SystemVerilog [get_files $sv_files]
}

update_compile_order -fileset sources_1
report_compile_order -of_objects [get_filesets sources_1] -used_in synthesis -file $compile_order_report
report_compile_order -of_objects [get_filesets sources_1] -used_in synthesis -missing_instances -file $unresolved_report

set ur [open $unresolved_report r]
set unresolved_text [read $ur]
close $ur
if {![regexp -nocase {<\s*empty\s*>} $unresolved_text]} {
    error "Unresolved references reported; see $unresolved_report"
}

puts "TAXI_SOURCE_ADD_PASS: [llength $resolved_rtl] unique RTL files"
puts "TAXI_COMPILE_MANIFEST: [string map {\\ /} $manifest_file]"
