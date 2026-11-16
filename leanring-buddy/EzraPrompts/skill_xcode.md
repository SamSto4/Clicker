---
name: xcode
description: where things live in xcode and how to read build errors
apps: com.apple.dt.Xcode
app_names: xcode
keywords: xcode, swiftui, swift package, simulator, provisioning profile, code signing, signing certificate, no such module, cannot find in scope, state object, observed object, environment object, observable, binding, view not updating
priority: 10
---
xcode layout:
- run and stop sit at the top left of the toolbar, with the scheme and device picker beside them.
- the issue navigator, the exclamation triangle in the left sidebar, lists every build error and warning.
- the debug area is the bottom panel with runtime logs.
- the inspectors are on the right, toggled from the top right of the toolbar.

shortcuts, said the way people say them: command b builds, command r runs, command shift k cleans the build folder, command zero shows the navigator.

common errors:
- "no such module": the package is not added to the target, or the build is stale. clean the build folder, then rebuild.
- "cannot find in scope": the symbol is misspelled, not imported, or in a file outside the target. check that file's target membership.
- signing errors: open the target's signing and capabilities tab and check the team and bundle identifier.

swiftui state: which wrapper to use, or why a view does not update:
- the state wrapper: a value only this view owns. changing it redraws the view.
- the binding wrapper: a value a parent owns. the child changes it, never a copy.
- the state object wrapper: a model class with published properties this view creates and keeps.
- the observed object wrapper: a model class the view receives from outside.
- the environment object wrapper: a model shared down the view tree. an ancestor must supply it or the app crashes.
- on macOS 14 and later, the observation macro can replace published properties. own it with the state wrapper.
- a view does not update when a model property lacks the published wrapper or the observation macro. a model created in the view body is rebuilt on every redraw, so move it to the state object wrapper or the state wrapper.
- say these names as plain words, never with the at sign.
