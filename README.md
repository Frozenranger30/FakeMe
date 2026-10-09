# FakeMe

Eine kleine macOS-App, mit der man sich kurz selbst aufnimmt und diese Aufnahme dann in Zoom, Teams oder FaceTime als Kamerabild abspielt – mit weicher Überblendung zwischen Live-Bild und Aufnahme.

Gebaut, damit es auch ohne Technik-Kenntnisse funktioniert: große Knöpfe, deutsche Hinweise, alles Weitere passiert automatisch.

## Download

👉 **[Neueste Version herunterladen](../../releases/latest)** – dort `FakeMe.dmg` laden.

Alle bisherigen Versionen findest du unter [Releases](../../releases).

**Voraussetzungen:** macOS 14 oder neuer, Mac mit Apple-Chip oder Intel, eingebaute oder USB-Kamera.

## Installation

1. `FakeMe.dmg` doppelklicken.
2. **FakeMe** auf den Ordner **Programme** ziehen.
3. FakeMe aus *Programme* oder *Launchpad* öffnen.

> **„FakeMe kann nicht geöffnet werden“?**
> FakeMe ist nicht von Apple beglaubigt (dafür bräuchte man ein kostenpflichtiges Entwickler-Konto).
> Einmalig: **Systemeinstellungen → Datenschutz & Sicherheit** → ganz unten bei FakeMe auf **„Trotzdem öffnen“** klicken.

## Erster Start

Beim allerersten Start kommen ein paar Fragen – danach nie wieder:

1. **Kamerazugriff** für FakeMe → *OK*
2. **„OBS installieren?“** → *Ja, installieren*
   FakeMe lädt das kostenlose Programm [OBS Studio](https://obsproject.com) (ca. 190 MB) direkt von der offiziellen OBS-Seite auf GitHub und prüft vor der Installation die Apple-Signatur von OBS.
3. **Bildschirmaufnahme** für OBS erlauben.
4. **Kameratreiber erlauben:** FakeMe öffnet die richtige Seite in den Systemeinstellungen – dort bei *Kameraerweiterungen* den Schalter bei **OBS Virtual Camera** einschalten. FakeMe merkt das automatisch.

Danach in Zoom / Teams / FaceTime als Kamera **„OBS Virtual Camera“** auswählen.

## Benutzung

| Schritt | Knopf | Was passiert |
|---|---|---|
| 1 | **Aufnehmen** (rot) | Nimmt dich für die eingestellte Zeit auf (10 s, 20 s, 30 s oder 1 Min). Zoom sieht dabei weiter das Live-Bild. |
| 2 | **Loop abspielen** (grün) | Blendet weich auf die Aufnahme über. Zoom sieht jetzt die Aufnahme. |
| – | **Loop stoppen** | Blendet zurück zum Live-Bild. |

Wenn der Loop einmal durchgelaufen ist, bleibt das letzte Bild kurz stehen (mit Countdown), dann wechselt es automatisch zurück zum Live-Bild.

Tastenkürzel: **Fn+F11** = Aufnehmen, **Fn+F12** = Abspielen/Stoppen. Die Kürzel brauchen die Erlaubnis unter *Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen*. Die Knöpfe in der App funktionieren auch ohne.

FakeMe immer über das rote X oder `Cmd+Q` beenden – dann wird OBS im Hintergrund mit beendet.

## Datenschutz

- Alles läuft **nur lokal** auf deinem Mac. Aufnahmen liegen nur im Arbeitsspeicher und werden nie gespeichert oder hochgeladen.
- Ins Internet geht FakeMe nur einmal, um OBS herunterzuladen (von `github.com/obsproject`).
- FakeMe benutzt nie eine virtuelle Kamera als Quelle, sondern immer die echte Kamera.

## Wie es funktioniert

Seit macOS 15 kann eine App nur noch mit einem kostenpflichtigen Apple-Entwickler-Konto eine eigene virtuelle Kamera mitbringen (Camera Extension). FakeMe nutzt deshalb die – von Apple signierte – virtuelle Kamera von OBS:

```
Kamera ──▶ FakeMe (Aufnahme / Überblendung / Loop)
              │
              ▼
       verstecktes Ausgabe-Fenster ──▶ OBS (Fensteraufnahme) ──▶ „OBS Virtual Camera“ ──▶ Zoom / Teams
```

- FakeMe legt in OBS eine eigene Szene **„FakeMe“** und ein eigenes Profil **„FakeMe“** (1280×720, 30 fps) an. Vorhandene OBS-Szenen und -Profile bleiben unberührt.
- OBS wird unsichtbar im Hintergrund gestartet; die virtuelle Kamera wird über die in OBS eingebaute Fernsteuerung (obs-websocket, passwortgeschützt) eingeschaltet.
- Lange Aufnahmen werden mit weniger Bildern pro Sekunde gespeichert (bis 15 s: 30 fps, bis 30 s: 15 fps, darüber: 10 fps), damit der Arbeitsspeicher reicht.

## Selbst bauen

Benötigt Xcode bzw. die Xcode Command Line Tools (Swift 6).

```bash
swift build            # Debug-Build
swift test             # Tests
Scripts/package_dmg.sh 1.0.0   # Universal-DMG (Apple-Chip + Intel) → FakeMe.dmg
```

### Projektstruktur

| Ordner | Inhalt |
|---|---|
| `Sources/FakeMeApp` | App-Start, Fenster, OBS-Steuerung und -Installation |
| `Sources/FakeMeCore` | Video-Pipeline, Aufnahme-Puffer, Überblendung, Zustandsautomat, Tastenkürzel |
| `Sources/FakeMeUI` | Bedienoberfläche (Steuerleiste, Statusanzeige, Einstellungen) |
| `Tests/FakeMeCoreTests` | Tests für Pipeline, Puffer, Überblendung, Abspiel-Logik |
| `Sources/FakeMeCameraExtension`, `DALPlugin` | Frühere Ansätze für eine eigene virtuelle Kamera (Camera Extension braucht ein Entwickler-Konto; DAL-Plugins lädt macOS 15+ nicht mehr) – werden nicht benutzt |

## Neue Version veröffentlichen

```bash
Scripts/package_dmg.sh 1.1.0
git tag v1.1.0 && git push --tags
gh release create v1.1.0 FakeMe.dmg --title "FakeMe 1.1.0" --notes "Was ist neu …"
```

## Lizenz

[MIT](LICENSE). OBS Studio ist ein eigenständiges Programm unter GPL-2.0 und wird nicht mit FakeMe ausgeliefert, sondern bei Bedarf von der offiziellen Quelle geladen.
