# Statuto Tecnico di Vision

Questo documento definisce i principi vincolanti di architettura, stabilità e integrità dei dati per lo sviluppo e la manutenzione di **Vision**.

## 1. Integrità e Retrocompatibilità del Database (`ProjectDatabase`)

Il database di produzione dell'utente risiede in `~/Library/Application Support/Vision/projects.db` (SQLite con snapshot JSON `ProjectDocumentData`) ed è affiancato dai backup automatici gestiti da `ProjectBackupManager`. **Nessuna modifica al codice, nessun test e nessuna migrazione deve mai corrompere, sovrascrivere o rendere illeggibile un database o un progetto esistente.**

### Regole vincolanti per modelli e DTO (`Codable`)
1. **Solo estensioni additive e opzionali**: Ogni nuovo campo aggiunto a struct/classi serializzate (`ProjectDocumentData`, `TimelineModelData`, `TimelineTrackData`, `TimelineClipData`, `MediaItemData`, `MediaFolder`, ecc.) **deve essere opzionale (`?`)** con valore di default sicuro al caricamento (`nil` o fallback deterministico).
2. **Divieto di rottura dello schema**: Non rinominare, rimuovere o cambiare il tipo di chiavi/proprietà JSON esistenti, né modificare i `rawValue` di enum già persistite senza fallback di decodifica retrocompatibile.
3. **Schema SQLite non distruttivo**: La tabella `projects` non deve subire `DROP`, `TRUNCATE` o `ALTER` distruttivi. Eventuali evoluzioni devono preservare integralmente le righe esistenti.
4. **Resilienza al caricamento**: File mancanti o volumi rinominati non devono causare perdita di record; i percorsi vanno risolti in sicurezza mantenendo i metadati originali.

### Regole vincolanti per Test e Script di Verifica
1. **Isolamento totale dal DB reale**: Tutti i test, target `xctest`, eseguibili `verify_*` o `probe_*` **devono** usare esclusivamente un database temporaneo isolato (tramite variabile d'ambiente `VISION_DB_PATH` oppure la guardia automatica su `vision_test_projects.db` in `ProjectDatabase.getDatabaseURL()`).
2. **Divieto di accesso al DB utente nei test**: È severamente vietato eseguire test, script di migrazione o probe puntando a `~/Library/Application Support/Vision/projects.db`.
3. **Verifica retrocompatibilità**: Ogni modifica ai modelli persistiti deve poter decodificare un `ProjectDocumentData` generato dalle versioni precedenti senza errori né perdita di timeline, clip, cartelle, proxy, LUT o posizione della testina (`playheadSeconds`).

## 2. Principi di UX & Editing NLE
- **Stato visuale coerente**: Cambio LUT, cambio Proxy e modifiche di timeline non devono mai resettare visivamente il viewer al punto iniziale (`00:00:00:00`) o perdere la posizione del playhead.
- **Ordinamento deterministico**: Le cartelle nel Media Pool restano sempre in cima; il drag & drop multiplo verso la timeline rispetta esattamente l'ordinamento visivo della cartella attiva.
- **Controlli non invasivi**: Scrollbar e interazioni (zoom canvas, grab con tasto centrale in timeline) non devono invadere le aree riservate ai controlli delle tracce (`V1`, `A1`, lock, visibilità, mute).
