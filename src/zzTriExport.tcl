# OrCADTriExport-17.2-loader-v1 -- installer ownership marker; ASCII loader.
if {1} {
    set triExportHome [file join $::env(LOCALAPPDATA) OrCADTriExport 17.2]
    set triExportRoot [file normalize [file join [file dirname [info script]] .. .. .. ..]]
    if {[file isfile [file join $triExportHome TriExport.tcl]]} {
        if {[catch {
            if {![llength [info commands ::TriExport::init]]} {
                source -encoding utf-8 [file join $triExportHome TriExport.tcl]
            }
            ::TriExport::init $triExportRoot
        } triExportError triExportOptions]} {
            if {[llength [info commands ::TriExport::reportError]]} {
                ::TriExport::reportError "Could not load the menu" $triExportError $triExportOptions
            } else {
                puts "OrCAD TriExport could not load: $triExportError"
            }
        }
    }
    unset triExportHome triExportRoot
}
