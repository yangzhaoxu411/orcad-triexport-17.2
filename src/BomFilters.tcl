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
    if {$::TriExport::bomOperator ni {equals not_equals}} {set ::TriExport::bomOperator equals}
    set ::TriExport::bomValue [lindex $colors 0]
}

namespace eval ::TriExport {
    variable bomRuleError ""
    variable bomRuleHint ""
    variable bomPanelNote ""
    variable bomLastField Reference
}
proc ::TriExport::updateBomSummary {} {
    variable bomFilter
    if {$::TriExport::bomFilterLoadError ne ""} {
        set ::TriExport::bomSummary [tr {BOM: settings need correction}]
    } elseif {![dict get $bomFilter enabled]} {
        set ::TriExport::bomSummary [tr {BOM: all components}]
    } else {
        set ::TriExport::bomSummary [tr "BOM: [llength [dict get $bomFilter rules]] active rules"]
    }
    updateOverview
}
proc ::TriExport::bomRuleLabel {rule} {
    if {[dict get $rule field] eq "property"} {return [tr "Property: [dict get $rule property]"]}
    dict for {label id} $::TriExport::bomFields {if {$id eq [dict get $rule field]} {return [tr $label]}}
}
proc ::TriExport::commitBomConfig {candidate} {
    set candidate [validateBomFilter $candidate]
    set previous $::TriExport::bomFilter
    set previousError $::TriExport::bomFilterLoadError
    set ::TriExport::bomFilter $candidate
    set ::TriExport::bomFilterLoadError ""
    try {saveSettings} on error {message options} {
        set ::TriExport::bomFilter $previous
        set ::TriExport::bomFilterLoadError $previousError
        refreshBomPanel
        return -options $options $message
    }
    refreshBomPanel
    updateBomSummary
}
proc ::TriExport::bomModeChanged {} {
    if {$::TriExport::busy} {return}
    set candidate [dict replace $::TriExport::bomFilter enabled $::TriExport::bomEnabled include_match $::TriExport::bomIncludeMatch]
    if {[catch {commitBomConfig $candidate} message]} {set ::TriExport::bomPanelNote [displayError $message]}
}
proc ::TriExport::refreshBomPanel {} {
    set ::TriExport::bomEnabled [dict get $::TriExport::bomFilter enabled]
    set ::TriExport::bomIncludeMatch [dict get $::TriExport::bomFilter include_match]
    set tree $::TriExport::win.body.content.bom.list.rules
    if {![winfo exists $tree]} {return}
    set selected [$tree selection]
    foreach child [$tree children {}] {$tree delete $child}
    set i 0
    foreach rule [dict get $::TriExport::bomFilter rules] {
        set value [expr {[dict get $rule op] in {is_empty not_empty} ? [tr {No value needed}] : [dict get $rule value]}]
        $tree insert {} end -id r$i -values [list [tr [dict get $rule action]] [bomRuleLabel $rule] [tr [dict get $rule op]] $value]
        incr i
    }
    if {[llength $selected] && [$tree exists [lindex $selected 0]]} {$tree selection set [lindex $selected 0]}
    if {$::TriExport::bomFilterLoadError ne ""} {
        set ::TriExport::bomPanelNote [displayError $::TriExport::bomFilterLoadError]
    } elseif {!$i} {
        set ::TriExport::bomPanelNote [tr {No rules yet. Add a rule to exclude a color, property or reference.}]
    } elseif {!$::TriExport::bomEnabled} {
        set ::TriExport::bomPanelNote [tr {Rules are saved but inactive. All components will be exported.}]
    } else {set ::TriExport::bomPanelNote [tr {Rules are saved automatically. Exclusions take priority.}]}
    refreshBomButtons
}
proc ::TriExport::refreshBomButtons {} {
    set w $::TriExport::win.body.content.bom
    if {![winfo exists $w.list.rules]} {return}
    set selected [$w.list.rules selection]
    set state [expr {[llength $selected] && !$::TriExport::busy ? "!disabled" : "disabled"}]
    $w.actions.edit state $state
    $w.actions.remove state $state
    $w.mode.match state [expr {$::TriExport::bomEnabled && !$::TriExport::busy ? "!disabled" : "disabled"}]
}
proc ::TriExport::selectedBomIndex {} {
    set tree $::TriExport::win.body.content.bom.list.rules
    set selection [$tree selection]
    if {![llength $selection]} {error "Select a rule to update."}
    set index [string range [lindex $selection 0] 1 end]
    if {![string is integer -strict $index] || $index >= [llength [dict get $::TriExport::bomFilter rules]]} {error "Select a rule to update."}
    return $index
}
proc ::TriExport::removeBomRule {} {
    if {$::TriExport::busy} {return}
    if {[catch {
        set index [selectedBomIndex]
        set rules [lreplace [dict get $::TriExport::bomFilter rules] $index $index]
        set candidate [dict replace $::TriExport::bomFilter rules $rules]
        if {![llength $rules]} {dict set candidate enabled 0}
        commitBomConfig $candidate
    } message]} {set ::TriExport::bomPanelNote [displayError $message]}
}
proc ::TriExport::editSelectedBomRule {} {
    if {[catch {set index [selectedBomIndex]}]} {return}
    showBomRule $index
}
proc ::TriExport::showBomFilters {} { showView bom }
proc ::TriExport::closeBomRule {} {
    if {$::TriExport::busy} {return}
    set w $::TriExport::win.bomRule
    catch {grab release $w}
    destroy $w
}
proc ::TriExport::bomEditorAction {command args} {
    if {$::TriExport::busy} {return}
    set ::TriExport::bomRuleError ""
    if {[catch {$command {*}$args} message]} {set ::TriExport::bomRuleError [displayError $message]}
}
proc ::TriExport::saveBomRule {} {
    set field [dict get $::TriExport::bomFields $::TriExport::bomField]
    set property [expr {$field eq "property" ? [string trim $::TriExport::bomProperty] : ""}]
    set value [expr {$::TriExport::bomOperator in {is_empty not_empty} ? "" : $::TriExport::bomValue}]
    set rule [dict create action $::TriExport::bomAction field $field property $property op $::TriExport::bomOperator value $value]
    validateBomFilter [dict create enabled 1 include_match any rules [list $rule]]
    set rules [dict get $::TriExport::bomFilter rules]
    if {$::TriExport::bomEditIndex < 0} {lappend rules $rule} else {
        set rules [lreplace $rules $::TriExport::bomEditIndex $::TriExport::bomEditIndex $rule]
    }
    commitBomConfig [dict replace $::TriExport::bomFilter enabled 1 rules $rules]
    closeBomRule
}
proc ::TriExport::bomFieldChanged {} {
    set w $::TriExport::win.bomRule.form
    if {![winfo exists $w]} {return}
    set field [dict get $::TriExport::bomFields $::TriExport::bomField]
    if {$::TriExport::bomLastField ne $::TriExport::bomField} {
        set ::TriExport::bomValue ""
        set ::TriExport::bomSampleRef ""
        set ::TriExport::bomLastField $::TriExport::bomField
    }
    set choices [expr {$field eq "color" ? {equals not_equals} : {equals not_equals contains not_contains glob is_empty not_empty}}]
    if {$::TriExport::bomOperator ni $choices} {set ::TriExport::bomOperator equals}
    setChoiceOptions $w.op ::TriExport::bomOperator $choices
    foreach name {propertyLabel property colorLabel color valueLabel value} {grid remove $w.$name}
    if {$field eq "property"} {
        grid $w.propertyLabel -row 2 -column 0 -sticky w -padx {0 20} -pady 10
        grid $w.property -row 2 -column 1 -sticky ew -pady 10
    }
    if {$::TriExport::bomOperator ni {is_empty not_empty}} {
        grid $w.valueLabel -row 4 -column 0 -sticky w -padx {0 20} -pady 10
        grid $w.value -row 4 -column 1 -sticky ew -pady 10
    }
    $w.value configure -state [expr {$field eq "color" ? "readonly" : "normal"}]
    $w.valueLabel configure -text [tr [expr {$field eq "color" ? "Stored color ID" : "Value / wildcard pattern"}]]
    if {$field eq "color"} {
        grid $w.colorLabel -row 5 -column 0 -sticky w -padx {0 20} -pady 10
        grid $w.color -row 5 -column 1 -sticky ew -pady 10
        set ::TriExport::bomRuleHint [tr {Enter a same-color reference and read its color. Selection highlights and text colors are not matched.}]
    } elseif {$::TriExport::bomOperator in {is_empty not_empty}} {
        set ::TriExport::bomRuleHint [tr {No value is needed. A missing property is treated as empty.}]
    } elseif {$field eq "property"} {
        set ::TriExport::bomRuleHint [tr {Use the exact property name from Capture, such as Assembly Status. Example value: Not fitted.}]
    } elseif {$::TriExport::bomOperator eq "glob"} {
        set ::TriExport::bomRuleHint [tr {Example: R* matches all references starting with R. The * wildcard matches any text.}]
    } else {
        set ::TriExport::bomRuleHint [tr {Text matching ignores case and spaces at the start and end.}]
    }
}
proc ::TriExport::showBomRule {{index -1} {preset Reference}} {
    if {$::TriExport::busy} {return}
    set w $::TriExport::win.bomRule
    if {[winfo exists $w]} {raise $w;return}
    set ::TriExport::bomEditIndex $index
    set ::TriExport::bomAction exclude
    set ::TriExport::bomField $preset
    set ::TriExport::bomProperty ""
    set ::TriExport::bomOperator equals
    set ::TriExport::bomValue ""
    set ::TriExport::bomSampleRef ""
    set ::TriExport::bomRuleError ""
    if {$index >= 0} {
        set rule [lindex [dict get $::TriExport::bomFilter rules] $index]
        set ::TriExport::bomAction [dict get $rule action]
        set ::TriExport::bomOperator [dict get $rule op]
        set ::TriExport::bomProperty [dict get $rule property]
        set ::TriExport::bomValue [dict get $rule value]
        dict for {label id} $::TriExport::bomFields {if {$id eq [dict get $rule field]} {set ::TriExport::bomField $label}}
    }
    set ::TriExport::bomLastField $::TriExport::bomField
    toplevel $w
    $w configure -background #f4f6fa
    wm title $w "TriExport - BOM"
    wm transient $w $::TriExport::win
    wm geometry $w 660x570
    wm minsize $w 620 540
    wm protocol $w WM_DELETE_WINDOW ::TriExport::closeBomRule
    ttk::frame $w.header -style TriExport.TFrame -padding {24 22 24 10}
    pack $w.header -fill x
    ttk::label $w.header.title -text [tr [expr {$index < 0 ? "Add a BOM rule" : "Edit BOM rule"}]] -style Title.TriExport.TLabel
    ttk::label $w.header.note -text [tr {Save once to apply this rule. The netlist and PDF are not filtered.}] -style Muted.TriExport.TLabel
    pack $w.header.title $w.header.note -anchor w -pady 3
    ttk::frame $w.bottom -style TriExport.TFrame -padding {24 14}
    pack $w.bottom -side bottom -fill x
    primaryButton $w.bottom.save [expr {$index < 0 ? "Add rule" : "Save changes"}] {::TriExport::bomEditorAction ::TriExport::saveBomRule}
    ttk::button $w.bottom.cancel -text [tr {Cancel}] -style TriExport.TButton -command ::TriExport::closeBomRule
    pack $w.bottom.save $w.bottom.cancel -side right -padx {8 0}
    ttk::label $w.error -textvariable ::TriExport::bomRuleError -style Error.TriExport.TLabel -wraplength 600
    pack $w.error -side bottom -fill x -padx 24 -pady {2 0}
    ttk::label $w.hint -textvariable ::TriExport::bomRuleHint -style Muted.TriExport.TLabel -wraplength 600
    pack $w.hint -side bottom -fill x -padx 24 -pady 10
    ttk::frame $w.form -style Card.TriExport.TFrame -padding {20 10}
    pack $w.form -fill both -expand 1 -padx 24 -pady {0 4}
    foreach {name label variable values row} {
        action Action bomAction {exclude include} 0
        field Field bomField {} 1
        op Operator bomOperator {equals not_equals contains not_contains glob is_empty not_empty} 3
    } {
        if {$name eq "field"} {set values [dict keys $::TriExport::bomFields]}
        ttk::label $w.form.${name}Label -text [tr $label] -style Card.TriExport.TLabel
        localizedChoice $w.form.$name -textvariable ::TriExport::$variable -state readonly -values $values -style TriExport.TCombobox
        grid $w.form.${name}Label -row $row -column 0 -sticky w -padx {0 20} -pady 10
        grid $w.form.$name -row $row -column 1 -sticky ew -pady 10
    }
    foreach {name label variable} {property {Custom property name} bomProperty value {Value / wildcard pattern} bomValue} {
        ttk::label $w.form.${name}Label -text [tr $label] -style Card.TriExport.TLabel
        ttk::entry $w.form.$name -textvariable ::TriExport::$variable -style TriExport.TEntry
    }
    ttk::label $w.form.colorLabel -text [tr {Color sample reference}] -style Card.TriExport.TLabel
    ttk::frame $w.form.color -style Card.TriExport.TFrame
    ttk::entry $w.form.color.ref -textvariable ::TriExport::bomSampleRef -style TriExport.TEntry -width 14
    ttk::button $w.form.color.read -text [tr {Read color}] -style TriExport.TButton -command {::TriExport::bomEditorAction ::TriExport::readBomSampleColor}
    pack $w.form.color.read -side right -padx {8 0}
    pack $w.form.color.ref -fill x -expand 1
    grid columnconfigure $w.form 1 -weight 1
    bind $w.form.field <<ComboboxSelected>> ::TriExport::bomFieldChanged
    bind $w.form.op <<ComboboxSelected>> ::TriExport::bomFieldChanged
    bind $w <Escape> ::TriExport::closeBomRule
    bomFieldChanged
    grab set $w
}
proc ::TriExport::buildBomPanel {w} {
    pageHeading $w {BOM component selection} {Choose all components, or use rules to include and exclude specific components.}
    card $w.mode {Export mode}
    pack $w.mode -fill x -pady {0 12}
    ttk::radiobutton $w.mode.all -text [tr {Export all components}] -variable ::TriExport::bomEnabled -value 0 -style TriExport.TRadiobutton -command ::TriExport::bomModeChanged
    ttk::radiobutton $w.mode.filtered -text [tr {Filter by rules}] -variable ::TriExport::bomEnabled -value 1 -style TriExport.TRadiobutton -command ::TriExport::bomModeChanged
    pack $w.mode.all $w.mode.filtered -anchor w
    localizedChoice $w.mode.match -textvariable ::TriExport::bomIncludeMatch -state readonly -style TriExport.TCombobox -values {any all} -width 15
    ttk::label $w.mode.matchLabel -text [tr {Include rules match}] -style Card.TriExport.TLabel
    pack $w.mode.matchLabel -side left -padx {0 8} -pady {10 0}
    pack $w.mode.match -side left -pady {10 0}
    bind $w.mode.match <<ComboboxSelected>> ::TriExport::bomModeChanged
    ttk::frame $w.quick -style TriExport.TFrame
    pack $w.quick -fill x -pady {0 12}
    ttk::button $w.quick.color -text [tr {Exclude by color}] -style TriExport.TButton -command {::TriExport::showBomRule -1 {Part color}}
    ttk::button $w.quick.property -text [tr {Exclude by property}] -style TriExport.TButton -command {::TriExport::showBomRule -1 {Custom property}}
    ttk::button $w.quick.add -text [tr {Add rule}] -style TriExport.TButton -command ::TriExport::showBomRule
    pack $w.quick.color $w.quick.property $w.quick.add -side left -padx {0 8}
    ttk::frame $w.actions -style TriExport.TFrame
    pack $w.actions -side bottom -fill x -pady {12 0}
    ttk::button $w.actions.edit -text [tr {Edit selected}] -style TriExport.TButton -command ::TriExport::editSelectedBomRule
    ttk::button $w.actions.remove -text [tr {Remove selected}] -style TriExport.TButton -command ::TriExport::removeBomRule
    pack $w.actions.edit $w.actions.remove -side left -padx {0 8}
    ttk::label $w.note -textvariable ::TriExport::bomPanelNote -style Muted.TriExport.TLabel -wraplength 700
    pack $w.note -side bottom -fill x -pady {12 0}
    ttk::frame $w.list -style Card.TriExport.TFrame
    pack $w.list -fill both -expand 1
    ttk::treeview $w.list.rules -columns {action field op value} -show headings -selectmode browse -style TriExport.Treeview -height 5
    foreach {id label width} {action Action 70 field Field 180 op Operator 90 value Value 220} {
        $w.list.rules heading $id -text [tr $label]
        $w.list.rules column $id -width $width -minwidth 60 -stretch 1
    }
    ttk::scrollbar $w.list.scroll -orient vertical -command [list $w.list.rules yview]
    $w.list.rules configure -yscrollcommand [list $w.list.scroll set]
    pack $w.list.scroll -side right -fill y
    pack $w.list.rules -fill both -expand 1
    bind $w.list.rules <<TreeviewSelect>> ::TriExport::refreshBomButtons
    bind $w.list.rules <Double-1> ::TriExport::editSelectedBomRule
    refreshBomPanel
}
