---
name: opencode-orchestrate
description: Orchestrazione del codice a consumo ridotto di token — Claude fa da planner, orchestrator e reviewer, mentre delega l'esecuzione agentica (lettura/scrittura file, edit, test) a opencode CLI (DeepSeek V4) invocato non-interattivamente. Use when the user wants to save Claude tokens on coding tasks, offload implementation work, or says any of "delega a opencode", "fai fare a opencode", "usa opencode per", "/opencode", "orchestrazione opencode", "offload to opencode", "risparmia token", "modalita` orchestratore", "planner orchestrator reviewer", "execution su opencode". Use proactively for implementation-heavy tasks (bulk edits, scaffolding, refactor meccanici, test-writing, feature ben specificate) dove il grosso del costo token sarebbe leggere e riscrivere file.
---

# /opencode-orchestrate — Claude pianifica e revisiona, opencode esegue

## Ruoli

| Ruolo | Chi | Cosa fa | Cosa NON fa |
|---|---|---|---|
| **Planner** | Claude | Decompone il task, scrive spec precise | Non legge i file che opencode modifichera` |
| **Orchestrator** | Claude | Lancia opencode via `oc_run.sh`, gestisce iterazioni | Non scrive codice direttamente |
| **Executor** | opencode (DeepSeek V4) | Legge i file, edita, scrive, esegue i test | Non decide architettura, non fa git push |
| **Reviewer** | Claude | Revisiona via `git diff`, verifica exit code dei test | Non rilegge interi file |

**Obiettivo: minimizzare i token consumati da Claude.** Ogni byte di codice che
Claude legge o scrive e` un costo evitabile: il codice lo tocca opencode.

## Pre-flight (sempre, prima di delegare)

```bash
OC=~/.npm-global/bin/opencode          # SOLO il build npm: lo snap fallisce
$OC --version                          # sotto shell systemd-hardened (snap-confine)
$OC providers 2>&1 | head -5           # auth DeepSeek presente?
cd <REPO> && git rev-parse HEAD && git status --porcelain | head
```

- **Auth assente** → STOP, chiedi all'utente: `opencode auth login` (deepseek) oppure
  esporta `DEEPSEEK_API_KEY`. Non proseguire alla cieca.
- **Tree sporco** → segnalalo all'utente prima di delegare; annota sempre l'HEAD
  di partenza per il rollback.
- opencode eredita config da `~/.config/opencode/opencode.jsonc` (permessi
  auto-allow, snapshot attivi, istruzioni da `~/.claude/CLAUDE.md` e
  `~/MASTER_CONTEXT.md`): i worker partono gia` contestualizzati.

## Protocollo

### 1 — PLAN (Claude, token-frugale)

Costruisci il quadro SENZA leggere i sorgenti per intero:
- `tree -L 2` / `ls`, `grep -rln <simbolo>`, GitNexus per la mappa del codice.
- Leggi al massimo firme/interfacce (`grep -n "def \|class \|fn " file | head`).

Scrivi la spec in un prompt file (`/tmp/oc-task-N.md`). Ogni spec DEVE contenere:
- **Path esatti** dei file da creare/modificare.
- **Simboli esatti** (funzioni, classi) da introdurre o cambiare.
- **Criteri di accettazione concreti** (comportamento osservabile).
- **Comando di verifica** che opencode deve eseguire da solo
  (es. `pytest tests/ -x -q`, `cargo build`, `npm test`) e l'obbligo di
  iterare finche' non passa.
- **Limiti**: "non toccare file fuori da <scope>", "niente commit, niente push".

### 2 — DELEGATE (Claude → opencode)

```bash
RUN=~/.claude/skills/opencode-orchestrate/scripts/oc_run.sh
$RUN -d ~/projects/<repo> -t <titolo-task> -T 600 -p /tmp/oc-task-1.md
```

**Scelta del modello (`-m`).** Di default opencode usa `deepseek-v4-pro`
(da `opencode.jsonc`). Come orchestratore, in fase di PLAN sai gia` se il task
e` meccanico o complesso: instrada di conseguenza.
- `-m deepseek/deepseek-v4-flash` → task su singolo file, scaffolding, edit
  meccanici, test-writing su spec chiara. ~68% piu` economico, ~invisibile il
  gap di coding (SWE-bench 79.0 vs 80.6), piu` veloce.
- `-m deepseek/deepseek-v4-pro` (o ometti il flag) → refactor multi-file,
  invarianti cross-file, catene agentiche lunghe (Terminal-Bench: gap di 11
  punti a favore di Pro), qualunque task dove un errore costa un ciclo ITERATE.
- Nel dubbio, o se il primo giro Flash fallisce la REVIEW: ridelega a Pro.

- Il wrapper restituisce exit code, path del log e tail compatto (≤60 righe,
  niente ANSI). **Leggi solo quello.** Il log completo e` su disco per i casi
  dubbi — non rileggerlo se il tail basta.
- Task seriali nello stesso repo: le correzioni continuano l'ultima sessione
  con `-c` (mantiene il contesto lato opencode, costo zero lato Claude).
- Task paralleli: SOLO su repo/worktree distinti (`git worktree add`), un
  `oc_run.sh` per directory, mai due worker sugli stessi file. Con worker
  paralleli non usare `-c` (ambiguo): usa `-s <sessionID>` se serve riprendere.

### 3 — REVIEW (Claude, a diff, mai a file interi)

```bash
cd <repo>
git diff --stat                  # prima la forma: file e volumi
git diff -- <file-sospetto>      # poi il merito, solo dove serve
<comando test>; echo "RC=$?"     # fidati dell'exit code, non rileggere i test
```

Checklist: scope rispettato? file fuori spec toccati? simboli richiesti
presenti (`grep -n`)? test verdi? niente segreti/credenziali nel diff?

### 4 — ITERATE (max 3 cicli)

Review fallita → prompt correttivo MINIMO (solo cosa e` sbagliato e cosa ci si
aspetta, niente ripetizione della spec):

```bash
echo "Il test X fallisce con <errore>. Correggi SOLO <file>: <aspettativa>." | \
  $RUN -d ~/projects/<repo> -c -t <titolo-task>-fix
```

Dopo 3 cicli falliti → STOP. Riporta all'utente diff parziale, errore e opzioni
(intervento diretto di Claude, rollback, o respec). Non bruciare token in loop.

### 5 — REPORT

- Sintesi: cosa e` cambiato (`git diff --stat`), esito test, n. iterazioni.
- Costo executor: `$OC stats | head -20` (token/costo DeepSeek lato opencode).
- Rollback disponibile: `git reset --hard <HEAD-annotato>` (solo su conferma utente).

## Regole dure di economia token (per Claude)

1. MAI leggere per intero un file che opencode creera` o modifichera`.
2. Review SEMPRE a diff: `--stat` prima, diff mirato poi.
3. La verifica dei test la esegue opencode; Claude controlla solo l'exit code.
4. Correzioni via `-c` (sessione calda), mai ri-spec da zero.
5. Output di opencode: solo il tail del wrapper; il log integrale resta su disco.
6. Spec chirurgiche e brevi: path + simboli + accettazione, niente prosa.

## Cosa NON delegare

- Decisioni architetturali, refactor ambigui con invarianti cross-file, security review → restano a Claude.
- Operazioni irreversibili (push, deploy, migrazioni, `rm -rf`, modifiche a servizi systemd) → Claude + conferma esplicita dell'utente.
- Task che richiedono i tool MCP della sessione Claude (FreeCAD, chrome-devtools, SauronsEye).
- Micro-task: se la risposta sta in 30 secondi di Claude, l'overhead di delega non ripaga.

## Troubleshooting

| Sintomo | Causa | Fix |
|---|---|---|
| `snap-confine ... cap_dac_override` | invocato lo snap da shell systemd-hardened | usa `~/.npm-global/bin/opencode` (gia` default del wrapper) |
| `Unauthorized: Authentication Fails` | manca credenziale DeepSeek | `opencode auth login` o `DEEPSEEK_API_KEY` nell'env |
| exit 124 dal wrapper | timeout | alza `-T`, o spezza il task in spec piu` piccole |
| worker tocca file fuori scope | spec troppo vaga | respec con limiti espliciti, rollback mirato del file |

## Report automatico costi (Athena/Telegram)

Ogni sera alle 21:30 il timer `oc-stats-report.timer` (systemd user) esegue
`scripts/oc_stats_report.sh 1`: estrae `opencode stats --days 1` e invia un
riepilogo compatto (sessioni, costo $, token in/out, cache) via
`athena/modules/comm-tg/outbound.py` — categoria `system_update`, quindi
passa dal budget arbiter come ogni altro messaggio. Zero sessioni nella
finestra → nessun messaggio. Test manuale senza invio:
`oc_stats_report.sh 1 --dry-run`.
