# NotProton auf dem Mac

Mit NotProton startest du unterstützte Windows Spiele aus der normalen macOS Steam App. CrossOver führt die Spiele im Hintergrund aus. Eine zweite Windows Steam Installation brauchst du für diesen Ablauf nicht.

Dieses Repository ist ein Beitragsfork des [Originalprojekts](https://github.com/NotProtonNot/NotProton). Die Änderungen basieren auf dessen Entwicklungsbranch `dev-1.1.0` und wurden noch nicht ins Original übernommen. Die fertige Beitragsversion für Apple Silicon gibt es als [Download](https://github.com/schroedernils/NotProton/releases/tag/v1.1.0-contribution.1). Sie wurde noch nicht upstream übernommen.

Entpacke die ZIP und kopiere NotProton.app nach Programme. Die App ist lokal signiert und nicht von Apple notarisiert. Falls macOS den ersten Start blockiert und du diesem Download vertraust, kannst du die einzelne App unter Datenschutz und Sicherheit mit Dennoch öffnen freigeben. Gatekeeper bleibt eingeschaltet. Automatische App Updates sind in diesem Beitragspaket deaktiviert. Der erste Installations- und Spieltest mit dieser neuen Oberfläche steht noch aus.

## Was enthalten ist

Hilfe, Details im Onboarding und Wartung lassen sich über die gesamte Überschriftszeile aufklappen. Steam und CrossOver zeigen die Symbole deiner installierten Apps.

Die Mac App führt durch fünf Seiten der Einrichtung. Sie erklärt die benötigten Berechtigungen, prüft Integration und Laufzeitumgebung und zeigt den Weg zum ersten Spiel. Statusmeldungen unterscheiden fehlende Steam Dateien von fehlenden Runtime Dateien. Unterstützte CrossOver Builds werden genauer angezeigt.

Unter Spielumgebungen findest du die Windows Umgebung jedes gestarteten Spiels. Dort kannst du Programme ausführen, Sicherungen erstellen und Umgebungen neu aufbauen. Die Hilfe erklärt häufige Probleme und erklärt die unterstützten CrossOver Profile. Eine kurze Supportzusammenfassung kannst du vor dem Kopieren prüfen. Es wird nichts automatisch hochgeladen.

Die neuen Einrichtungsseiten und Hilfetexte sind auf Deutsch und Englisch verfügbar. Bestehende erweiterte Werkzeuge behalten ihre englischen Bezeichnungen.

## Voraussetzungen

Du brauchst macOS 26 oder neuer, die macOS Steam App unter `/Applications/Steam.app` und einen aktivierten CrossOver Build mit geprüftem Profil. Öffne Steam und melde dich einmal an. Für fehlende Valve Komponenten benötigt die Installation Internet. Plane außerdem Platz für die separate Runtime Kopie, Spielumgebungen und Sicherungen ein.

NotProton ist kostenlos. CrossOver ist ein separates kostenpflichtiges Produkt. Seine Lizenzbedingungen gelten weiterhin.

| CrossOver | Genaue Buildnummer | Optionen |
| --- | --- | --- |
| Stable 26.3 | `26.3.0.39832` | Rosetta |
| Preview 20260821 | `27.0.0.40921` | Rosetta Build oder FEX Build mit FEX und Rosetta Tools |
| Preview 20261006 | `27.0.0.41069` | Rosetta Build oder FEX Build mit FEX und Rosetta Tools |

Der Versionsname allein genügt nicht. NotProton prüft die eigentlichen Wine Dateien gegen bekannte Profile, bevor es die eigene Kopie anpasst. Beginne mit Rosetta. FEX ist experimentell und wurde hier nicht im Spielbetrieb getestet.

Auch Steam Updates können Änderungen an NotProton nötig machen. Der lokale Spieltest erfolgte mit Steam Client `1788652215`. Weitere Signaturprofile im Quellcode bedeuten keine vollständige Prüfung sämtlicher Steam Versionen.

## Installation

Die veröffentlichte Originalversion findest du auf der [offiziellen Releaseseite](https://github.com/NotProtonNot/NotProton/releases). Deren Voraussetzungen können von diesem Fork abweichen. Sie enthält nicht automatisch die hier beschriebenen Änderungen.

Für diesen Fork baust du die App aus dem Quellcode oder nutzt ein separat bereitgestelltes lokales Testpaket. Eine lokal signierte Testapp ist kein öffentlich notarisiertes Release. Schalte Gatekeeper oder andere macOS Schutzfunktionen nicht pauschal für die Installation ab.

1. Kopiere die App nach Programme und öffne sie. Beim ersten App Start öffnet sich der Assistent. Du kannst ihn später unten in der Seitenleiste über Einstellungen oder im Status erneut öffnen.
2. Prüfe Steam und die CrossOver Quelle auf der ersten Seite. Mit CrossOver auswählen kannst du eine App aus einem anderen Ordner hinzufügen. Aktiviere CrossOver bei Bedarf in dessen eigener App.
3. Lies vor der Installation die Berechtigungsseite. Ihr Button öffnet Datenschutz & Sicherheit → App Verwaltung. Aktiviere dort die verwendete NotProton App, falls sie erscheint. Falls sie noch fehlt, kann macOS sie nach dem Installationsversuch hinzufügen. NotProton kann diese Berechtigung nicht zuverlässig abfragen. Weiter bedeutet, dass du den Hinweis gelesen hast, und bestätigt keine erteilte Berechtigung.
4. Beende deine Spiele und installiere die Integration. Steam wird möglicherweise geschlossen. Eine aktivierte Quelle kann dabei schon automatisch als Runtime eingerichtet werden. Bei einem Fehler bleibt die Seite offen und zeigt den Fehler sowie gegebenenfalls den passenden Einstellungslink.
5. Richte die Runtime auf der nächsten Seite ein, falls sie oder erforderliche Komponenten noch fehlen. NotProton verwendet eine eigene Kopie. Die ursprüngliche CrossOver App bleibt die Quelle.
6. Öffne oder starte die normale macOS Steam App neu. Wähle in deiner Bibliothek ein Windows Spiel und öffne Eigenschaften → Kompatibilität. Wähle ein installiertes NotProton / CrossOver Tool und starte das Spiel.

Beim ersten Start wird die Windows Umgebung erstellt, deshalb kann er länger dauern. Prüfe Bild, Steuerung und Spielstände. Ein geprüfter Installationsstand garantiert nicht, dass jedes Spiel funktioniert.

Für Controller kann Steam später die Eingabeüberwachung anfragen. Erlaube sie bei der Abfrage für Steam und starte Steam neu. Vollständiger Festplattenzugriff ist keine allgemeine Voraussetzung.

## Spielstände und Sicherungen

Ein Prefix ist die Windows Umgebung eines Spiels mit Registry, Komponenten und möglicherweise Spielständen. Er erscheint nach dem ersten Windows Spielstart unter Spielumgebungen.

Sichere ihn, bevor du Komponenten änderst oder ihn neu aufbaust. Eine Prefix Sicherung enthält keine Spieldownloads und garantiert keine Steam Cloud Synchronisierung. Behalte bei wichtigen Spielen zusätzlich eigene Sicherungen der Spielstände.

Steam kann vorhandene Downloads weiterverwenden und prüfen. Eine bestehende CrossOver Bottle lässt sich aber nicht durch bloßes Verschieben ihres Ordners übertragen. Dieser Fork importiert Bottles oder Spielstände nicht automatisch.

Über Tools → Run Program startest du eine vertrauenswürdige Windows EXE im ausgewählten Prefix. Das ändert nicht die Standarddatei hinter Steams Spielen Button.

## Häufige Probleme

| Problem | Sinnvoller erster Schritt |
| --- | --- |
| CrossOver wird nicht unterstützt | Vergleiche die genaue Buildnummer im Status mit der Tabelle. Benenne keine App um und umgehe keine Dateiprüfung. |
| Die Installation darf Steam nicht ändern | Lies den Fehler. Bei App Verwaltung öffne die verlinkte Einstellung. Bei einem anderen Eigentümer braucht es das richtige macOS Konto oder korrekte Ordnerrechte. |
| NotProton sei nicht für dieses Konto installiert | Die korrigierte Statusprüfung trennt Steam Komponenten und Runtime Komponenten. Sie prüft keine Steam Käufe oder Spielberechtigungen. |
| Die Kompatibilitätsseite fehlt | Starte Steam nach der Einrichtung neu und aktualisiere den Status. Ein Steam Update kann eine neue Anpassung benötigen. |
| Das Spielfenster bleibt schwarz | Lass die erste Einrichtung fertig werden, beende das Spiel normal und versuche es erneut. Prüfe das gewählte Tool und ändere jeweils nur eine Grafikoption. |
| Controller oder Tastatur funktionieren nicht | Prüfe macOS, Steam und die Eingabeoptionen des Spiels. Setze die Controllerberechtigung im Status nur bei Bedarf zurück und starte Steam neu. |
| VCRuntime fehlt | Starte einen vertrauenswürdigen Komponenteninstaller im betroffenen Prefix über Tools → Run Program. Nutze keine beliebigen DLL Downloadseiten. |
| Ubisoft oder ein anderer Launcher verlangt Windows Steam | Das kann ein Launcherproblem sein. Es beweist keine fehlende native Steam Integration. Prüfe die aktuellen Berichte im Originalprojekt. |
| Online Spiele oder Anti Cheat scheitern | VAC wird von dieser Integration nicht unterstützt. Andere Anti Cheat Systeme können ebenfalls inkompatibel mit Wine sein. |

Die Hilfe in der App erklärt diese Fälle ausführlicher. Im eingeklappten Bereich Wartung findest du Reparatur und Entfernen. Reparatur stellt Steam wieder her. Entfernen baut die NotProton Integration und ihre Runtime Komponenten ab und stellt Steam wieder her. Spieldownloads und Spielprefixe bleiben erhalten. Lies die Bestätigung des jeweiligen Vorgangs.

Das Blockieren von Steam Client Updates ist optional und verzögert auch Steam Fehlerbehebungen. Spielupdates laufen weiter. Eine ältere NotProton App verweigert das Überschreiben einer neueren Installation.

Für einen Fehlerbericht sind Spielname, macOS Version, genaue CrossOver Buildnummer, gewähltes Tool und reproduzierbare Schritte hilfreich. Prüfe die Zusammenfassung vor dem Kopieren. Rohe Logs können private Pfade und Fehlerdetails enthalten und sollten separat geprüft werden.

## Fokus auf CrossOver

Dieser Fork konzentriert sich auf CrossOver. Es wird keine kostenlose Wine Runtime eingebaut, keine CrossOver Aktivierung umgangen und keine Unterstützung beliebiger Wine Engines versprochen. Eine weitere Runtime braucht eigene geprüfte Binärprofile und eine funktionierende Steam Brücke.

## Was geprüft wurde

Das vorherige lokale Paket `1.1.0-local.1` wurde aus einem bereinigten Integrationsstand selbst installiert. Normal Golf Game war mit CrossOver 26.3 Rosetta sichtbar und spielbar. Das bestätigt noch keine spätere UI Änderung oder andere Spiele.

Die aktuellen automatisierten und visuellen Prüfungen stehen in [VALIDATION.md](VALIDATION.md). FEX Spielbetrieb, Intel Macs, ältere macOS Versionen, physische Controller und eine breite Spieleliste wurden hier nicht vollständig geprüft.

Bauanleitung, Struktur und Lizenzhinweise stehen in der [englischen README](../README.md). Die ursprünglichen Lizenzhinweise in [NOTICE](../NOTICE) gelten weiterhin.
