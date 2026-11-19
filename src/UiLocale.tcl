# Localize display text only. Persisted choices and CAD property data stay stable.
source -encoding utf-8 [file join [file dirname [info script]] ZhCN.tcl]
namespace eval ::TriExport {
    variable choiceMaps [dict create]
    variable choiceBusy [dict create]
}
proc ::TriExport::tr {text} {
    variable zhExact
    variable zhPatterns
    if {[dict exists $zhExact $text]} { return [dict get $zhExact $text] }
    foreach item $zhPatterns {
        lassign $item pattern translated
        set matches [regexp -inline -- $pattern $text]
        if {[llength $matches]} {
            set replacements {}
            set i 0
            foreach value [lrange $matches 1 end] {
                lappend replacements "\{$i\}" $value
                incr i
            }
            # One literal replacement pass; captures are never evaluated.
            return [string map $replacements $translated]
        }
    }
    return $text
}
proc ::TriExport::localizedChoice {path args} {
    variable choiceMaps
    set opts $args
    set internal [dict get $opts -textvariable]
    set ui "::TriExport::ui_[namespace tail $internal]"
    set labels {}
    set reverse [dict create]
    foreach value [dict get $opts -values] {
        set label [tr $value]
        lappend labels $label
        dict set reverse $label $value
    }
    set first [expr {![dict exists $choiceMaps $internal]}]
    dict set choiceMaps $internal $reverse
    set $ui [tr [set $internal]]
    if {$first} {
        trace add variable $internal write [list ::TriExport::syncChoice $internal $ui 0]
        trace add variable $ui write [list ::TriExport::syncChoice $internal $ui 1]
    }
    dict set opts -values $labels
    dict set opts -textvariable $ui
    return [ttk::combobox $path {*}$opts]
}
proc ::TriExport::syncChoice {internal ui fromUi args} {
    variable choiceMaps
    variable choiceBusy
    if {[dict exists $choiceBusy $internal]} { return }
    dict set choiceBusy $internal 1
    try {
        if {$fromUi} {
            if {![dict exists $choiceMaps $internal [set $ui]]} {
                set $ui [tr [set $internal]]
                error "Invalid localized selection."
            }
            set $internal [dict get $choiceMaps $internal [set $ui]]
        } else {
            set $ui [tr [set $internal]]
        }
    } finally { dict unset choiceBusy $internal }
}
proc ::TriExport::displayError {message} {
    set translated [tr $message]
    if {$translated ne $message} { return $translated }
    # Third-party/native diagnostics remain intact beneath a Chinese context.
    return "[tr {Error details:}]\n$message"
}
proc ::TriExport::showMessage {args} {
    set opts $args
    if {[dict exists $opts -title]} { dict set opts -title [tr [dict get $opts -title]] }
    return [::tk_messageBox {*}$opts]
}
