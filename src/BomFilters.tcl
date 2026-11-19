# BOM-only rules. This file is loaded by TriExport.tcl; it never edits a design.
namespace eval ::TriExport {
    variable bomFilter [dict create enabled 0 include_match any rules {}]
    variable bomFilterLoadError ""
    variable bomSummary "BOM: all components"
    variable bomEnabled 0
    variable bomIncludeMatch any
    variable bomRules {}
    variable bomEditIndex -1
    variable bomAction exclude
    variable bomField Reference
    variable bomProperty ""
    variable bomOperator equals
    variable bomValue ""
    variable bomSampleRef ""
    variable bomFields [dict create Reference ref Value value {PCB Footprint} footprint \
        {Part Number} part_number Manufacturer manufacturer Description description \
        {DNP / DNI} dnp {Part color} color {Custom property} property]
}

proc ::TriExport::defaultBomFilter {} { return [dict create enabled 0 include_match any rules {}] }
proc ::TriExport::validateBomFilter {config} {
    foreach key {enabled include_match rules} {
        if {![dict exists $config $key]} { error "Missing BOM filter setting: $key" }
    }
    if {![string is boolean -strict [dict get $config enabled]]} { error "Invalid BOM filter enable setting." }
    dict set config enabled [expr {!![dict get $config enabled]}]
    if {[dict get $config include_match] ni {any all}} { error "Choose any or all for include rules." }
    if {[llength [dict get $config rules]] > 100} { error "BOM filters support up to 100 rules." }
    foreach rule [dict get $config rules] {
        foreach key {action field property op value} {
            if {![dict exists $rule $key]} { error "Missing BOM rule field: $key" }
        }
        if {[dict get $rule action] ni {include exclude}} { error "Choose include or exclude." }
        set field [dict get $rule field]
        if {$field ni {ref value footprint part_number manufacturer description dnp color property}} { error "Unknown BOM field." }
        set op [dict get $rule op]
        if {$op ni {equals not_equals contains not_contains glob is_empty not_empty}} { error "Unknown BOM operator." }
        set value [dict get $rule value]
        if {$field eq "property" && [string trim [dict get $rule property]] eq ""} { error "Enter a custom property name." }
        if {$op ni {is_empty not_empty} && [string trim $value] eq ""} { error "Enter a value, or choose is_empty / not_empty." }
        if {$field eq "color" && ($op ni {equals not_equals} || ![regexp {^[0-9]+$} $value])} {
            error "Part color requires equals / not_equals and a numeric color ID. Use Read color from a reference."
        }
        if {[string length $value] > 1024 || [string length [dict get $rule property]] > 1024} {
            error "BOM filter names and values must be at most 1024 characters."
        }
    }
    return $config
}
proc ::TriExport::bomFilterJson {config} {
    set config [validateBomFilter $config]
    set enabled [expr {[dict get $config enabled] ? "true" : "false"}]
    return "\{\"enabled\":$enabled,\"include_match\":[jsonString [dict get $config include_match]],\"rules\":[jsonObjects [dict get $config rules]]\}"
}
proc ::TriExport::bomRowsJson {rows} {
    set encoded {}
    foreach row $rows {
        set fields {}
        dict for {key value} $row {
            if {$key eq "filter_values"} {
                lappend fields "[jsonString $key]:[jsonObject $value]"
            } else {
                lappend fields "[jsonString $key]:[jsonString $value]"
            }
        }
        lappend encoded "\{[join $fields ,]\}"
    }
    return "\[[join $encoded ,]\]"
}
proc ::TriExport::partColor {occ} {
    set state [DboState]
    try {
        # 17.2 documents GetPartInst(DboState&) and the inherited
        # DboGraphicInstance::GetColor(DboState&), returning ColorT.
        set part [$occ GetPartInst $state]
        if {$part in {NULL 0 ""} || ![$state OK]} { error "Could not read the schematic part for its color." }
        set color [$part GetColor $state]
        if {![$state OK] || ![regexp {^[0-9]+$} $color]} { error "Could not read the stored part color." }
        return $color
    } finally { $state -delete }
}
proc ::TriExport::filterProperty {occ name} {
    set key [DboTclHelper_sMakeCString $name]
    set val [DboTclHelper_sMakeCString]
    try {
        # NC is the documented case-insensitive effective-property lookup.
        # Capture 17.2 returns ORDBDLL-1021 (Object Not Found) for an
        # absent property. Other failures must not become empty matches.
        set state [$occ GetEffectivePropStringValueNC $key $val]
        try {
            if {![$state OK]} {
                if {[$state Code] == 1021} { return "" }
                error "Could not read BOM filter property '$name' (Capture error [$state Code])."
            }
            return [DboTclHelper_sGetConstCharPtr $val]
        } finally { $state -delete }
    } finally { releaseString $key; releaseString $val }
}
proc ::TriExport::captureFilterValues {occ row config} {
    if {$config eq "" || ![dict get $config enabled]} { return $row }
    foreach rule [dict get $config rules] {
        switch -- [dict get $rule field] {
            color {
                if {![dict exists $row color]} { dict set row color [partColor $occ] }
            }
            property {
                set name [dict get $rule property]
                if {![dict exists $row filter_values $name]} {
                    dict set row filter_values $name [filterProperty $occ $name]
                }
            }
        }
    }
    return $row
}
proc ::TriExport::updateBomSummary {} {
    variable bomFilter
    variable bomFilterLoadError
    variable bomSummary
    if {$bomFilterLoadError ne ""} { set bomSummary "BOM: settings need correction"; return }
    if {![dict get $bomFilter enabled] || ![llength [dict get $bomFilter rules]]} {
        set bomSummary "BOM: all components"
    } else {
        set bomSummary "BOM: [llength [dict get $bomFilter rules]] rules enabled; netlist includes all components"
    }
}
proc ::TriExport::bomDraft {} {
    return [validateBomFilter [dict create enabled $::TriExport::bomEnabled \
        include_match $::TriExport::bomIncludeMatch rules $::TriExport::bomRules]]
}
proc ::TriExport::bomRuleLabel {rule} {
    variable bomFields
    if {[dict get $rule field] eq "property"} { return "Property: [dict get $rule property]" }
    dict for {label id} $bomFields { if {$id eq [dict get $rule field]} { return $label } }
}
proc ::TriExport::refreshBomRuleList {} {
    set tree $::TriExport::win.bomFilters.rules
    foreach child [$tree children {}] { $tree delete $child }
    set index 0
    foreach rule $::TriExport::bomRules {
        $tree insert {} end -id r$index -values [list [dict get $rule action] [bomRuleLabel $rule] \
            [dict get $rule op] [dict get $rule value]]
        incr index
    }
}
proc ::TriExport::resetBomRule {} {
    set ::TriExport::bomEditIndex -1
    set ::TriExport::bomAction exclude
    set ::TriExport::bomField Reference
    set ::TriExport::bomProperty ""
    set ::TriExport::bomOperator equals
    set ::TriExport::bomValue ""
}
proc ::TriExport::selectBomRule {} {
    set selected [$::TriExport::win.bomFilters.rules selection]
    if {![llength $selected]} { return }
    set index [string range [lindex $selected 0] 1 end]
    set rule [lindex $::TriExport::bomRules $index]
    set ::TriExport::bomEditIndex $index
    set ::TriExport::bomAction [dict get $rule action]
    set ::TriExport::bomProperty [dict get $rule property]
    set ::TriExport::bomOperator [dict get $rule op]
    set ::TriExport::bomValue [dict get $rule value]
    dict for {label id} $::TriExport::bomFields {
        if {$id eq [dict get $rule field]} { set ::TriExport::bomField $label }
    }
}
proc ::TriExport::storeBomRule {replace} {
    set rule [dict create action $::TriExport::bomAction field [dict get $::TriExport::bomFields $::TriExport::bomField] \
        property [string trim $::TriExport::bomProperty] op $::TriExport::bomOperator value $::TriExport::bomValue]
    validateBomFilter [dict create enabled 1 include_match any rules [list $rule]]
    if {$replace} {
        set index $::TriExport::bomEditIndex
        if {$index < 0 || $index >= [llength $::TriExport::bomRules]} { error "Select a rule to update." }
        set ::TriExport::bomRules [lreplace $::TriExport::bomRules $index $index $rule]
    } else {
        if {[llength $::TriExport::bomRules] >= 100} { error "BOM filters support up to 100 rules." }
        lappend ::TriExport::bomRules $rule
    }
    set ::TriExport::bomEnabled 1
    refreshBomRuleList
    resetBomRule
}
proc ::TriExport::removeBomRule {} {
    set index $::TriExport::bomEditIndex
    if {$index < 0 || $index >= [llength $::TriExport::bomRules]} { error "Select a rule to remove." }
    set ::TriExport::bomRules [lreplace $::TriExport::bomRules $index $index]
    refreshBomRuleList
    resetBomRule
}
proc ::TriExport::readBomSampleColor {} {
    set ref [string trim $::TriExport::bomSampleRef]
    if {$ref eq ""} { error "Enter a reference of the color to match, for example R1." }
    set d [activeDesign]
    set path [assertSaved $d]
    if {![string equal -nocase $path [file normalize $::TriExport::designPath]]} {
        error "The active design changed. Close BOM Filters and refresh the page list."
    }
    set sample [dict create action exclude field color property {} op equals value 0]
    set rows [enumerateBom $d [dict create enabled 1 include_match any rules [list $sample]]]
    set colors {}
    foreach row $rows {
        if {[string equal -nocase [dict get $row ref] $ref]} { lappend colors [dict get $row color] }
    }
    set colors [lsort -unique $colors]
    if {[llength $colors] == 0} { error "Reference $ref was not found in the current design." }
    if {[llength $colors] != 1} { error "Units of $ref have different colors. Choose a reference with one stored color." }
    set ::TriExport::bomField "Part color"
    set ::TriExport::bomOperator equals
    set ::TriExport::bomValue [lindex $colors 0]
}
proc ::TriExport::applyBomFilters {} {
    variable bomFilter
    variable bomFilterLoadError
    set candidate [bomDraft]
    set previous $bomFilter
    set previousError $bomFilterLoadError
    set bomFilter $candidate
    set bomFilterLoadError ""
    try {
        saveSettings
    } on error {message options} {
        set bomFilter $previous
        set bomFilterLoadError $previousError
        return -options $options $message
    }
    updateBomSummary
    closeBomFilters
}
proc ::TriExport::closeBomFilters {} {
    if {$::TriExport::busy} { return }
    destroy $::TriExport::win.bomFilters
}
proc ::TriExport::bomEditorAction {command args} {
    if {$::TriExport::busy} { return }
    if {[catch {$command {*}$args} message]} {
        tk_messageBox -parent $::TriExport::win.bomFilters -title "BOM Filters" -icon error -message $message
    }
}
proc ::TriExport::showBomFilters {} {
    if {$::TriExport::busy} { return }
    set w $::TriExport::win.bomFilters
    if {[winfo exists $w]} { raise $w; return }
    set ::TriExport::bomEnabled [dict get $::TriExport::bomFilter enabled]
    set ::TriExport::bomIncludeMatch [dict get $::TriExport::bomFilter include_match]
    set ::TriExport::bomRules [dict get $::TriExport::bomFilter rules]
    resetBomRule
    toplevel $w
    wm title $w "BOM Filters - TriExport"
    wm transient $w $::TriExport::win
    wm geometry $w 850x610
    wm minsize $w 750 580
    wm protocol $w WM_DELETE_WINDOW ::TriExport::closeBomFilters
    ttk::frame $w.top -padding 12
    pack $w.top -fill x
    ttk::checkbutton $w.top.enabled -text "Enable BOM filters" -variable ::TriExport::bomEnabled
    ttk::label $w.top.matchLabel -text "Include rules match"
    ttk::combobox $w.top.match -textvariable ::TriExport::bomIncludeMatch -state readonly -values {any all} -width 7
    pack $w.top.enabled $w.top.matchLabel $w.top.match -side left -padx {0 14}
    ttk::label $w.help -text "Exclusions always win. No include rules = include all. Text matches ignore case and outer spaces.\nRules match any unit of a physical component. Filtering affects BOM only; netlist and PDF are unchanged." -wraplength 800
    pack $w.help -anchor w -padx 12 -pady {0 8}
    ttk::treeview $w.rules -columns {action field op value} -show headings -selectmode browse -height 7
    foreach {id title width} {action Action 80 field Field 180 op Operator 120 value Value 340} {
        $w.rules heading $id -text $title
        $w.rules column $id -width $width -minwidth 60
    }
    bind $w.rules <<TreeviewSelect>> ::TriExport::selectBomRule
    pack $w.rules -fill both -expand 1 -padx 12
    ttk::frame $w.edit -padding 12
    pack $w.edit -fill x
    set row 0
    foreach {name label variable values} {
        action Action bomAction {exclude include}
        field Field bomField {}
        op Operator bomOperator {equals not_equals contains not_contains glob is_empty not_empty}
    } {
        if {$name eq "field"} { set values [dict keys $::TriExport::bomFields] }
        ttk::label $w.edit.${name}Label -text $label
        ttk::combobox $w.edit.$name -textvariable ::TriExport::$variable -state readonly -values $values
        grid $w.edit.${name}Label -row $row -column 0 -sticky w -padx {0 10} -pady 2
        grid $w.edit.$name -row $row -column 1 -sticky ew -pady 2
        incr row
    }
    foreach {name label variable} {property {Custom property name} bomProperty value {Value / wildcard pattern} bomValue} {
        ttk::label $w.edit.${name}Label -text $label
        ttk::entry $w.edit.$name -textvariable ::TriExport::$variable
        grid $w.edit.${name}Label -row $row -column 0 -sticky w -padx {0 10} -pady 2
        grid $w.edit.$name -row $row -column 1 -sticky ew -pady 2
        incr row
    }
    grid columnconfigure $w.edit 1 -weight 1
    ttk::frame $w.actions -padding {12 0 12 8}
    pack $w.actions -fill x
    foreach {name label command} {add {Add rule} {::TriExport::storeBomRule 0} update {Update selected} {::TriExport::storeBomRule 1} remove {Remove selected} {::TriExport::removeBomRule} new {Clear input} {::TriExport::resetBomRule}} {
        ttk::button $w.actions.$name -text $label -command [list ::TriExport::bomEditorAction {*}$command]
        pack $w.actions.$name -side left -padx {0 8}
    }
    ttk::frame $w.color -padding {12 0 12 8}
    pack $w.color -fill x
    ttk::label $w.color.label -text "Color sample reference"
    ttk::entry $w.color.ref -textvariable ::TriExport::bomSampleRef -width 14
    ttk::button $w.color.read -text "Read color" -command {::TriExport::bomEditorAction ::TriExport::readBomSampleColor}
    pack $w.color.label $w.color.ref $w.color.read -side left -padx {0 8}
    ttk::label $w.colorHelp -text "Part color uses Capture's stored color ID. Enter a same-color reference and click Read color, then Add rule.\nSelection highlights, pin/text colors and a custom Color property are separate from the part color." -wraplength 800
    pack $w.colorHelp -anchor w -padx 12
    ttk::frame $w.bottom -padding 12
    pack $w.bottom -fill x
    ttk::button $w.bottom.cancel -text "Cancel" -command ::TriExport::closeBomFilters
    ttk::button $w.bottom.save -text "Save filters" -command {::TriExport::bomEditorAction ::TriExport::applyBomFilters}
    pack $w.bottom.cancel $w.bottom.save -side right -padx 4
    refreshBomRuleList
}
