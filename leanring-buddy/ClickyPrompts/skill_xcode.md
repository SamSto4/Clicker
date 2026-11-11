---
name: xcode
description: where things live in xcode and how to read build errors
apps: com.apple.dt.Xcode
app_names: xcode
keywords: xcode, swiftui, swift package, simulator, provisioning profile, code signing, signing certificate, no such module, cannot find in scope, state object, observed object, environment object, observable, binding, view not updating
priority: 10
---
xcode layout:
- run and stop are at the top left of the toolbar. the scheme and device picker sit just right of them.
- the issue navigator is the triangle with an exclamation mark in the left sidebar tabs. it lists every build error and warning with its file and line.
- the debug area is the bottom panel. the console there shows runtime output and logs.
- the inspectors are on the right. the toggle is at the top right of the toolbar.

shortcuts, said the way people say them: command b builds, command r runs, command shift k cleans the build folder, command zero shows the navigator, command shift y shows the debug area.

common errors:
- "no such module": the package is not added to the target, or the build is stale. clean the build folder, then build again.
- "cannot find in scope": the symbol is misspelled, not imported, or in a file that is not in the target. check the target membership of that file.
- signing errors: open the target's signing and capabilities tab and check the team and the bundle identifier.

swiftui state, for which wrapper to use or why a view does not update:
- @State: a value only this view owns. changing it redraws the view.
- @Binding: a value a parent owns. the child changes it, never a copy.
- @StateObject: a model class with @Published properties that this view creates and keeps.
- @ObservedObject: a model class the view receives from outside.
- @EnvironmentObject: a model shared down the view tree. an ancestor must supply it or the app crashes.
- on macOS 14 and later, @Observable can replace published properties. own it with @State.
- a view does not update when a model property lacks @Published or @Observable. a model created inside the view body is rebuilt on every redraw, so move it to @StateObject or @State.
