#!/usr/bin/env python3
"""Static must-fix checks; does not compile Swift or execute runtime tests."""
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, f"Duplicate JSON key: {key}"
        result[key] = value
    return result


def values(node):
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield node["stringUnit"]["value"]
        else:
            for child in node.values():
                yield from values(child)


def placeholders(value):
    tokens = re.findall(r"%(?:\d+\$)?(?:[-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hlLztj])?[@diuoxXfFeEgGaAcsp]|%)", value)
    return Counter(re.sub(r"^%\d+\$", "%", token) for token in tokens if token != "%%")


catalogs = {}
checked = 0
for path in ["Sources/PlainsayApp/Resources/Localizable.xcstrings",
             "Sources/PlainsayCore/Resources/CoreLocalizable.xcstrings"]:
    catalog = json.loads(source(path), object_pairs_hook=unique_object)
    catalogs[path] = catalog["strings"]
    for key, entry in catalog["strings"].items():
        localized = entry.get("localizations", {})
        english = list(values(localized.get("en", {})))
        polish = list(values(localized.get("pl", {})))
        if english and polish:
            expected = placeholders(english[0])
            for value in english + polish:
                assert value, (path, key, "empty value")
                assert placeholders(value) == expected, (path, key, "placeholder mismatch", value)
                checked += 1
print(f"PASS: both catalogs parse without duplicate keys; {checked} EN/PL values match placeholders")

app = catalogs["Sources/PlainsayApp/Resources/Localizable.xcstrings"]
history = source("Sources/PlainsayApp/HistoryView.swift")
for suffix in ["deletionFailed", "disabledDescriptionNotDeleted", "retryDeletion", "saveFailed", "saveUnprotected"]:
    key = "history." + suffix
    localized = app[key]["localizations"]
    en = localized["en"]["stringUnit"]["value"]
    pl = localized["pl"]["stringUnit"]["value"]
    assert en and pl and en != pl, key
    assert re.search(re.escape('"' + key + '",') + r'\s*fallback: ' + re.escape('"' + en + '"'), history), key
print("PASS: five History keys ship EN/PL; English matches each UI fallback")

overflow = app["profiles.vocabulary.overflow"]["localizations"]
for lang, categories in [("en", {"one", "other"}), ("pl", {"one", "few", "many", "other"})]:
    forms = overflow[lang]["variations"]["plural"]
    assert set(forms) == categories, (lang, forms.keys())
    assert all(placeholders(form["stringUnit"]["value"]) == Counter({"%d": 1}) for form in forms.values())
assert app["profiles.email.off"]["localizations"]["pl"]["stringUnit"]["value"] == "Wyłączony"
assert app["profiles.translation.off"]["localizations"]["pl"]["stringUnit"]["value"] == "Wyłączone"
assert "profiles.off" not in app
editor = source("Sources/PlainsayApp/ProfileEditorView.swift")
assert 'Localization.appPlural(' in editor and '"profiles.vocabulary.overflow"' in editor
assert '"profiles.email.off"' in editor and '"profiles.translation.off"' in editor
print("PASS: overflow plural categories/placeholders, plural call site and Polish Off labels")

guards = source("Tests/PlainsayCoreTests/PrivateArmLiveTests.swift")
limits = {"Sources/PlainsayCore/DictationCoordinator.swift": 1304,
          "Sources/PlainsayApp/SettingsView.swift": 784}
helpers = re.search(r"let helpers = \[(.*?)\]", guards, re.S).group(1)
limits.update({path: 500 for path in re.findall(r'"([^"]+\.swift)"', helpers)})
assert 'lineCount(path) <= 500' in guards
for path, limit in limits.items():
    count = source(path).count("\n")
    assert count <= limit, (path, count, limit)
    print(f"PASS: {path}: {count}/{limit} lines")

for path in ["Sources/PlainsayApp/VoiceEditWindowController.swift", "Sources/PlainsayApp/DictationCorrectionWindow.swift"]:
    text = source(path)
    assert "editor.edit(" not in text and "Task.checkCancellation()" not in text, path
    for token in ["previewRequest.start(request, to: editor", ".check()", "previewRequest.cancel()"]:
        assert token in text, (path, token)
    assert text.index(".check()") < text.index("ProviderFactory.makeEditor(settings)"), path
slot = source("Sources/PlainsayCore/HostedEditSlot.swift")
assert "gate.send(request, to: editor)" in slot and "gate.track(Task" in slot
assert "editGate: coordinator.privateDictation.hostedEdits" in source("Sources/PlainsayApp/AppModel.swift")
correction = source("Sources/PlainsayApp/DictationCorrectionWindow.swift")
assert "HostedEditSlot(gate: coordinator.privateDictation.hostedEdits)" in correction
assert "remember = RememberCorrectionModel(settings: settings)" in correction
print("PASS: both Preview paths retain the live gate/slot and Remember initialization")

private = source("Sources/PlainsayCore/DictationCoordinator+Private.swift")
assert "sessionPolicy.privacy == .privateLocal && privateDictation.isArmed" in private
profiles = source("Sources/PlainsayCore/DictationCoordinator+Profiles.swift")
assert "policy.allowsCleanup && effectivePolishingReadiness().runs" in profiles
assert "let target = policy.translateTo, polishes, cloud.account?.isActive == true" in profiles
assert "if readiness.offersStyles" in editor
assert "settings.appProfiles.rename(profileID, to: typed)" in editor
assert ".onSubmit(commitName)" in editor and ".onDisappear(perform: commitName)" in editor
assert 'guard let valid = DictationProfile.validName(name) else { throw DictationProfileEditError.invalidName }' in source("Sources/PlainsayCore/DictationProfile.swift")
print("PASS: retained live-arm notice, effective chip/editor readiness and rename validation wiring")
print("Static checks only. Swift build, Swift tests and Mac UI verification are still required.")
