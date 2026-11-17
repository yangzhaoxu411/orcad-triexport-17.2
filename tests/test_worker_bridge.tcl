# Exercise the frozen helper from Tcl, without loading native Capture APIs.
set base [file normalize [file join [file dirname [info script]] ..]]
source -encoding utf-8 [file join $base src TriExport.tcl]
package require json
if {![llength $argv]} { error "Provide the compiled TriExportWorker.exe path" }
set exe [file normalize [lindex $argv 0]]
set scratch [file join $base .work worker-bridge-test]
file mkdir $scratch
set ::env(TEMP) $scratch
set ::env(TMP) $scratch
set design [file join $scratch "中文 空格.dsn"]
::TriExport::writeUtf8 $design "synthetic bytes, not a DSN file"
set hash [file join $scratch digest.txt]
file delete -force $hash
exec $exe hash $design --output $hash
if {![regexp {^[0-9a-f]{64}$} [::TriExport::readUtf8 $hash]]} { error "Hash subprocess failed" }
if {[file exists "$design.sha256"]} { error "Unexpected sidecar next to source" }
set ::TriExport::jobDir $scratch
set job [file join $scratch job.json]
::TriExport::writeUtf8 $job "\{\}"
file delete -force [file join $scratch result.json]
set ::TriExport::workerChannel [open [list | $exe run $job 2>@1] r]
fconfigure $::TriExport::workerChannel -blocking 0 -encoding utf-8
set done 0
fileevent $::TriExport::workerChannel readable {
    ::TriExport::workerReadable
    if {$::TriExport::workerChannel eq ""} {set ::done 1}
}
set watchdog [after 15000 {set ::done timeout}]
vwait done
after cancel $watchdog
if {$done ne "1"} { error "Worker bridge timed out" }
set result [::json::json2dict [::TriExport::readUtf8 [file join $scratch result.json]]]
if {[dict get $result ok]} { error "Invalid manifest unexpectedly succeeded" }
puts "PASS: compiled helper hash, Unicode path, async pipe and failure result; no Capture launched."
