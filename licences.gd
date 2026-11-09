extends RefCounted
## The licence notices that must travel with every copy of the app, shown by
## About Ontomeme → Licences: Ontomeme's own MIT licence, the SIL OFL 1.1 of
## the bundled Adwaita fonts (res://fonts/OFL.txt, packed by the export
## presets' fonts/* filter) and the Godot Engine's licence with the copyright
## lines and licence texts of the third-party code compiled into it.

const OFL_PATH: String = "res://fonts/OFL.txt"

## A copy of LICENSE, which is not packed into the app. tests/licences_test.gd
## fails when the two drift apart.
const ONTOMEME_LICENSE: String = """MIT License

Copyright (c) 2026 Joseph Sailor Usher

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


## Every notice, as one plain text for a read-only text box.
static func licences_text() -> String:
	var sections: PackedStringArray = [
		_section("Ontomeme", ONTOMEME_LICENSE),
		_section("Fonts: Adwaita Sans and Adwaita Mono", font_licence()),
		_section("Godot Engine", "Ontomeme is built with the Godot Engine (https://godotengine.org).\n\n" + Engine.get_license_text()),
		_section("Third-party code in the Godot Engine", engine_components()),
		_section("Licence texts of that code", engine_licence_texts()),
	]
	return "\n\n\n".join(sections)


## The fonts' copyright lines and the OFL, as packed into the app.
static func font_licence() -> String:
	var text: String = FileAccess.get_file_as_string(OFL_PATH)
	if text == "":
		return "The font licence (fonts/OFL.txt) is missing from this build. The fonts are licensed under the SIL Open Font License, Version 1.1: https://openfontlicense.org"
	return text


## Each component the engine reports, with its copyright lines and licence.
static func engine_components() -> String:
	var lines: PackedStringArray = []
	for component: Dictionary in Engine.get_copyright_info():
		lines.append(str(component.get("name", "")))
		for part: Dictionary in component.get("parts", []):
			for holder in part.get("copyright", []):
				lines.append("    Copyright (c) " + str(holder))
			lines.append("    Licence: " + str(part.get("license", "")))
		lines.append("")
	return "\n".join(lines).strip_edges()


## The full text of every licence named in engine_components().
static func engine_licence_texts() -> String:
	var info: Dictionary = Engine.get_license_info()
	var texts: PackedStringArray = []
	for name: String in info:
		texts.append("%s\n%s\n\n%s" % [name, "-".repeat(name.length()), str(info[name]).strip_edges()])
	return "\n\n".join(texts)


static func _section(title: String, body: String) -> String:
	return "%s\n%s\n\n%s" % [title, "=".repeat(title.length()), body.strip_edges()]
