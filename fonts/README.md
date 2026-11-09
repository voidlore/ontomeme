# Fonts

Ontomeme draws its interface and notes with two font families from GNOME
[adwaita-fonts](https://gitlab.gnome.org/GNOME/adwaita-fonts). The files are
unchanged copies of the upstream releases.

| File | Family | Version | Based on |
|---|---|---|---|
| `AdwaitaSans-Regular.ttf` | Adwaita Sans | 4.001 | [Inter](https://github.com/rsms/inter) |
| `AdwaitaSans-Italic.ttf` | Adwaita Sans | 4.001 | [Inter](https://github.com/rsms/inter) |
| `AdwaitaMono-Regular.ttf` | Adwaita Mono | 34.8.0 | [Iosevka](https://github.com/be5invis/Iosevka) |
| `AdwaitaMono-Bold.ttf` | Adwaita Mono | 34.8.0 | [Iosevka](https://github.com/be5invis/Iosevka) |

## Licence

Both families are licensed under the
[SIL Open Font License, Version 1.1](https://openfontlicense.org). The OFL
asks that the copyright notice and the licence travel with every copy of the
fonts, so [OFL.txt](OFL.txt) holds both: the copyright lines embedded in each
font file, then the upstream notice and the full licence text.

OFL.txt is also packed into the app, because the export presets include
`fonts/*`, and Ontomeme shows it under **About Ontomeme → Licences**.

The `.ttf.import` files beside the fonts are Godot's import settings, not part
of the fonts.
