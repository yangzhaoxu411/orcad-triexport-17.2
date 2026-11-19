# Read-only Capture adapters: exact signatures, pointer ownership and failures.
set base [file normalize [file join [file dirname [info script]] ..]]
source -encoding utf-8 [file join $base src TriExport.tcl]
package require json
set assertions 0
proc check {expression message} {
    if {![uplevel 1 [list expr $expression]]} {error "FAIL: $message"}
    incr ::assertions
}
set allocated {}
set nextId 0
set failPart 0
set failColor 0
set missingProperty 0
set propertyError 1021
set colorCalls 0
set propertyCalls 0
proc DboState {} {
    set id state[incr ::nextId]
    dict set ::allocated $id 1
    interp alias {} $id {} stateCall $id
    return $id
}
proc stateCall {id method} {
    if {$method eq "OK"} {return [dict get $::allocated $id]}
    if {$method eq "Code"} {return $::propertyError}
    if {$method eq "-delete"} {dict unset ::allocated $id; rename $id {}; return}
    error "Unknown state method"
}
proc DboTclHelper_sMakeCString {{value {}}} {
    set id string[incr ::nextId]
    dict set ::allocated $id $value
    return $id
}
proc DboTclHelper_sGetConstCharPtr {id} {return [dict get $::allocated $id]}
proc DboTclHelper_sDeleteCString {id} {dict unset ::allocated $id}
proc occurrence {method args} {
    switch -- $method {
        GetPartInst {
            check {[llength $args] == 1} "GetPartInst receives a DboState"
            if {$::failPart} {return NULL}
            return part
        }
        GetEffectivePropStringValueNC {
            incr ::propertyCalls
            check {[llength $args] == 2} "property lookup uses CString name and value"
            set name [DboTclHelper_sGetConstCharPtr [lindex $args 0]]
            check {$name eq "Assembly [format %c 91]x[format %c 93]"} "property names are passed literally"
            set state [DboState]
            if {$::missingProperty} {dict set ::allocated $state 0; return $state}
            dict set ::allocated [lindex $args 1] "Not fitted; [format %c 91]literal[format %c 93]"
            return $state
        }
        default {error "Unexpected occurrence method: $method"}
    }
}
proc part {method state} {
    check {$method eq "GetColor"} "part color uses inherited GetColor"
    incr ::colorCalls
    if {$::failColor} {dict set ::allocated $state 0}
    return 48
}
set color [dict create action exclude field color property {} op equals value 48]
set prop [dict create action exclude field property property {Assembly [x]} op equals value {Not fitted; [literal]}]
set filter [dict create enabled 1 include_match any rules [list $color $color $prop $prop]]
set row [::TriExport::captureFilterValues occurrence [dict create ref U1] $filter]
check {[dict get $row color] eq "48"} "stored color ID is preserved"
check {[dict get $row filter_values {Assembly [x]}] eq {Not fitted; [literal]}} "custom value remains literal data"
check {$colorCalls == 1 && $propertyCalls == 1} "each requested field is read once per unit"
check {[dict size $allocated] == 0} "all state and CString allocations released"
set decoded [::json::json2dict [::TriExport::jobJson {} {} {} [list $row] $filter]]
check {[dict get $decoded bom_filter enabled] eq "true"} "enabled serialized as JSON boolean"
check {[dict get [lindex [dict get $decoded bom_rows] 0] filter_values {Assembly [x]}] eq {Not fitted; [literal]}} "nested property JSON round trips"
set missingProperty 1
check {[::TriExport::filterProperty occurrence {Assembly [x]}] eq ""} "missing property is an empty value"
check {[dict size $allocated] == 0} "missing-property resources released"
set propertyError 9999
check {[catch {::TriExport::filterProperty occurrence {Assembly [x]}} message] && [string match {*Capture error 9999*} $message]} "actual property errors abort instead of matching empty"
check {[dict size $allocated] == 0} "failed-property resources released"
set failPart 1
check {[catch {::TriExport::partColor occurrence} message] && [string match {*schematic part*} $message]} "missing part aborts color read"
check {[dict size $allocated] == 0} "missing-part state released"
set failPart 0
set failColor 1
check {[catch {::TriExport::partColor occurrence} message] && [string match {*stored part color*} $message]} "failed color state aborts export"
check {[dict size $allocated] == 0} "failed-color state released"
set disabled [dict replace $filter enabled 0]
check {[::TriExport::captureFilterValues invalidPointer [dict create ref U1] $disabled] eq {ref U1}} "disabled rules never query native objects"
foreach bad [list [dict replace $color value red] [dict replace $color op contains] [dict replace $prop property {}] [dict replace $prop op script]] {
    check {[catch {::TriExport::validateBomFilter [dict create enabled 1 include_match any rules [list $bad]]}]} "invalid rule rejected"
}
puts "PASS: $assertions BOM Capture adapter assertions; no native CAD or GUI used."
