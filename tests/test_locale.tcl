# Verify Unicode independently of the system code page, without showing windows.
set base [file normalize [file join [file dirname [info script]] ..]]
set assertions 0
proc check {expr message} {
    if {![uplevel 1 [list expr $expr]]} {error "FAIL: $message"}
    incr ::assertions
}
set savedEncoding [encoding system]
try {
    foreach codepage {cp936 cp1252 utf-8} {
        encoding system $codepage
        source [file join $base src TriExport.tcl]
        check {[::TriExport::tr {Export Files}] eq "\u5f00\u59cb\u5bfc\u51fa"} "Chinese label survives $codepage"
        check {[::TriExport::tr {3 / 31 pages selected}] eq "\u5df2\u9009\u62e9 3 / 31 \u9875"} "dynamic counts survive $codepage"
        check {[::TriExport::tr {Property: Color}] eq "\u5c5e\u6027\uff1aColor"} "CAD property name is preserved"
        set literal {R1 [error boom] $env(HOME) {0}}
        set translated [::TriExport::tr "Reference $literal was not found in the current design."]
        check {[string first $literal $translated] >= 0} "captures remain literal without Tcl execution or recursive substitution"
        check {[::TriExport::tr {Value}] eq "\u503c"} "display labels translated"
        check {[::TriExport::tr {unrecognized native detail}] eq {unrecognized native detail}} "unknown diagnostic remains intact"
        set result [::TriExport::displayError {unrecognized native detail}]
        check {[string first "\u9519\u8bef" $result] == 0 && [string match {*unrecognized native detail} $result]} "native errors have Chinese context and original detail"
        check {[string first "\u5df2\u5bfc\u51fa 2" [::TriExport::tr {Exported 2 PDF pages and 17 BOM components to three files.}]] == 0} "success text is translated with counts"
    }
} finally {encoding system $savedEncoding}
foreach name {TriExport.tcl WorkspaceUI.tcl BomFilters.tcl UiLocale.tcl ZhCN.tcl zzTriExport.tcl} {
    set f [open [file join $base src $name] rb];set raw [read $f];close $f
    check {![regexp {[^\x00-\x7f]} $raw]} "runtime $name is ASCII with escaped Unicode catalog"
}
set f [open [file join $base src zh_CN.json] r];fconfigure $f -encoding utf-8;set source [read $f];close $f
package require json
set catalog [::json::json2dict $source]
dict for {english chinese} [dict get $catalog exact] {
    check {[::TriExport::tr $english] eq $chinese} "generated catalog matches UTF-8 source"
}
puts "PASS: $assertions locale assertions across cp936, cp1252 and UTF-8; no windows opened."
