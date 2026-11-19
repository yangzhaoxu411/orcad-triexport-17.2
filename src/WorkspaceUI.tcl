# Workspace UI. Styles and bindings are scoped to this plugin; no global theme change.
namespace eval ::TriExport {
    variable view overview
    variable pageQuery ""
    variable visiblePages {}
    variable designTitle ""
    variable overviewPdf ""
    variable overviewBom ""
    variable summaryText ""
    variable outputNames ""
    variable lastOutput ""
    variable environmentStatus ""
}
proc ::TriExport::uiStyles {} {
    foreach {name args} {
        TriExport.TFrame {-background #f4f6fa}
        Card.TriExport.TFrame {-background #ffffff}
        TriExport.TLabel {-background #f4f6fa -foreground #172b4d -font {{Microsoft YaHei UI} 10}}
        Card.TriExport.TLabel {-background #ffffff -foreground #172b4d -font {{Microsoft YaHei UI} 10}}
        Muted.TriExport.TLabel {-background #f4f6fa -foreground #5d6b82 -font {{Microsoft YaHei UI} 9}}
        Hint.Card.TriExport.TLabel {-background #ffffff -foreground #5d6b82 -font {{Microsoft YaHei UI} 9}}
        Title.TriExport.TLabel {-background #f4f6fa -foreground #172b4d -font {{Microsoft YaHei UI} 18 bold}}
        Heading.Card.TriExport.TLabel {-background #ffffff -foreground #172b4d -font {{Microsoft YaHei UI} 11 bold}}
        TriExport.TButton {-font {{Microsoft YaHei UI} 10} -padding {12 7}}
        TriExport.TEntry {-font {{Microsoft YaHei UI} 10} -padding {7 6}}
        TriExport.TCombobox {-font {{Microsoft YaHei UI} 10} -padding {7 6}}
        TriExport.TCheckbutton {-background #ffffff -font {{Microsoft YaHei UI} 10} -padding {4 5}}
        TriExport.TRadiobutton {-background #ffffff -font {{Microsoft YaHei UI} 10} -padding {4 7}}
        TriExport.Treeview {-font {{Microsoft YaHei UI} 10} -rowheight 34 -background #ffffff -fieldbackground #ffffff -borderwidth 0}
        TriExport.Treeview.Heading {-font {{Microsoft YaHei UI} 9 bold} -padding {8 9}}
        Error.TriExport.TLabel {-background #f4f6fa -foreground #a12828 -font {{Microsoft YaHei UI} 9}}
    } { ttk::style configure $name {*}$args }
    ttk::style map TriExport.Treeview -background {selected #e6efff} -foreground {selected #173d78}
}
proc ::TriExport::primaryButton {path text command} {
    button $path -text [tr $text] -command $command -background #245dd8 -foreground white \
        -activebackground #1949b2 -activeforeground white -disabledforeground #c9d6f1 \
        -relief flat -borderwidth 0 -padx 24 -pady 11 -cursor hand2 -font {{Microsoft YaHei UI} 10 bold}
    return $path
}
proc ::TriExport::card {path title} {
    ttk::frame $path -style Card.TriExport.TFrame -padding 18
    ttk::label $path.title -text [tr $title] -style Heading.Card.TriExport.TLabel
    pack $path.title -anchor w -pady {0 12}
    return $path
}
proc ::TriExport::pageHeading {path title subtitle} {
    ttk::label $path.title -text [tr $title] -style Title.TriExport.TLabel
    ttk::label $path.subtitle -text [tr $subtitle] -style Muted.TriExport.TLabel -wraplength 700
    pack $path.title -anchor w
    pack $path.subtitle -anchor w -pady {5 18}
}
proc ::TriExport::showView {name} {
    variable win
    variable busy
    if {$busy} { return }
    set ::TriExport::view $name
    foreach tab {overview pdf bom environment} {
        $win.body.nav.$tab configure -background [expr {$tab eq $name ? "#e4edff" : "#f4f6fa"}] \
            -foreground [expr {$tab eq $name ? "#1648a3" : "#526079"}]
    }
    if {$name in {overview environment}} {
        raise $win.body.content.${name}Scroll
        raise $win.body.content.$name
    } else { raise $win.body.content.$name }
    if {$name eq "bom"} { refreshBomPanel }
}
proc ::TriExport::updateOverview {} {
    variable pages
    variable checked
    variable bomFilter
    variable netlistFormat
    set selected 0
    foreach index [array names checked] { if {$checked($index)} { incr selected } }
    set ::TriExport::selectedCount [tr "$selected / [llength $pages] pages selected"]
    set ::TriExport::overviewPdf [tr "PDF: $selected selected pages"]
    if {$::TriExport::bomFilterLoadError ne ""} {
        set ::TriExport::overviewBom [tr {BOM: settings need correction}]
    } elseif {![dict get $bomFilter enabled]} {
        set ::TriExport::overviewBom [tr "BOM: all components"]
    } else {
        set ::TriExport::overviewBom [tr "BOM: [llength [dict get $bomFilter rules]] active rules"]
    }
    set ::TriExport::summaryText "$::TriExport::overviewPdf    |    $::TriExport::overviewBom"
    set extension [expr {$netlistFormat eq "Allegro (ZIP)" ? "_allegro.zip" : ".asc"}]
    set ::TriExport::outputNames "[tr {Output file example:}] design$extension  +  design.pdf  +  design.csv"
    set ::TriExport::designTitle [expr {$::TriExport::designPath eq "" ? [tr {No design selected}] : [file tail $::TriExport::designPath]}]
}
proc ::TriExport::countSelected {} { updateOverview }
proc ::TriExport::selectAll {value {visibleOnly 0}} {
    if {$::TriExport::busy} { return }
    set indices [expr {$visibleOnly ? $::TriExport::visiblePages : [array names ::TriExport::checked]}]
    foreach index $indices { set ::TriExport::checked($index) $value }
    countSelected
}
proc ::TriExport::refreshPages {} {
    if {$::TriExport::busy} { return }
    set d [activeDesign]
    set path [getString $d GetName]
    set fresh [enumeratePages $d]
    set old [dict create]
    set same [string equal -nocase [file normalize $path] [file normalize $::TriExport::designPath]]
    if {$same} {
        set i 0
        foreach p $::TriExport::pages {
            if {[info exists ::TriExport::checked($i)]} {dict set old [list [dict get $p schematic] [dict get $p name]] $::TriExport::checked($i)}
            incr i
        }
    }
    set ::TriExport::pages $fresh
    set ::TriExport::designPath $path
    array unset ::TriExport::checked
    set i 0
    foreach p $fresh {
        set key [list [dict get $p schematic] [dict get $p name]]
        set ::TriExport::checked($i) [expr {$same && [dict size $old] ? ([dict exists $old $key] ? [dict get $old $key] : 0) : 1}]
        incr i
    }
    renderPageList
    countSelected
}
proc ::TriExport::renderPageList {} {
    variable win
    set canvas $win.body.content.pdf.list.canvas
    if {![winfo exists $canvas]} { return }
    foreach child [winfo children $canvas.items] {destroy $child}
    set ::TriExport::visiblePages {}
    set query [string tolower [string trim $::TriExport::pageQuery]]
    set i 0
    foreach page $::TriExport::pages {
        set label "[dict get $page schematic] / [dict get $page name]"
        if {$query eq "" || [string first $query [string tolower $label]] >= 0} {
            lappend ::TriExport::visiblePages $i
            ttk::checkbutton $canvas.items.p$i -text $label -variable ::TriExport::checked($i) \
                -style TriExport.TCheckbutton -command ::TriExport::countSelected
            pack $canvas.items.p$i -anchor w -fill x -padx 12 -pady 2
            bind $canvas.items.p$i <MouseWheel> [list ::TriExport::scrollPages %D]
        }
        incr i
    }
    if {![llength $::TriExport::visiblePages]} {
        ttk::label $canvas.items.empty -text [tr {No matching pages. Clear the search to see all pages.}] -style Hint.Card.TriExport.TLabel
        pack $canvas.items.empty -padx 18 -pady 28
    }
    $canvas yview moveto 0
}
proc ::TriExport::scrollPages {delta} {
    if {$::TriExport::busy} {return}
    set units [expr {$delta > 0 ? -3 : 3}]
    $::TriExport::win.body.content.pdf.list.canvas yview scroll $units units
}
proc ::TriExport::sizeCanvas {} {
    set c $::TriExport::win.body.content.pdf.list.canvas
    $c configure -scrollregion [$c bbox all]
}
proc ::TriExport::scrollPanel {w} {
    set host ${w}Scroll
    ttk::frame $host -style TriExport.TFrame
    grid $host -row 0 -column 0 -sticky nsew
    canvas $host.canvas -background #f4f6fa -highlightthickness 0 -width 300 -height 300
    ttk::scrollbar $host.scroll -orient vertical -command [list $host.canvas yview]
    $host.canvas configure -yscrollcommand [list $host.scroll set]
    pack $host.scroll -side right -fill y
    pack $host.canvas -fill both -expand 1
    # Tk permits a sibling of the canvas's parent as the embedded window.
    $host.canvas create window 0 0 -window $w -anchor nw -tags content
    bind $host.canvas <Configure> [list $host.canvas itemconfigure content -width %w]
    bind $w <Configure> [list ::TriExport::resizePanel $host.canvas]
    bind $host.canvas <MouseWheel> [list ::TriExport::wheelPanel $host.canvas %D]
}
proc ::TriExport::resizePanel {canvas} { $canvas configure -scrollregion [$canvas bbox all] }
proc ::TriExport::wheelPanel {canvas delta} {
    $canvas yview scroll [expr {$delta > 0 ? -3 : 3}] units
}
proc ::TriExport::bindPanelWheel {parent canvas} {
    bind $parent <MouseWheel> [list ::TriExport::wheelPanel $canvas %D]
    foreach child [winfo children $parent] {bindPanelWheel $child $canvas}
}
proc ::TriExport::resizeFooter {width} {
    set w $::TriExport::win.bottom
    set available [expr {max(190, $width - [winfo reqwidth $w.export] - [winfo reqwidth $w.open] - 84)}]
    $w.summary configure -wraplength $available
    $w.status configure -wraplength $available
}
proc ::TriExport::saveEnvironment {} {
    if {$::TriExport::busy} {return}
    if {[catch {saveSettings} message]} {set ::TriExport::environmentStatus [displayError $message];return}
    set issues {}
    if {![file isfile $::TriExport::ghostscript] || [string tolower [file tail $::TriExport::ghostscript]] ni {gswin64c.exe gswin32c.exe}} {
        lappend issues [tr {Select the Ghostscript executable in its bin folder.}]
    }
    if {[catch {capIsPrinterDriverAvailable $::TriExport::driver} available] || !$available} {lappend issues [tr {The selected PostScript driver is unavailable.}]}
    set ::TriExport::environmentStatus [expr {[llength $issues] ? [join $issues "\n"] : [tr {Settings saved. Ghostscript and the printer driver are available.}]}]
}
proc ::TriExport::openOutput {} {
    if {$::TriExport::lastOutput ne "" && [file isdirectory $::TriExport::lastOutput]} {
        if {[catch {exec explorer.exe [file nativename $::TriExport::lastOutput] &} message]} {showMessage -parent $::TriExport::win -icon error -message [displayError $message]}
    }
}
proc ::TriExport::validateUi {} {
    if {[winfo exists $::TriExport::win.bomRule]} {error "Finish or cancel the current BOM rule before exporting."}
    if {![file isdirectory $::TriExport::root]} {showView overview;focus $::TriExport::win.body.content.overview.destination.path;error "Choose an existing output root folder."}
    set count 0
    foreach i [array names ::TriExport::checked] {incr count $::TriExport::checked($i)}
    if {!$count} {showView pdf;error "Select at least one schematic page."}
    if {$::TriExport::bomFilterLoadError ne ""} {showView bom;error $::TriExport::bomFilterLoadError}
    if {[dict get $::TriExport::bomFilter enabled] && ![llength [dict get $::TriExport::bomFilter rules]]} {showView bom;error "Add at least one BOM rule, or choose all components."}
    if {![file isfile $::TriExport::ghostscript] || [string tolower [file tail $::TriExport::ghostscript]] ni {gswin64c.exe gswin32c.exe}} {
        showView environment;error "Select the Ghostscript executable in its bin folder."
    }
}
proc ::TriExport::setControls {parent disabled} {
    foreach child [winfo children $parent] {
        set class [winfo class $child]
        if {$class in {TButton TCheckbutton TRadiobutton TEntry TCombobox Treeview}} {
            $child state [expr {$disabled ? "disabled" : "!disabled"}]
        } elseif {$class eq "Button"} {
            $child configure -state [expr {$disabled ? "disabled" : "normal"}]
        }
        setControls $child $disabled
    }
    if {$parent eq $::TriExport::win} {
        if {$disabled} {
            $parent.bottom.export configure -text [tr {Exporting...}]
            pack $parent.progress -side bottom -fill x -before $parent.bottom
            $parent.progress start 15
        } else {
            $parent.bottom.export configure -text [tr {Export three files}]
            $parent.progress stop
            pack forget $parent.progress
            refreshBomButtons
            if {$::TriExport::lastOutput eq ""} {$parent.bottom.open state disabled}
        }
    }
}
proc ::TriExport::buildDialog {} {
    variable win
    package require json
    loadSettings
    if {$::TriExport::ghostscript eq ""} {set ::TriExport::ghostscript [findGhostscript]}
    uiStyles
    set ::TriExport::pageQuery ""
    set ::TriExport::lastOutput ""
    set ::TriExport::environmentStatus ""
    set ::TriExport::statusText [tr {Choose a folder, review the scope, then export.}]
    toplevel $win
    wm title $win "TriExport $::TriExport::version - OrCAD 17.2"
    $win configure -background #f4f6fa
    set width [expr {max(900, min(1040, [winfo screenwidth $win] - 60))}]
    set height [expr {max(690, min(780, [winfo screenheight $win] - 80))}]
    wm geometry $win ${width}x${height}
    wm minsize $win 900 690
    wm protocol $win WM_DELETE_WINDOW ::TriExport::closeWindow
    ttk::frame $win.header -style Card.TriExport.TFrame -padding {24 16}
    pack $win.header -fill x
    ttk::label $win.header.brand -text TriExport -style Card.TriExport.TLabel -font {{Segoe UI} 21 bold}
    ttk::label $win.header.design -textvariable ::TriExport::designTitle -style Hint.Card.TriExport.TLabel -width 28
    ttk::label $win.header.version -text "OrCAD 17.2  /  $::TriExport::version" -style Hint.Card.TriExport.TLabel
    pack $win.header.brand $win.header.design -side left -padx {0 22}
    pack $win.header.version -side right
    # Pack the footer before the expanding workspace so its action never vanishes.
    ttk::frame $win.bottom -style Card.TriExport.TFrame -padding {24 14}
    pack $win.bottom -side bottom -fill x
    primaryButton $win.bottom.export {Export three files} ::TriExport::start
    ttk::button $win.bottom.open -text [tr {Open output folder}] -style TriExport.TButton -command ::TriExport::openOutput
    $win.bottom.open state disabled
    pack $win.bottom.export $win.bottom.open -side right -padx {12 0}
    ttk::label $win.bottom.summary -textvariable ::TriExport::summaryText -style Heading.Card.TriExport.TLabel -wraplength 560
    ttk::label $win.bottom.status -textvariable ::TriExport::statusText -style Hint.Card.TriExport.TLabel -wraplength 560
    pack $win.bottom.summary $win.bottom.status -anchor w -pady 2
    bind $win.bottom <Configure> [list ::TriExport::resizeFooter %w]
    ttk::progressbar $win.progress -mode indeterminate
    ttk::frame $win.body -style TriExport.TFrame -padding {16 20 24 20}
    pack $win.body -fill both -expand 1
    ttk::frame $win.body.nav -style TriExport.TFrame -width 158
    pack $win.body.nav -side left -fill y -padx {0 24}
    foreach {name label} {overview {Export overview} pdf {PDF pages} bom {BOM filters} environment {Environment}} {
        button $win.body.nav.$name -text [tr $label] -command [list ::TriExport::showView $name] \
            -anchor w -width 13 -relief flat -borderwidth 0 -padx 16 -pady 12 -cursor hand2 \
            -font {{Microsoft YaHei UI} 10 bold} -background #f4f6fa -foreground #526079 -activebackground #e4edff
        pack $win.body.nav.$name -fill x -pady {0 6}
    }
    ttk::frame $win.body.content -style TriExport.TFrame
    pack $win.body.content -fill both -expand 1
    grid rowconfigure $win.body.content 0 -weight 1
    grid columnconfigure $win.body.content 0 -weight 1
    foreach name {overview pdf bom environment} {
        ttk::frame $win.body.content.$name -style TriExport.TFrame
        if {$name in {overview environment}} {
            scrollPanel $win.body.content.$name
        } else {grid $win.body.content.$name -row 0 -column 0 -sticky nsew}
    }
    buildOverview $win.body.content.overview
    buildPdfPanel $win.body.content.pdf
    buildBomPanel $win.body.content.bom
    buildEnvironment $win.body.content.environment
    foreach name {overview environment} {
        bindPanelWheel $win.body.content.$name $win.body.content.${name}Scroll.canvas
    }
    updateFormatNote
    updateBomSummary
    refreshAction
    showView overview
}
proc ::TriExport::buildOverview {w} {
    pageHeading $w {Ready to export} {One export creates a new folder with exactly three files.}
    card $w.destination {1. Choose the output folder}
    pack $w.destination -fill x -pady {0 12}
    ttk::entry $w.destination.path -textvariable ::TriExport::root -style TriExport.TEntry
    ttk::button $w.destination.browse -text [tr {Browse...}] -style TriExport.TButton -command ::TriExport::chooseRoot
    pack $w.destination.browse -side right -padx {10 0}
    pack $w.destination.path -fill x -expand 1
    card $w.format {2. Choose the netlist format}
    pack $w.format -fill x -pady {0 12}
    foreach {name value title subtitle} {
        allegro {Allegro (ZIP)} {Allegro} {Native DAT files in one ZIP. Unzip before importing.}
        pads {PADS PowerPCB V3 (ASC)} {PADS PowerPCB V3} {One ASC file for import into PADS.}
    } {
        ttk::frame $w.format.$name -style Card.TriExport.TFrame
        pack $w.format.$name -side left -fill both -expand 1
        ttk::radiobutton $w.format.$name.choice -text $title -value $value -variable ::TriExport::netlistFormat -style TriExport.TRadiobutton -command ::TriExport::formatChanged
        ttk::label $w.format.$name.hint -text [tr $subtitle] -style Hint.Card.TriExport.TLabel -wraplength 275
        pack $w.format.$name.choice -anchor w
        pack $w.format.$name.hint -anchor w -padx {26 8} -pady {0 5}
    }
    card $w.scope {3. Review the export scope}
    pack $w.scope -fill x -pady {0 12}
    foreach {name variable label target} {pdf overviewPdf {Choose pages} pdf bom overviewBom {Manage rules} bom} {
        ttk::frame $w.scope.$name -style Card.TriExport.TFrame
        pack $w.scope.$name -fill x -pady 4
        ttk::label $w.scope.$name.text -textvariable ::TriExport::$variable -style Card.TriExport.TLabel
        ttk::button $w.scope.$name.edit -text [tr $label] -style TriExport.TButton -command [list ::TriExport::showView $target]
        pack $w.scope.$name.text -side left
        pack $w.scope.$name.edit -side right
    }
    ttk::label $w.files -textvariable ::TriExport::outputNames -style Muted.TriExport.TLabel -wraplength 550
    ttk::label $w.note -text [tr {PDF selection and BOM rules are independent. The netlist always includes the full design.}] -style Muted.TriExport.TLabel -wraplength 720
    pack $w.files $w.note -anchor w -pady {4 0}
}
proc ::TriExport::buildPdfPanel {w} {
    pageHeading $w {Choose PDF pages} {Checked pages are merged into one PDF, in the order shown.}
    ttk::frame $w.tools -style TriExport.TFrame
    pack $w.tools -fill x -pady {0 10}
    ttk::entry $w.tools.search -textvariable ::TriExport::pageQuery -style TriExport.TEntry -width 24
    ttk::label $w.tools.label -text [tr {Search pages}] -style TriExport.TLabel
    ttk::button $w.tools.refresh -text [tr {Refresh}] -style TriExport.TButton -command ::TriExport::refreshAction
    pack $w.tools.label $w.tools.search -side left -padx {0 8}
    pack $w.tools.refresh -side right
    bind $w.tools.search <KeyRelease> ::TriExport::renderPageList
    ttk::frame $w.selection -style TriExport.TFrame
    pack $w.selection -fill x -pady {0 10}
    ttk::label $w.selection.count -textvariable ::TriExport::selectedCount -style TriExport.TLabel
    ttk::button $w.selection.all -text [tr {Select listed pages}] -style TriExport.TButton -command {::TriExport::selectAll 1 1}
    ttk::button $w.selection.none -text [tr {Clear listed pages}] -style TriExport.TButton -command {::TriExport::selectAll 0 1}
    pack $w.selection.count -side left
    pack $w.selection.none $w.selection.all -side right -padx {8 0}
    ttk::frame $w.paper -style TriExport.TFrame
    pack $w.paper -side bottom -fill x -pady {14 0}
    ttk::label $w.paper.label -text [tr {Paper size}] -style TriExport.TLabel
    localizedChoice $w.paper.choice -textvariable ::TriExport::paper -state readonly -style TriExport.TCombobox \
        -values {{Original sheet size} {A4 landscape} {A3 landscape}} -width 20
    pack $w.paper.label $w.paper.choice -side left -padx {0 12}
    ttk::frame $w.list -style Card.TriExport.TFrame
    pack $w.list -fill both -expand 1
    canvas $w.list.canvas -background white -highlightthickness 0 -width 300 -height 200
    ttk::scrollbar $w.list.scroll -orient vertical -command [list $w.list.canvas yview]
    $w.list.canvas configure -yscrollcommand [list $w.list.scroll set]
    ttk::frame $w.list.canvas.items -style Card.TriExport.TFrame
    $w.list.canvas create window 0 0 -window $w.list.canvas.items -anchor nw -tags content
    bind $w.list.canvas.items <Configure> ::TriExport::sizeCanvas
    bind $w.list.canvas <Configure> [list $w.list.canvas itemconfigure content -width %w]
    bind $w.list.canvas <MouseWheel> [list ::TriExport::scrollPages %D]
    pack $w.list.scroll -side right -fill y
    pack $w.list.canvas -fill both -expand 1
}
proc ::TriExport::buildEnvironment {w} {
    pageHeading $w {Environment settings} {Configure once. These settings are remembered for later exports.}
    card $w.paths {PDF conversion}
    pack $w.paths -fill x -pady {0 12}
    ttk::label $w.paths.gsLabel -text Ghostscript -style Card.TriExport.TLabel
    pack $w.paths.gsLabel -anchor w -pady {0 6}
    ttk::frame $w.paths.gsRow -style Card.TriExport.TFrame
    pack $w.paths.gsRow -fill x
    ttk::entry $w.paths.gsRow.path -textvariable ::TriExport::ghostscript -style TriExport.TEntry
    ttk::button $w.paths.gsRow.browse -text [tr {Browse...}] -style TriExport.TButton -command ::TriExport::chooseGs
    pack $w.paths.gsRow.browse -side right -padx {10 0}
    pack $w.paths.gsRow.path -fill x -expand 1
    ttk::label $w.paths.gsHint -text [tr {Select gswin64c.exe from the Ghostscript bin folder.}] -style Hint.Card.TriExport.TLabel
    pack $w.paths.gsHint -anchor w -pady {7 20}
    ttk::label $w.paths.driverLabel -text [tr {PostScript printer driver}] -style Card.TriExport.TLabel
    ttk::entry $w.paths.driver -textvariable ::TriExport::driver -style TriExport.TEntry
    pack $w.paths.driverLabel -anchor w -pady {0 6}
    pack $w.paths.driver -fill x
    ttk::label $w.paths.driverHint -text [tr {Usually OrCADPS_17.2. Microsoft Print to PDF cannot replace it.}] -style Hint.Card.TriExport.TLabel -wraplength 650
    pack $w.paths.driverHint -anchor w -pady {7 0}
    ttk::button $w.check -text [tr {Save and check settings}] -style TriExport.TButton -command ::TriExport::saveEnvironment
    ttk::label $w.result -textvariable ::TriExport::environmentStatus -style TriExport.TLabel -wraplength 680
    pack $w.check -anchor w -pady {4 14}
    pack $w.result -anchor w
}
