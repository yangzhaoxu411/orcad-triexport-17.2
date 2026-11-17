# Headless Tcl tests: all Capture APIs below are local test doubles.
set base [file normalize [file join [file dirname [info script]] ..]]
source -encoding utf-8 [file join $base src TriExport.tcl]
package require json
set testCount 0
proc check {expression message} {
    if {![uplevel 1 [list expr $expression]]} { error "FAIL: $message" }
    incr ::testCount
}
set scratch [file join $base .work tcl-tests]
file mkdir $scratch
set text "中文 \\ path \"quote\" \n \t \r \x01 \[data\] \$value"
set encoded [::TriExport::jsonObject [dict create key $text]]
check {[dict get [::json::json2dict $encoded] key] eq $text} "JSON escaping and Unicode"
::TriExport::writeUtf8 [file join $scratch utf8.txt] $text
check {[::TriExport::readUtf8 [file join $scratch utf8.txt]] eq $text} "UTF-8 round trip"
set rows [list [dict create schematic MAIN name "Page 1"] [dict create schematic MAIN name "Page 3"]]
set manifest [::TriExport::jobJson [dict create design {C:\设计\test.dsn}] $rows $rows [list [dict create ref U1 value 74LS]]]
set job [::json::json2dict $manifest]
check {[llength [dict get $job selected_pages]] == 2} "JSON page array"
check {[dict get [lindex [dict get $job bom_rows] 0] ref] eq "U1"} "JSON BOM array"

set menus {}
set refreshes 0
set actions {}
proc RegisterAction {label enabler accelerator callback view} {
    dict set ::actions $label [list $enabler $callback]
}
proc dispatch {name args} {
    lassign [dict get $::actions $name] enabler callback
    if {[uplevel #0 [list $enabler {*}$args]]} { return [uplevel #0 [list $callback {*}$args]] }
}
proc InsertXMLMenu {value} { lappend ::menus $value }
proc RefreshMenu {} { incr ::refreshes }
::TriExport::init [file join $scratch fake-17.2]
::TriExport::init [file join $scratch fake-17.2]
check {[llength $menus] == 2 && $refreshes == 1} "menu registration is idempotent"
check {[lrange [lindex $menus 0] 1 2] eq {1 Help}} "menu appended after Help"

package provide capPdfUtil 1.0
namespace eval ::capPdfUtil {}
proc ::capPdfUtil::annotatePageObjects {args} { return originalPage }
proc ::capPdfUtil::printPdfFromPS {args} { return originalPrint }
proc ::capPdfUtil::capPageTrue {args} { return 1 }
proc ::capPdfUtil::capPrintTrue {args} { return 1 }
set initFails 0
set ::capPdfUtil::mOutDir originalDirectory
set ::capPdfUtil::mRemoveTempFiles 1
proc ::capPdfUtil::setOptionValues {} {
    set ::capPdfUtil::mInitialized 1
    set ::capPdfUtil::mOutDir initializedDirectory
    return [expr {!$::initFails}]
}
set options [dict create PostscriptDriver oldDriver InstMode False CreateNetBookMarks True \
    CreateRefdesBookMarks True CreatePropertiesPdfFile True LandscapeOrientation False PaperSize 8]
set initialOptions $options
set printFails 0
set designFile [file join $scratch {Design with spaces 中文.dsn}]
set pmSelection partEditor
set selectionFails 0
set selectionCalls 0
set printCalls 0
set activeDsn mockDesign
rename ::TriExport::activeDesign ::TriExport::realActiveDesign
rename ::TriExport::getString ::TriExport::realGetString
proc ::TriExport::activeDesign {} { return $::activeDsn }
proc ::TriExport::getString {obj method} {
    return $::designFile
}
proc GetSelectedPMItems {} { return $::pmSelection }
proc DboBaseObjectToDboLib {obj} {
    error "17.2 PM items are paths, never pass them to DboBaseObjectToDboLib"
}
proc pmDesignNode {} { return [string map {/ \\} "./[string tolower [file tail $::designFile]]"] }
proc SelectPMItem {target} {
    check {[uplevel 1 {namespace current}] eq "::"} "PM selection uses global context"
    check {$target eq "./[file tail $::designFile]"} "DSN target preserves spaces and Unicode"
    incr ::selectionCalls
    if {$::selectionFails eq "error"} { error "injected selection error" }
    if {$::selectionFails eq "ignored"} { return }
    if {$::selectionFails eq "multiple"} { set ::pmSelection [list [pmDesignNode] {.\Other.dsn}]; return }
    if {$::selectionFails eq "wrong_selection"} { set ::pmSelection {{.\Other.dsn}}; return }
    if {$::selectionFails eq "wrong_design"} {
        set ::activeDsn otherDesign
        set ::designFile [file join $::scratch Other.dsn]
        set ::pmSelection [list [pmDesignNode]]
        return
    }
    set ::pmSelection [list [pmDesignNode]]
}
proc render {spool} { ::TriExport::renderPostscript $spool $::designFile }
proc CapPdfGetOption {key} { return [dict get $::options $key] }
proc CapPdfSetOption {key value} { dict set ::options $key $value }
proc CapPdfPrint {dir file} {
    incr ::printCalls
    check {[lindex $::pmSelection 0] eq [pmDesignNode]} "native print receives DSN rather than editor selection"
    check {[uplevel 1 {namespace current}] eq "::"} "native print runs in global context"
    check {$::capPdfUtil::mInitialized == 1} "native PDF initialized before printing"
    check {$::capPdfUtil::mOutDir eq $dir && $::capPdfUtil::mRemoveTempFiles == 0} "native PDF temporary files retained"
    check {[dict get $::options InstMode] eq "True"} "instance printing configured"
    check {[dict get $::options CreateNetBookMarks] eq "True"} "native annotation pass enabled for page mapping"
    check {[dict get $::options CreatePropertiesPdfFile] eq "False"} "no separate properties PDF"
    if {$::printFails eq "no_output_action"} { return }
    if {$::printFails ni {no_pages zero_pages_empty_ps}} {
        dispatch _cdnOrPdfPrintAnnotatePageObjects DESIGN MAIN PAGE3 mockPage NULL
        dispatch _cdnOrPdfPrintAnnotatePageObjects DESIGN MAIN PAGE1 mockPage NULL
    }
    if {$::printFails eq "native_error"} { error "injected native failure" }
    set ps [file join $dir pages.ps]
    if {$::printFails ne "missing_ps"} {
        ::TriExport::writeUtf8 $ps "%!PS\n%%Page: 3 1\n%%Page: 1 2\n"
    } else { set ps [file join $dir missing.ps] }
    if {$::printFails eq "invalid_ps"} { ::TriExport::writeUtf8 $ps "not PostScript" }
    if {$::printFails eq "zero_pages_empty_ps"} { ::TriExport::writeUtf8 $ps "" }
    dispatch _cdnOrPdfPrintFromPS [file join $dir pages.pdf] {} $ps {} {}
    if {$::printFails eq "duplicate"} { catch {dispatch _cdnOrPdfPrintFromPS [file join $dir pages.pdf] {} $ps {} {}} }
}
set ps [render [file join $scratch spool]]
check {[file exists $ps]} "PostScript callback captured path"
check {[dict get [lindex $::TriExport::printedPages 0] name] eq "PAGE3"} "actual page sequence retained"
check {$options eq $initialOptions} "PDF options restored after success"
check {[::capPdfUtil::annotatePageObjects] eq "originalPage"} "page callback restored after success"
check {[::capPdfUtil::printPdfFromPS] eq "originalPrint"} "converter callback restored after success"
check {[dispatch _cdnOrPdfPrintFromPS a b c d e] eq "originalPrint"} "native converter action restored after success"
check {$::capPdfUtil::mOutDir eq "originalDirectory" && $::capPdfUtil::mRemoveTempFiles == 1} "native PDF state restored"
check {![info exists ::capPdfUtil::mInitialized]} "new native PDF state removed"
set printFails native_error
set code [catch {render [file join $scratch spool]} message]
check {$code == 1 && $message eq "injected native failure"} "native failure propagated"
check {$options eq $initialOptions} "PDF options restored after failure"
check {[::capPdfUtil::annotatePageObjects] eq "originalPage"} "page callback restored after failure"
check {[::capPdfUtil::printPdfFromPS] eq "originalPrint"} "converter callback restored after failure"
check {![llength [info commands ::capPdfUtil::*_triExportSaved]]} "no stale callback backup"
check {[dispatch _cdnOrPdfPrintAnnotatePageObjects a b c d e] eq "originalPage"} "native page action restored after failure"
foreach {failure expected} {
    no_output_action {*did not call the PDF output action*}
    no_pages {*PostScript but no page callbacks*}
    missing_ps {*returned empty PostScript*}
    zero_pages_empty_ps {*returned empty PostScript*Page callbacks: 0*}
    invalid_ps {*did not produce PostScript*}
    duplicate {*submitted PostScript twice*}
} {
    set printFails $failure
    set code [catch {render [file join $scratch $failure]} message]
    check {$code == 1 && [string match $expected $message]} "distinct diagnostic for $failure: $message"
    check {$options eq $initialOptions} "options restored for $failure"
    check {[dispatch _cdnOrPdfPrintFromPS a b c d e] eq "originalPrint"} "native actions restored for $failure"
    check {$::capPdfUtil::mOutDir eq "originalDirectory"} "native state restored for $failure"
    check {[file isfile $::TriExport::pdfLog]} "diagnostic log retained for $failure"
}
set initFails 1
set code [catch {render [file join $scratch init-failure]} message]
check {$code == 1 && [string match {*initialization found no active design*} $message]} "native initialization failure"
check {$options eq $initialOptions && $::capPdfUtil::mOutDir eq "originalDirectory"} "initialization failure restores state"

set initFails 0
set printFails 0
foreach context {pageEditor propertyEditor designCache mockDesign} {
    set pmSelection $context
    set previousCalls $selectionCalls
    render [file join $scratch repeat-$context]
    check {$selectionCalls == $previousCalls + 1} "repeated export reselects DSN from $context"
    check {[llength $::TriExport::printedPages] == 2} "repeated export clears previous page mapping"
}
foreach failure {error ignored multiple wrong_selection wrong_design} {
    set pmSelection propertyEditor
    set selectionFails $failure
    set beforePrint $printCalls
    set code [catch {render [file join $scratch selection-$failure]} message]
    check {$code == 1} "selection failure is reported: $failure"
    check {$printCalls == $beforePrint} "selection failure stops before printing: $failure"
    check {$options eq $initialOptions} "selection failure restores options: $failure"
    check {[dispatch _cdnOrPdfPrintFromPS a b c d e] eq "originalPrint"} "selection failure leaves native actions intact"
    set activeDsn mockDesign
    set designFile [file join $scratch {Design with spaces 中文.dsn}]
}
set beforePrint $printCalls
set code [catch {::TriExport::renderPostscript [file join $scratch changed-design] [file join $scratch Different.dsn]} message]
check {$code == 1 && [string match {*active design changed*} $message]} "reject switched project before selecting"
check {$printCalls == $beforePrint} "switched project is never printed"
rename ::TriExport::activeDesign {}
rename ::TriExport::realActiveDesign ::TriExport::activeDesign
rename ::TriExport::getString {}
rename ::TriExport::realGetString ::TriExport::getString

# Dbo string getters own only their temporary CString and returned DboState.
set freed {}
proc DboTclHelper_sMakeCString {args} { return stringBuffer }
proc DboTclHelper_sGetConstCharPtr {p} { return "value result" }
proc DboTclHelper_sDeleteCString {p} { lappend ::freed $p }
proc mockState {method} { if {$method eq "OK"} {return 1}; lappend ::freed state }
proc mockObject {method args} { return mockState }
check {[::TriExport::getString mockObject GetName] eq "value result"} "Dbo string read"
check {$freed eq {state stringBuffer}} "Dbo temporary resources released"
puts "PASS: $testCount assertions; no Capture or Tk UI was started."
