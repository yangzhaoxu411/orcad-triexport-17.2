# Headless UI regression: package loading, widget creation and real callbacks.
# Intercept Tk package loading so this test cannot open a native window.
set base [file normalize [file join [file dirname [info script]] ..]]
source -encoding utf-8 [file join $base src TriExport.tcl]
set scratch [file join $base .work ui-tests]
file mkdir $scratch
proc ::TriExport::dataHome {} { return $::scratch }
set ::TriExport::ghostscript "mock-gswin64c.exe"
set assertions 0
proc check {expression message} {
    if {![uplevel 1 [list expr $expression]]} { error "FAIL: $message" }
    incr ::assertions
}
set tkLoaded 0
set tkLoads 0
set failTk 0
rename ::package ::realPackage
proc ::package {subcommand args} {
    if {$subcommand eq "provide" && $args eq "Tk"} {
        if {$::tkLoaded} { return 8.6.0 }; return ""
    }
    if {$subcommand eq "require" && [lindex $args 0] eq "Tk"} {
        if {$::failTk} { error "injected Tk initialization failure" }
        set ::tkLoaded 1
        incr ::tkLoads
        return 8.6.0
    }
    return [::realPackage $subcommand {*}$args]
}
set widgets [dict create . [dict create class Root options {}]]
set calls {}
set messages {}
set failWidget ""
proc requireTk {} { if {!$::tkLoaded} { error "Tk command used before package require Tk" } }
proc widget {class path args} {
    requireTk
    if {$path eq $::failWidget} { error "injected widget construction failure" }
    if {[dict exists $::widgets $path]} { error "duplicate widget: $path" }
    set parent [string range $path 0 [expr {[string last . $path] - 1}]]
    if {$parent eq ""} {set parent .}
    if {![dict exists $::widgets $parent]} { error "missing parent: $parent" }
    dict set ::widgets $path [dict create class $class options $args]
    interp alias {} $path {} widgetCommand $path
    return $path
}
proc widgetCommand {path method args} {
    switch -- $method {
        create {return 1}
        bbox {return {0 0 600 200}}
        configure - itemconfigure - state - yview - set {return}
        default {error "unsupported widget method: $method"}
    }
}
proc winfo {method path} {
    requireTk
    switch -- $method {
        exists {return [dict exists $::widgets $path]}
        class {return [dict get $::widgets $path class]}
        children {
            set children {}
            dict for {name data} $::widgets {
                set parent [string range $name 0 [expr {[string last . $name] - 1}]]
                if {$parent eq $path} {lappend children $name}
            }
            return $children
        }
        default {error "unsupported winfo method: $method"}
    }
}
proc destroy {path} {
    foreach name [dict keys $::widgets] {
        if {$name eq $path || [string match "$path.*" $name]} {
            dict unset ::widgets $name
            rename $name {}
        }
    }
}
proc wm {args} { requireTk; lappend ::calls [linsert $args 0 wm] }
proc raise {args} {requireTk}
proc pack {args} {requireTk}
proc grid {args} {requireTk}
proc bind {args} {requireTk}
proc tk_messageBox {args} {requireTk; lappend ::messages $args}
proc toplevel {path args} {widget Toplevel $path {*}$args}
proc canvas {path args} {widget Canvas $path {*}$args}
namespace eval ::ttk {}
foreach {name class} {frame TFrame label TLabel button TButton entry TEntry checkbutton TCheckbutton scrollbar TScrollbar combobox TCombobox} {
    interp alias {} ::ttk::$name {} widget $class
}
proc ::TriExport::activeDesign {} {return mockDesign}
proc ::TriExport::getString {obj method} {return {C:/fixture/Design.dsn}}
proc ::TriExport::enumeratePages {design} {
    return [list [dict create schematic MAIN name PAGE1] [dict create schematic MAIN name PAGE2] [dict create schematic MAIN name PAGE3]]
}
set actions {}
set menus {}
proc RegisterAction {name enabled unused callback context} {dict set ::actions $name $callback}
proc InsertXMLMenu {menu} {lappend ::menus $menu}
proc RefreshMenu {} {}
::TriExport::init [file join $scratch mock-cadence]
check {!$tkLoaded} "autoload does not create windows"
foreach menu $menus {
    check {![regexp {[^\x00-\x7f]} $menu]} "native menu labels are ASCII"
}
set popup [lindex $menus 0 3]
check {[lindex $popup 3] eq "TriExportEnable"} "opening popup does not invoke export dialog"
set run [lindex $menus 1 3 3]
set callback [dict get $actions $run]
check {$callback eq "::TriExport::openAction"} "menu child is wired to the open action"
set result [$callback]
check {$result eq "true" && [winfo exists .triExport.bottom.export]} "menu callback builds a complete dialog"
check {[string match {Allegro Netlist*} [dict get $widgets .triExport.top.title options -text]]} "UI identifies Allegro output"
check {[string match {*Unzip*Allegro*} [dict get $widgets .triExport.options.note options -text]]} "UI explains netlist ZIP extraction"
check {$tkLoads == 1} "Tk loaded before window commands"
check {[lsearch -exact $calls {wm withdraw .}] >= 0} "only newly loaded Tk root is hidden"
set options [dict get $widgets .triExport.options.paper options]
set values [dict get $options -values]
check {[llength $values] == 3 && [lindex $values 0] eq "Original sheet size"} "paper labels remain three choices"
check {$::TriExport::selectedCount eq "3 / 3 pages selected"} "page selection initialized"
set clear [dict get [dict get $widgets .triExport.pageTools.none options] -command]
eval $clear
check {$::TriExport::selectedCount eq "0 / 3 pages selected"} "clear all button works"
set all [dict get [dict get $widgets .triExport.pageTools.all options] -command]
eval $all
check {$::TriExport::selectedCount eq "3 / 3 pages selected"} "select all button works"
set before [dict size $widgets]
dict for {path item} $widgets {
    set options [dict get $item options]
    foreach key {-text -values} {
        if {[dict exists $options $key]} {
            check {![regexp {[^\x00-\x7f]} [dict get $options $key]]} "all static UI labels are ASCII"
        }
    }
}
$callback
check {[dict size $widgets] == $before} "repeat click raises existing dialog"
check {[llength $messages] == 0} "normal open shows no error"
::TriExport::closeWindow
set failWidget .triExport.location
$callback
check {![winfo exists .triExport]} "failed build removes partial dialog"
check {[string match {*widget construction failure*} [lindex $messages end]]} "original error is reported"
set failWidget ""
$callback
check {[winfo exists .triExport.bottom.export]} "next click retries after build failure"
::TriExport::closeWindow
set tkLoaded 0
set failTk 1
rename tk_messageBox mockMessageBoxDisabled
set code [catch {$callback} result]
check {$code == 0 && $result eq "true"} "missing Tk does not trigger a secondary Tk error"
set log [::TriExport::readUtf8 [file join $scratch startup-error.log]]
check {[string match {*injected Tk initialization failure*} $log]} "Tk failure preserved in startup log"
check {![dict exists $widgets .triExport]} "failed Tk initialization creates no dialog"
::TriExport::writeUtf8 [file join $scratch settings.json] [::TriExport::jsonObject [dict create paper "A4 \u6a2a\u5411"]]
::TriExport::loadSettings
check {$::TriExport::paper eq "A4 landscape"} "rc1 paper label migrates to English"
file delete [file join $scratch settings.json]
puts "PASS: $assertions UI regression assertions; Tk loading intercepted, no windows opened."
