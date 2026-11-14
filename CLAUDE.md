# OHZ Bobrowniki — aplikacja fermy bydła mlecznego

Właściciel nie jest programistą: odpowiadaj po polsku, prostym językiem, bez żargonu.

## Co to jest
- Aplikacja PWA w jednym pliku `index.html` (HTML + CSS + JS, bez budowania). `sw.js` = tryb offline, `manifest.json` = instalacja na telefonie.
- Dane: Firebase Firestore, projekt `ohz-bobrowniki-po-app`, kolekcja `ohz_data` (dokument na moduł + `config` z uprawnieniami i blokadami ról).
- Logowanie: Firebase Authentication, jedno konto na rolę: `<rola>@ohz-bobrowniki.app` (tworca, zootechnik, prezes, magazynier, paszowoz).
- Zasady bazy: `firestore.rules` — po zmianie trzeba je wkleić w konsoli Firebase (Firestore → Rules → Publish).

## Zasady
- Nigdy nie wpisuj haseł do kodu ani do Firestore.
- Każda zmiana dostępu do danych musi zgadzać się z `firestore.rules`.
- Po zmianach przetestuj aplikację w przeglądarce (Playwright) przed zapisaniem.
