#!/usr/bin/env python3
"""Narrow source guardrails, not a native interaction or rendering test."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
view = (root / 'LiveWindowView.swift').read_text()
style = (root / 'WindowPresentation.swift').read_text()
scroll = (root / 'TimeInteractions.swift').read_text()
watch = (root / 'LiveWatch.swift').read_text()
checks = []

def check(condition: bool, message: str) -> None:
    checks.append((condition, message))

native = style.split('struct WindowNativeButton:', 1)[1].split('/// A small adjacent', 1)[0]
check('Button(role: configuration.role, action: configuration.trigger)' in native, 'native action preserves semantic role and activation')
check('.foregroundStyle(' not in native and '.opacity(' not in native, 'native materials own foreground/disabled rendering')
check('.glassEffect(' not in style, 'no double-applied glass on standard buttons')
check('.glassProminent' in native and '.glass)' in native, 'native primary and secondary glass paths exist')
check('.borderedProminent' in native and '.bordered)' in native, 'accessible bordered fallbacks exist')
check('!reduceTransparency && contrast != .increased' in native, 'glass fallback gates accessibility settings')
check('GlassEffectContainer(spacing: 0)' in style, 'adjacent dialog controls remain distinct at rest')
check('.buttonStyle(PrimaryButton(' not in view, 'live primary controls no longer force the old label color')
check('.animation(Motion.press' not in style, 'custom feedback observes Reduce Motion')
check(view.count('.popover(item: $comparison)') == 1, 'comparison has one persistent anchor')
check(view.count('.popover(isPresented: $details)') == 1, 'details has one persistent anchor')
check('EditorSession' in view and 'editorSession?.id == session.id' in view, 'nested callbacks check presentation identity')
check('current.acceptsChild(session.parentID' in view, 'nested callbacks check draft/day/revision ownership')
check('JourneyPresentation.screen(model: watch.screen, editing: edit != nil)' in view, 'navigation is local to the editing surface')
check('watch.screen = "setup"' not in view, 'opening an editor does not navigate the other surface')
check('hasPresentedSurface ? nil : KeyboardShortcut.defaultAction' in view, 'parent Return is suspended during a child presentation')
check('MinuteEntry.value(entry)' in view and 'WindowStepperField(text: $entry, placeholder: "0", unit: "min"' in view, 'duration has validated exact entry')
clear_search = view.split('private func clearSearch()', 1)[1].split('\n    }', 1)[0] if 'private func clearSearch()' in view else ''
check(all(step in clear_search for step in ('search.cancel()', 'search.complete("")', 'search.results = []', 'search.error = nil', 'selectedResult = nil')),
      'search invalidation clears in-flight work, suggestions and old results')
check('text: queryBinding' in view and 'clearSearch(); query = value' in view, 'query edits invalidate synchronously, before submit')
check('guard !search.busy, hasQuery else' in view, 'Return cannot restart a pending search')
check('!samePlace && !search.busy && !hasQuery' in view, 'unresolved search cannot silently confirm old places')
check('ResultSelection.moved' in view and 'scroller.scrollTo(id' in view, 'keyboard selection keeps results reachable')
check('.buttonStyle(WindowRowButton' in view, 'route rows have state feedback without content glass')
check('watch.testingAlert' in view and '@State private var testing' not in view, 'test progress is shared across surfaces')
check('while let permissionTask' in watch, 'test joins the full permission-request chain')
check('owner?.isKeyWindow == true && owner?.attachedSheet == nil' in scroll, 'scroll edits respect active-window/modal boundaries')
check('view.enabled = enabled' in scroll and 'gesture.handle' in scroll, 'scroll edits use enabled-state and physical-gesture ownership')
check('NSPopover.didCloseNotification' in view and 'stopObserving()' in view, 'transient panel dismissal and observer cleanup are handled')
check('WindowControlReview' in view and 'struct WindowControlReview' in style, 'native capture matrix includes control variants')
for ok, message in checks:
    if not ok:
        print('FAIL:', message)
print(f"{'PASS' if all(ok for ok, _ in checks) else 'FAIL'}: {sum(ok for ok, _ in checks)}/{len(checks)} interaction source guardrails. Native behavior is not exercised.")
raise SystemExit(0 if all(ok for ok, _ in checks) else 1)
