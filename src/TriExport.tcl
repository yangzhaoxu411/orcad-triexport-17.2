# OrCAD Capture 17.2 TriExport. Chinese UI; user data remains UTF-8.
# Entry points use the documented Capture Tcl API; no window automation.
namespace eval ::TriExport {
    variable version "1.0.0-rc10"
    variable home [file dirname [file normalize [info script]]]
    variable cadenceRoot ""
    variable registered 0
    variable busy 0
    variable win .triExport
    variable pages {}
    variable checked
    variable designPath ""
    variable root ""
    variable ghostscript ""
    variable driver "OrCADPS_17.2"
    variable paper "Original sheet size"
    variable netlistFormat "Allegro (ZIP)"
    variable formatNote ""
    variable statusText "Choose an output folder and PDF pages."
    variable jobDir ""
    variable printedPages {}
    variable psPath ""
    variable selectedCount ""
    variable workerChannel ""
    variable pdfLog ""
    variable pdfCallbackError ""
}
source -encoding utf-8 [file join $::TriExport::home BomFilters.tcl]
source -encoding utf-8 [file join $::TriExport::home UiLocale.tcl]
set ::TriExport::statusText [::TriExport::tr $::TriExport::statusText]

proc ::TriExport::readUtf8 {path} {
    set f [open $path r]
    try { fconfigure $f -encoding utf-8 -translation lf; return [read $f] } finally { close $f }
}
proc ::TriExport::writeUtf8 {path text} {
    set f [open $path w]
    try { fconfigure $f -encoding utf-8 -translation lf; puts -nonewline $f $text } finally { close $f }
}
proc ::TriExport::dataHome {} {
    if {![info exists ::env(LOCALAPPDATA)]} { error "LOCALAPPDATA is not available." }
    return [file join $::env(LOCALAPPDATA) OrCADTriExport data-17.2]
}

# JSON strings are encoded as data. Never eval/source a manifest or settings.
proc ::TriExport::jsonString {value} {
    set out "\""
    foreach c [split $value ""] {
        scan $c %c n
        switch -- $c {
            "\"" {append out {\"}}
            "\\" {append out {\\}}
            default {
                if {$n < 32} { append out [format {\u%04x} $n] } else { append out $c }
            }
        }
    }
    append out "\""
    return $out
}
proc ::TriExport::jsonObject {pairs} {
    set fields {}
    dict for {k v} $pairs { lappend fields "[jsonString $k]:[jsonString $v]" }
    return "\{[join $fields ,]\}"
}
proc ::TriExport::jsonObjects {rows} {
    set values {}
    foreach row $rows { lappend values [jsonObject $row] }
    return "\[[join $values ,]\]"
}
proc ::TriExport::jobJson {scalars selected printed bom {filter {}}} {
    set fields {}
    dict for {k v} $scalars { lappend fields "[jsonString $k]:[jsonString $v]" }
    lappend fields "\"selected_pages\":[jsonObjects $selected]"
    lappend fields "\"printed_pages\":[jsonObjects $printed]"
    lappend fields "\"bom_rows\":[bomRowsJson $bom]"
    if {$filter ne ""} { lappend fields "\"bom_filter\":[bomFilterJson $filter]" }
    return "\{[join $fields ,]\}"
}
proc ::TriExport::loadSettings {} {
    variable bomFilter
    variable bomFilterLoadError
    set bomFilter [defaultBomFilter]
    set bomFilterLoadError ""
    set ::TriExport::netlistFormat "Allegro (ZIP)"
    set path [file join [dataHome] settings.json]
    if {![file isfile $path]} { return }
    if {[catch {package require json; set data [::json::json2dict [readUtf8 $path]]}]} {
        set bomFilterLoadError "Could not read saved settings. Open BOM Filters and save the corrected settings."
        return
    }
    foreach key {root ghostscript driver paper} {
        if {[dict exists $data $key]} { set ::TriExport::$key [dict get $data $key] }
    }
    if {[dict exists $data netlist_format] && [dict get $data netlist_format] eq "pads-v3"} {
        set ::TriExport::netlistFormat "PADS PowerPCB V3 (ASC)"
    }
    if {[dict exists $data bom_filter]} {
        if {[catch {set bomFilter [validateBomFilter [dict get $data bom_filter]]} err]} {
            set bomFilterLoadError "Saved BOM filters are invalid. Open BOM Filters and save the corrected settings: $err"
        }
    }
    # Migrate rc1 labels without retaining locale-dependent UI text.
    if {[string match {A4 *} $::TriExport::paper]} { set ::TriExport::paper "A4 landscape" }
    if {[string match {A3 *} $::TriExport::paper]} { set ::TriExport::paper "A3 landscape" }
    if {$::TriExport::paper ni {{Original sheet size} {A4 landscape} {A3 landscape}}} {
        set ::TriExport::paper "Original sheet size"
    }
}
proc ::TriExport::saveSettings {} {
    variable bomFilter
    variable bomFilterLoadError
    if {$bomFilterLoadError ne ""} { error $bomFilterLoadError }
    file mkdir [dataHome]
    set data {}
    foreach key {root ghostscript driver paper} { dict set data $key [set ::TriExport::$key] }
    dict set data netlist_format [netlistFormatId]
    set path [file join [dataHome] settings.json]
    set encoded [jsonObject $data]
    writeUtf8 "$path.tmp" "[string range $encoded 0 end-1],\"bom_filter\":[bomFilterJson $bomFilter]\}"
    file rename -force "$path.tmp" $path
}

proc ::TriExport::netlistFormatId {} {
    variable netlistFormat
    switch -- $netlistFormat {
        "Allegro (ZIP)" { return allegro-pst }
        "PADS PowerPCB V3 (ASC)" { return pads-v3 }
        default { error "Choose Allegro or PADS from Netlist format." }
    }
}
proc ::TriExport::updateFormatNote {} {
    variable formatNote
    if {[netlistFormatId] eq "allegro-pst"} {
        set formatNote [tr "Output: Allegro netlist ZIP, PDF and BOM CSV. Unzip the netlist before importing into Allegro. Page selection applies to PDF only."]
    } else {
        set formatNote [tr "Output: PADS PowerPCB V3 ASC, PDF and BOM CSV. PADS naming and power-mapping limits apply. Page selection applies to PDF only."]
    }
}
proc ::TriExport::formatChanged {} {
    updateFormatNote
    if {[catch {saveSettings} message options]} { reportError "Could not save the selected format" $message $options }
}

proc ::TriExport::findGhostscript {} {
    set candidates {}
    foreach envName {ProgramFiles ProgramW6432 ProgramFiles(x86)} {
        if {[info exists ::env($envName)]} {
            set base [file join $::env($envName) gs]
            foreach exe {gswin64c.exe gswin32c.exe} {
                lappend candidates {*}[lsort -decreasing -dictionary [glob -nocomplain -directory $base */bin/$exe]]
            }
        }
    }
    if {[info exists ::env(LOCALAPPDATA)]} {
        lappend candidates [file join $::env(LOCALAPPDATA) OrCADTriExport ghostscript bin gswin64c.exe]
    }
    foreach p $candidates { if {[file isfile $p]} { return $p } }
    return ""
}

proc ::TriExport::releaseString {ptr} {
    DboTclHelper_sDeleteCString $ptr
}
proc ::TriExport::getString {obj method} {
    set buf [DboTclHelper_sMakeCString]
    try {
        set state [$obj $method $buf]
        try {
            if {![$state OK]} { error "Could not read $method." }
            return [DboTclHelper_sGetConstCharPtr $buf]
        } finally { $state -delete }
    } finally { releaseString $buf }
}
proc ::TriExport::property {obj names} {
    foreach name $names {
        set key [DboTclHelper_sMakeCString $name]
        set val [DboTclHelper_sMakeCString]
        try {
            set state [$obj GetEffectivePropStringValue $key $val]
            try {
                if {[$state OK]} {
                    set text [DboTclHelper_sGetConstCharPtr $val]
                    if {$text ne ""} { return $text }
                }
            } finally { $state -delete }
        } finally { releaseString $key; releaseString $val }
    }
    return ""
}
proc ::TriExport::activeDesign {} {
    if {[catch {set d [GetActivePMDesign]}] || $d eq "NULL" || $d eq "" || $d eq "0"} {
        error "Open a project and select the design in Project Manager first."
    }
    return $d
}
proc ::TriExport::assertSaved {d} {
    set s [DboState]
    try {
        set modified [$d IsModified $s]
        if {![$s OK]} { error "Could not check whether the design is saved." }
        if {$modified} { error "The design has unsaved changes. Save it before exporting." }
    } finally { $s -delete }
    set path [getString $d GetName]
    if {![file isfile $path] || ![string equal -nocase [file extension $path] .dsn]} {
        error "Save the design as a DSN file first."
    }
    return [file normalize $path]
}
proc ::TriExport::enumeratePages {d} {
    set rows {}
    set s [DboState]
    set views "NULL"
    try {
        set views [$d NewViewsIter $s $::IterDefs_SCHEMATICS]
        if {$views eq "NULL" || ![$s OK]} { error "Could not enumerate schematics." }
        while {1} {
            set v [$views NextView $s]
            if {$v eq "NULL"} { break }
            if {![$s OK]} { error "Could not read a schematic." }
            set sch [DboViewToDboSchematic $v]
            if {$sch eq "NULL"} { error "Could not read the schematic view." }
            set name [getString $sch GetName]
            set pagesIter [$sch NewPagesIter $s]
            if {$pagesIter eq "NULL" || ![$s OK]} { error "Could not enumerate schematic pages." }
            try {
                while {1} {
                    set p [$pagesIter NextPage $s]
                    if {$p eq "NULL"} { break }
                    if {![$s OK]} { error "Could not read a schematic page." }
                    lappend rows [dict create schematic $name name [getString $p GetName]]
                }
            } finally { delete_DboSchematicPagesIter $pagesIter }
        }
    } finally {
        if {$views ne "NULL"} { delete_DboLibViewsIter $views }
        $s -delete
    }
    if {![llength $rows]} { error "The active design has no schematic pages to export." }
    return $rows
}
proc ::TriExport::walkBom {occ depth {filter {}}} {
    if {$depth > 128} { error "Hierarchy exceeds 128 levels. Check for recursive references." }
    set s [DboState]
    set iter "NULL"
    set rows {}
    try {
        set iter [$occ NewChildrenIter $s $::IterDefs_INSTS]
        if {$iter eq "NULL" || ![$s OK]} { error "Could not enumerate component occurrences." }
        $iter Sort $s
        while {1} {
            set child [$iter NextOccurrence $s]
            if {$child eq "NULL"} { break }
            if {![$s OK]} { error "Could not read a component occurrence." }
            set inst [DboOccurrenceToDboInstOccurrence $child]
            if {$inst eq "NULL"} { error "Could not convert a component occurrence." }
            set primitive [$inst IsPrimitive $s]
            if {![$s OK]} { error "Could not read the component type." }
            if {$primitive} {
                set ref [getString $inst GetReference]
                set row [dict create ref $ref value [getString $inst GetPartValue] \
                    part_number [property $inst {{Part Number} PartNumber MPN {Manufacturer Part Number}}] \
                    manufacturer [property $inst {Manufacturer MFR}] \
                    description [property $inst {Description}] \
                    dnp [property $inst {DNP DNI {Do Not Populate} {Do Not Stuff}}]]
                lappend rows [captureFilterValues $inst $row $filter]
            } else {
                lappend rows {*}[walkBom $inst [expr {$depth + 1}] $filter]
            }
        }
    } finally {
        if {$iter ne "NULL"} { delete_DboOccurrenceChildrenIter $iter }
        $s -delete
    }
    return $rows
}
proc ::TriExport::enumerateBom {d {filter {}}} {
    set s [DboState]
    try {
        set rootOcc [$d GetRootOccurrence $s]
        if {$rootOcc eq "NULL" || ![$s OK]} { error "The active design has no valid root occurrence." }
        return [walkBom $rootOcc 0 $filter]
    } finally { $s -delete }
}

# The native printing callback supplies the actual print sequence. We do not
# infer PDF indices from the order returned by NewPagesIter.
proc ::TriExport::onPage {design schematic page pageObj occurrence} {
    variable printedPages
    lappend printedPages [dict create schematic $schematic name $page]
    pdfTrace "page [llength $printedPages]: [list $schematic $page]"
    return $pageObj
}
proc ::TriExport::onPostscript {pdf props ps marks propmarks} {
    variable psPath
    variable pdfCallbackError
    # Capture can consume Tcl errors raised inside an action. Retain the error
    # explicitly so the caller cannot mistake a partial callback for success.
    if {$psPath ne ""} {
        set pdfCallbackError "The printer submitted PostScript twice. Export stopped."
        return 0
    }
    if {[catch {set psPath [file normalize $ps]} err]} {
        set pdfCallbackError "Capture returned an invalid PostScript path: $err"
        return 0
    }
    pdfTrace "PostScript callback: [list $psPath]"
    return 1
}
proc ::TriExport::pdfTrace {message} {
    variable pdfLog
    if {$pdfLog eq ""} { return }
    # Diagnostic failures must not interrupt a native print callback.
    catch {
        set f [open $pdfLog a]
        try {
            fconfigure $f -encoding utf-8 -translation lf
            puts $f "[clock format [clock seconds] -format {%H:%M:%S}] $message"
        } finally { close $f }
    }
}
proc ::TriExport::pdfActions {intercept} {
    # Native 17.2 printing dispatches registered actions. Replacing Tcl procs
    # alone does not establish that dispatch route. Keep the Cadence procs
    # intact and explicitly bind the two documented action names for this job.
    if {$intercept} {
        set page ::TriExport::onPage
        set converter ::TriExport::onPostscript
    } else {
        set page ::capPdfUtil::annotatePageObjects
        set converter ::capPdfUtil::printPdfFromPS
    }
    set errors {}
    foreach {label enabler callback} [list \
        _cdnOrPdfPrintAnnotatePageObjects ::capPdfUtil::capPageTrue $page \
        _cdnOrPdfPrintFromPS ::capPdfUtil::capPrintTrue $converter] {
        if {[catch {uplevel #0 [list RegisterAction $label $enabler {} $callback {}]} err]} {
            lappend errors "$label: $err"
        }
    }
    if {[llength $errors]} { error [join $errors {; }] }
}
proc ::TriExport::selectPdfDesign {path} {
    # Capture's PDF export requires the DESIGN selected in Project Manager.
    # GetActivePMDesign alone also succeeds while a page/part editor is active.
    # The documented SelectPMItem form uses ./<design filename> in the active PM.
    set expected [file normalize $path]
    set current [file normalize [getString [activeDesign] GetName]]
    if {![string equal -nocase $current $expected]} {
        error "The active design changed before PDF printing. Refresh the page list."
    }
    pdfTrace "Expected design: [list $expected]"
    foreach command {GetPMItemName GetPMItemType GetActiveWindow GetSelectedPMItems} {
        if {![catch {uplevel #0 [list $command]} value]} {
            pdfTrace "Before selection $command: [list $value]"
        }
    }
    set target "./[file tail $expected]"
    pdfTrace "Selecting Project Manager design: [list $target]"
    uplevel #0 [list SelectPMItem $target]
    set selected [uplevel #0 {GetSelectedPMItems}]
    pdfTrace "Selected PM paths: [list $selected]"
    set selectedPath ""
    if {[llength $selected] == 1} {
        # Capture 17.2 returns TREE PATH STRINGS, e.g. {.\design.dsn},
        # not DboBaseObject pointers. Resolve the selected design node against
        # the expected design directory; verify the active design again below.
        set item [string map {\\ /} [lindex $selected 0]]
        set selectedPath [file normalize [file join [file dirname $expected] $item]]
    }
    if {![string equal -nocase $selectedPath $expected]} {
        error "Capture could not select the design for PDF printing. Select the DSN in Project Manager and retry. Details: $::TriExport::pdfLog"
    }
    set current [file normalize [getString [activeDesign] GetName]]
    if {![string equal -nocase $current $expected]} {
        error "The PDF print target changed. Export stopped. Details: $::TriExport::pdfLog"
    }
    pdfTrace "Verified PDF design: [list $current]"
}
proc ::TriExport::renderPostscript {spool design} {
    variable printedPages
    variable psPath
    variable driver
    variable paper
    variable pdfLog
    variable pdfCallbackError
    set printedPages {}
    set psPath ""
    set pdfCallbackError ""
    set spool [file normalize $spool]
    file mkdir $spool
    set pdfLog [file join [file dirname $spool] pdf-print.log]
    writeUtf8 $pdfLog "TriExport $::TriExport::version\nDriver: $driver\nPaper: $paper\nSpool: $spool\n"
    # Use the same initialization as capPdfUtil::printPdf, without its blanket
    # catch (which discards native errors), external converter or PDF viewer.
    uplevel #0 {package require capPdfUtil}
    foreach name {setOptionValues capPageTrue capPrintTrue annotatePageObjects printPdfFromPS} {
        if {![llength [info procs ::capPdfUtil::$name]]} {
            error "The Capture 17.2 PDF package is incomplete: $name."
        }
    }
    set paperId 0
    if {$paper eq "A4 landscape"} { set paperId 9 }
    if {$paper eq "A3 landscape"} { set paperId 8 }
    # Retain the native annotation pass for page identity. Its mark files stay
    # in the job directory; the worker creates only the requested page bookmarks.
    set desired [dict create PostscriptDriver $driver InstMode True CreateNetBookMarks True \
        CreateRefdesBookMarks False CreatePropertiesPdfFile False LandscapeOrientation True PaperSize $paperId]
    set saved {}
    # Read all options before changing any, so a missing API cannot leave a
    # partially applied set of PDF preferences.
    dict for {k v} $desired { dict set saved $k [CapPdfGetOption $k] }
    if {$paperId == 0} { dict set desired LandscapeOrientation [dict get $saved LandscapeOrientation] }
    set nativeSaved {}
    set nativeVars {mActivePMDesign mInitialized mDesignBaseName mDesignDir mOutDir mOutFile \
        mPdfFilePath mPSFilePath mPSToPDFConverterCommand mRemoveTempFiles}
    foreach name $nativeVars {
        if {[info exists ::capPdfUtil::$name]} { dict set nativeSaved $name [set ::capPdfUtil::$name] }
    }
    set actionsTouched 0
    set restoreErrors {}
    set printCode 0
    try {
        # Re-establish the target on EVERY export, including after a failed job
        # or editing component properties while this modeless dialog stays open.
        selectPdfDesign $design
        if {![::capPdfUtil::setOptionValues]} {
            error "Capture PDF initialization found no active design. Select the DSN in Project Manager and retry."
        }
        set ::capPdfUtil::mOutDir $spool
        set ::capPdfUtil::mOutFile pages.pdf
        set ::capPdfUtil::mRemoveTempFiles 0
        set actionsTouched 1
        pdfActions 1
        dict for {k v} $desired { CapPdfSetOption $k $v }
        dict for {k v} $desired { pdfTrace "option $k = [CapPdfGetOption $k]" }
        pdfTrace "Calling CapPdfPrint"
        # Call in the global Tcl context, as Capture's registered native PDF
        # action does; avoid inheriting the Tk button's procedure scope.
        set printCode [catch {uplevel #0 [list CapPdfPrint $spool pages.pdf]} printResult printOptions]
        pdfTrace "CapPdfPrint code=$printCode result=[list $printResult]"
        if {$printCode} { return -options $printOptions $printResult }
    } on error {message options} {
        pdfTrace "PDF preparation/printing error: $message"
        return -options $options $message
    } finally {
        if {$actionsTouched && [catch {pdfActions 0} err]} { lappend restoreErrors "PDF actions: $err" }
        foreach name $nativeVars {
            if {[dict exists $nativeSaved $name]} {
                set ::capPdfUtil::$name [dict get $nativeSaved $name]
            } else {
                unset -nocomplain ::capPdfUtil::$name
            }
        }
        dict for {k v} $saved {
            if {[catch {CapPdfSetOption $k $v} err]} { lappend restoreErrors "$k: $err" }
        }
        pdfTrace "Page callbacks: [llength $printedPages]; PostScript: [list $psPath]"
        foreach f [glob -nocomplain -directory $spool *] {
            if {[file isfile $f]} { pdfTrace "spool file: [list [file tail $f]] ([file size $f] bytes)" }
        }
        if {[llength $restoreErrors]} {
            pdfTrace "Restore errors: [join $restoreErrors {; }]"
            error "Could not restore PDF settings: [join $restoreErrors {; }]"
        }
    }
    if {$pdfCallbackError ne ""} { error $pdfCallbackError }
    if {$psPath eq ""} {
        error "Capture did not call the PDF output action. Restart Capture, select the DSN in Project Manager and retry. Details: $pdfLog"
    }
    if {![file isfile $psPath] || [file size $psPath] == 0} {
        error "Capture returned empty PostScript after selecting the design ($design). Page callbacks: [llength $printedPages]. Close any part/property editor, select the DSN in Project Manager, and retry. If this continues, test Capture's built-in Export PDF. Details: $pdfLog"
    }
    if {![llength $printedPages]} {
        error "Capture produced PostScript but no page callbacks. PDF pages cannot be matched safely. Details: $pdfLog"
    }
    set parent [string tolower [file normalize [file dirname $psPath]]]
    if {$parent ne [string tolower [file normalize $spool]]} {
        error "Capture printed outside the temporary directory. Export stopped."
    }
    set f [open $psPath rb]
    try { set header [read $f 4096] } finally { close $f }
    if {[string first {%!PS} $header] < 0} {
        error "Printer '$driver' did not produce PostScript. Choose a PostScript printer. Details: $pdfLog"
    }
    return $psPath
}

proc ::TriExport::chooseRoot {} {
    variable root
    variable win
    set chosen [tk_chooseDirectory -parent $win -title [tr "Choose output root folder"] -mustexist 1]
    if {$chosen ne ""} { set root $chosen }
}
proc ::TriExport::chooseGs {} {
    variable ghostscript
    variable win
    set chosen [tk_getOpenFile -parent $win -title [tr "Select gswin64c.exe or gswin32c.exe"] \
        -filetypes {{{Ghostscript} {.exe}}}]
    if {$chosen ne ""} { set ghostscript $chosen }
}
proc ::TriExport::countSelected {} {
    variable checked
    variable pages
    variable selectedCount
    set n 0
    foreach key [array names checked] { if {$checked($key)} { incr n } }
    set selectedCount [tr "$n / [llength $pages] pages selected"]
}
proc ::TriExport::selectAll {value} {
    variable checked
    variable busy
    if {$busy} { return }
    foreach key [array names checked] { set checked($key) $value }
    countSelected
}
proc ::TriExport::refreshPages {} {
    variable win
    variable busy
    variable pages
    variable checked
    variable designPath
    if {$busy} { return }
    set d [activeDesign]
    set path [getString $d GetName]
    set fresh [enumeratePages $d]
    set pages $fresh
    set designPath $path
    foreach child [winfo children $win.pageList.canvas.items] { destroy $child }
    array unset checked
    set i 0
    foreach page $pages {
        set checked($i) 1
        ttk::checkbutton $win.pageList.canvas.items.p$i \
            -text "[dict get $page schematic] / [dict get $page name]" \
            -variable ::TriExport::checked($i) -command ::TriExport::countSelected
        pack $win.pageList.canvas.items.p$i -anchor w -fill x -padx 8 -pady 3
        incr i
    }
    countSelected
}
proc ::TriExport::refreshAction {} {
    variable win
    if {[catch {refreshPages} err]} { showMessage -parent $win -icon error -message [displayError $err] }
}
proc ::TriExport::sizeCanvas {} {
    variable win
    $win.pageList.canvas configure -scrollregion [$win.pageList.canvas bbox all]
}
proc ::TriExport::setControls {parent disabled} {
    foreach child [winfo children $parent] {
        if {[winfo class $child] in {TButton TCheckbutton TEntry TCombobox}} {
            if {$disabled} { $child state disabled } else { $child state !disabled }
        }
        setControls $child $disabled
    }
}
proc ::TriExport::closeWindow {} {
    variable busy
    variable win
    if {!$busy} { destroy $win }
}
proc ::TriExport::ensureUi {} {
    # Capture can invoke actions before any extension has loaded Tk. Do not
    # call winfo, ttk widgets or tk_messageBox until the package is available.
    set alreadyLoaded [expr {[package provide Tk] ne ""}]
    package require Tk 8.6
    if {!$alreadyLoaded} { wm withdraw . }
    if {![llength [info commands ::ttk::frame]]} { error "Tk loaded without ttk support." }
}
proc ::TriExport::recordError {context message details} {
    variable version
    set text "TriExport $version - $context\n$message\n$details"
    catch {
        set directory [dataHome]
        file mkdir $directory
        set channel [open [file join $directory startup-error.log] a]
        try {
            fconfigure $channel -encoding utf-8 -translation lf
            puts $channel "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\n$text\n"
        } finally { close $channel }
    }
    catch {puts $text}
    return $text
}
proc ::TriExport::reportError {context message options} {
    set details ""
    if {[dict exists $options -errorinfo]} { set details [dict get $options -errorinfo] }
    recordError $context $message $details
    # If Tk itself failed to load, do not mask the original error with another
    # call to an unavailable Tk command. Session Log and the file retain it.
    if {[llength [info commands ::tk_messageBox]]} {
        catch {showMessage -title "TriExport" -icon error -message "[tr $context]\n\n[displayError $message]\n\n[tr {See startup-error.log in LocalAppData/OrCADTriExport/data-17.2.}]"}
    }
}
proc ::TriExport::show {args} {
    variable win
    ensureUi
    if {[winfo exists $win]} { wm deiconify $win; raise $win; return }
    try {
        buildDialog
    } on error {message options} {
        # A partial widget tree must not make the next click appear successful.
        catch {destroy $win}
        return -options $options $message
    }
}
proc ::TriExport::buildDialog {} {
    variable win
    variable root
    variable ghostscript
    package require json
    loadSettings
    updateFormatNote
    updateBomSummary
    if {$ghostscript eq ""} { set ghostscript [findGhostscript] }
    toplevel $win
    wm title $win [tr "TriExport $::TriExport::version - OrCAD 17.2"]
    wm geometry $win 760x720
    wm minsize $win 620 560
    wm protocol $win WM_DELETE_WINDOW ::TriExport::closeWindow
    ttk::frame $win.top -padding 14
    pack $win.top -side top -fill x
    ttk::label $win.top.title -text [tr "Netlist  /  Schematic PDF  /  BOM"] -font {"Microsoft YaHei UI" 14 bold}
    ttk::label $win.top.design -textvariable ::TriExport::designPath -wraplength 690
    pack $win.top.title $win.top.design -anchor w -pady 4
    ttk::frame $win.location -padding {14 0 14 8}
    pack $win.location -fill x
    ttk::label $win.location.label -text [tr "Output root folder"]
    ttk::entry $win.location.path -textvariable ::TriExport::root
    ttk::button $win.location.browse -text [tr "Browse..."] -command ::TriExport::chooseRoot
    grid $win.location.label -row 0 -column 0 -padx {0 10}
    grid $win.location.path -row 0 -column 1 -sticky ew
    grid $win.location.browse -row 0 -column 2 -padx {8 0}
    grid columnconfigure $win.location 1 -weight 1
    ttk::frame $win.format -padding {14 0 14 8}
    pack $win.format -fill x
    ttk::label $win.format.label -text [tr "Netlist format"]
    ttk::combobox $win.format.choice -textvariable ::TriExport::netlistFormat -state readonly \
        -values {{Allegro (ZIP)} {PADS PowerPCB V3 (ASC)}} -width 30
    bind $win.format.choice <<ComboboxSelected>> ::TriExport::formatChanged
    pack $win.format.label -side left -padx {0 10}
    pack $win.format.choice -side left -fill x -expand 1
    ttk::frame $win.bom -padding {14 0 14 8}
    pack $win.bom -fill x
    ttk::button $win.bom.settings -text [tr "BOM Filters..."] -command ::TriExport::showBomFilters
    ttk::label $win.bom.summary -textvariable ::TriExport::bomSummary -wraplength 530
    pack $win.bom.settings -side left -padx {0 10}
    pack $win.bom.summary -side left -fill x -expand 1
    ttk::frame $win.pageTools -padding {14 4}
    pack $win.pageTools -fill x
    ttk::label $win.pageTools.label -text [tr "PDF pages (multiple selection)"]
    ttk::label $win.pageTools.count -textvariable ::TriExport::selectedCount
    ttk::button $win.pageTools.all -text [tr "Select all"] -command {::TriExport::selectAll 1}
    ttk::button $win.pageTools.none -text [tr "Clear all"] -command {::TriExport::selectAll 0}
    ttk::button $win.pageTools.refresh -text [tr "Refresh"] -command ::TriExport::refreshAction
    pack $win.pageTools.label $win.pageTools.count -side left -padx {0 10}
    pack $win.pageTools.refresh $win.pageTools.none $win.pageTools.all -side right -padx 3
    ttk::frame $win.pageList -padding {14 0 14 0}
    pack $win.pageList -fill both -expand 1
    canvas $win.pageList.canvas -background white -highlightthickness 1 -highlightbackground #d8dce2
    ttk::scrollbar $win.pageList.scroll -orient vertical -command [list $win.pageList.canvas yview]
    $win.pageList.canvas configure -yscrollcommand [list $win.pageList.scroll set]
    ttk::frame $win.pageList.canvas.items
    $win.pageList.canvas create window 0 0 -window $win.pageList.canvas.items -anchor nw -tags content
    bind $win.pageList.canvas.items <Configure> ::TriExport::sizeCanvas
    bind $win.pageList.canvas <Configure> [list $win.pageList.canvas itemconfigure content -width %w]
    pack $win.pageList.scroll -side right -fill y
    pack $win.pageList.canvas -side left -fill both -expand 1
    ttk::frame $win.options -padding 14
    pack $win.options -fill x
    ttk::label $win.options.gsLabel -text [tr "Ghostscript"]
    ttk::entry $win.options.gs -textvariable ::TriExport::ghostscript
    ttk::button $win.options.gsBrowse -text [tr "Browse..."] -command ::TriExport::chooseGs
    grid $win.options.gsLabel -row 0 -column 0 -sticky w -padx {0 10}
    grid $win.options.gs -row 0 -column 1 -sticky ew
    grid $win.options.gsBrowse -row 0 -column 2 -padx {8 0}
    ttk::label $win.options.driverLabel -text [tr "PDF print driver"]
    ttk::entry $win.options.driver -textvariable ::TriExport::driver
    localizedChoice $win.options.paper -textvariable ::TriExport::paper -state readonly \
        -values {{Original sheet size} {A4 landscape} {A3 landscape}} -width 19
    grid $win.options.driverLabel -row 1 -column 0 -sticky w -pady 8
    grid $win.options.driver -row 1 -column 1 -sticky ew -pady 8
    grid $win.options.paper -row 1 -column 2 -padx {8 0}
    grid columnconfigure $win.options 1 -weight 1
    ttk::label $win.options.note -textvariable ::TriExport::formatNote -wraplength 690
    grid $win.options.note -row 2 -column 0 -columnspan 3 -sticky w
    ttk::frame $win.bottom -padding {14 0 14 14}
    pack $win.bottom -fill x
    ttk::label $win.bottom.status -textvariable ::TriExport::statusText -wraplength 530
    ttk::button $win.bottom.export -text [tr "Export Files"] -command ::TriExport::start
    ttk::button $win.bottom.close -text [tr "Close"] -command ::TriExport::closeWindow
    pack $win.bottom.close $win.bottom.export -side right -padx 4
    pack $win.bottom.status -side left -fill x -expand 1
    refreshAction
}

proc ::TriExport::start {} {
    variable win
    variable busy
    variable statusText
    if {$busy} { return }
    set busy 1
    setControls $win 1
    set statusText [tr "Checking the design and export dependencies..."]
    update idletasks
    if {[catch {prepareJob} err opts]} {
        set busy 0
        setControls $win 0
        set statusText "[tr {Export did not complete:}] [displayError $err]"
        set err [displayError $err]
        variable jobDir
        if {$jobDir ne "" && [file isdirectory $jobDir]} {
            catch {writeUtf8 [file join $jobDir capture-error.log] [dict get $opts -errorinfo]}
            append err "\n\n[tr {Diagnostics:}] $jobDir"
        }
        showMessage -parent $win -title "Export Files" -icon error -message $err
    }
}
proc ::TriExport::prepareJob {} {
    variable home
    variable cadenceRoot
    variable root
    variable driver
    variable ghostscript
    variable designPath
    variable pages
    variable checked
    variable printedPages
    variable jobDir
    variable statusText
    set jobDir ""
    # Freeze the selection before rendering and reject invalid values early.
    set format [netlistFormatId]
    variable win
    if {[winfo exists $win.bomFilters]} { error "Save or cancel BOM Filters before exporting." }
    variable bomFilterLoadError
    variable bomFilter
    if {$bomFilterLoadError ne ""} { error $bomFilterLoadError }
    set filter [validateBomFilter $bomFilter]
    set selected {}
    set i 0
    foreach page $pages { if {$checked($i)} { lappend selected $page }; incr i }
    if {![llength $selected]} { error "Select at least one schematic page." }
    if {![file isdirectory $root]} { error "Choose an existing output root folder." }
    set worker [file join $home bin TriExportWorker.exe]
    if {![file isfile $worker]} { error "The export worker is missing. Reinstall TriExport." }
    if {![file isfile [file join $cadenceRoot tools bin pstswp.exe]]} { error "Could not find the Capture 17.2 netlister." }
    if {![file isfile $ghostscript] || [string tolower [file tail $ghostscript]] ni {gswin64c.exe gswin32c.exe}} {
        error "Select gswin64c.exe or gswin32c.exe from the Ghostscript bin folder, not the installer."
    }
    if {![capIsPrinterDriverAvailable $driver]} { error "PostScript printer is unavailable: $driver. Install the OrCAD 17.2 PDF printer first." }
    set d [activeDesign]
    set path [assertSaved $d]
    if {![string equal -nocase $path [file normalize $designPath]]} { error "The active design changed. Refresh the page list first." }
    if {[enumeratePages $d] ne $pages} { error "The schematic pages changed. Refresh the page list first." }
    saveSettings
    set jobDir [file join [dataHome] jobs "[clock format [clock seconds] -format %Y%m%d-%H%M%S]-[pid]-[clock clicks]"]
    file mkdir [file join $jobDir spool]
    set hashPath [file join $jobDir design.sha256]
    exec $worker hash $path --output $hashPath
    set hash [string trim [readUtf8 $hashPath]]
    if {![regexp {^[0-9a-f]{64}$} $hash]} { error "Could not verify the design file revision." }
    set statusText [tr "Reading the BOM for the full design..."]
    update idletasks
    set bom [enumerateBom $d $filter]
    set statusText [tr "Printing schematics to PostScript. Please wait..."]
    update idletasks
    set ps [renderPostscript [file join $jobDir spool] $path]
    assertSaved $d
    set scalars [dict create design $path design_hash $hash cadence_root $cadenceRoot \
        root [file normalize $root] ghostscript [file normalize $ghostscript] postscript $ps netlist_format $format]
    set manifest [file join $jobDir job.json]
    writeUtf8 $manifest [jobJson $scalars $selected $printedPages $bom $filter]
    variable workerChannel
    set workerChannel [open [list | $worker run $manifest 2>@1] r]
    fconfigure $workerChannel -blocking 0 -encoding utf-8
    fileevent $workerChannel readable ::TriExport::workerReadable
    set statusText [tr "Generating the netlist, PDF and BOM..."]
    after 500 ::TriExport::poll
}
proc ::TriExport::workerReadable {} {
    variable workerChannel
    variable jobDir
    if {$workerChannel eq ""} { return }
    set output [read $workerChannel]
    if {$output ne ""} {
        set f [open [file join $jobDir worker-console.log] a]
        fconfigure $f -encoding utf-8
        puts -nonewline $f $output
        close $f
    }
    if {[eof $workerChannel]} {
        fileevent $workerChannel readable {}
        catch {close $workerChannel} exitError
        set workerChannel ""
        set resultPath [file join $jobDir result.json]
        if {![file exists $resultPath]} {
            set status "The export worker stopped unexpectedly: $exitError"
            set result "\{\"ok\":false,\"error\":[jsonString $status],\"log\":[jsonString [file join $jobDir worker-console.log]]\}"
            writeUtf8 "$resultPath.tmp" $result
            file rename -force "$resultPath.tmp" $resultPath
        }
    }
}
proc ::TriExport::poll {} {
    variable jobDir
    variable statusText
    variable busy
    variable win
    variable workerChannel
    if {![winfo exists $win]} { return }
    set statusFile [file join $jobDir status.txt]
    if {[file exists $statusFile]} { catch {set statusText [tr [readUtf8 $statusFile]]} }
    set resultPath [file join $jobDir result.json]
    if {![file exists $resultPath] || $workerChannel ne ""} { after 500 ::TriExport::poll; return }
    set busy 0
    setControls $win 0
    if {[catch {set r [::json::json2dict [readUtf8 $resultPath]]} err]} {
        set statusText "[tr {Could not read the export result:}] [displayError $err]"
        return
    }
    if {[dict get $r ok]} {
        set statusText [tr "Exported [dict get $r pages] PDF pages and [dict get $r parts] BOM components to three files."]
        if {[dict exists $r bom_excluded]} {
            append statusText [tr " BOM excluded: [dict get $r bom_excluded]. Netlist: [dict get $r netlist_parts] components."]
        }
        showMessage -parent $win -title "Export complete" -icon info \
            -message "$statusText\n\n[dict get $r output]"
    } else {
        set statusText [tr "Export failed. No results were committed."]
        showMessage -parent $win -title "Export failed" -icon error \
            -message "[displayError [dict get $r error]]\n\n[tr {Log:}] [dict get $r log]"
    }
}
proc ::TriExport::enabled {args} { return true }
proc ::TriExport::openAction {args} {
    if {[catch {show} err options]} { reportError "Could not open the export window" $err $options }
    return true
}
proc ::TriExport::init {rootPath} {
    variable cadenceRoot
    variable registered
    if {$registered} { return }
    set cadenceRoot [file normalize $rootPath]
    RegisterAction "TriExportOpen" "::TriExport::enabled" "" "::TriExport::openAction" ""
    RegisterAction "TriExportEnable" "::TriExport::enabled" "" "::TriExport::enabled" ""
    InsertXMLMenu [list [list "TriExportMenu"] "1" "Help" \
        [list "popup" [tr "TriE&xport"] "0" "TriExportEnable" "TriExportEnable" "" ""] ""]
    InsertXMLMenu [list [list "TriExportMenu" "TriExportRun"] "" "" \
        [list "action" [tr "Export Files..."] "0" "TriExportOpen" "TriExportEnable" "" "" "" [tr "Select pages and export netlist, PDF and BOM"]] ""]
    RefreshMenu
    set registered 1
}
