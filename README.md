# ac-sw — Atelier Carliza Studio

The platform layer for AC tooling: a chat-first user portal (**AC_Intent**) + an admin control surface (**AC_Admin**) + an Auth Gate v1.0 block that gates every shipped tool against Supabase Auth + RLS.

Cloned from the DN Platform pattern, retuned for AC scale and AC brand.

---

## What's in this repo

| File | Purpose |
|---|---|
| `AC_Intent.html` | End-user portal. Chat-first catalog of tools, request new tools, see access state. Liza, Claudia, Philip all open this. |
| `AC_Admin.html` | Admin control surface (Philip only). Manage requests, build new tools via Claude API, grant access, ship to GitHub Pages. |
| `templates/ac_auth_gate_template.html` | The 6KB auth gate that gets dropped at the top of every shipped tool's `<body>`. |
| `bootstrap.sql` | One-shot Supabase setup — schema, RLS, helpers, AIOps-handover columns. Run once after creating the Supabase project. |
| `docs/google-oauth-setup.md` | Step-by-step Google Cloud Console + Supabase auth config. |

---

## Stack

- **Hosting**: GitHub Pages (static; `https://<user>.github.io/ac-sw/`)
- **Auth**: Supabase Auth + Google Workspace OAuth (locked to `@ateliercarliza.com`)
- **Database**: Supabase Postgres + RLS (project `qqkgtjfurjepaaglxohq`)
- **Builds**: Anthropic API (Claude Opus 4.7 default, Sonnet 4.6 fallback) — admin-only, key in browser localStorage
- **Local tools**: ac-launcher.exe spawns Python backends (PPE, LayerForge, FrameForge); their HTML serves on localhost ports with the same auth gate baked in

---

## Phase 1 — Deploy checklist (one-time, ~2 hours)

Do top to bottom.

### 1. Run the database bootstrap (~5 min)

1. Open `https://supabase.com/dashboard/project/qqkgtjfurjepaaglxohq/sql/new`
2. Paste the entire contents of `bootstrap.sql` and **Run**.
3. Verify: **Database → Tables** shows `profiles`, `requests`, `app_access`, `access_requests`, `activity_log`, `anthropic_token_costs`, `user_settings` — each with RLS enabled.

### 2. Configure Google OAuth (~15 min)

Follow `docs/google-oauth-setup.md` end-to-end.

### 3. Create the GitHub repo (~5 min)

1. New repo on your GitHub account: `ac-sw` — **public**, no README/license/gitignore (we have one).
2. **Settings → Pages → Source**: Deploy from a branch → main → / (root). Save.
3. From this folder (`C:\Users\Philip Korf\Dropbox\Atelier Carliza LLC\AC SW\ac-sw`), initialize git and push:
   ```bash
   git init
   git add .
   git commit -m "AC Studio v1 — bootstrap from DN handover kit"
   git branch -M main
   git remote add origin git@github.com:<your-user>/ac-sw.git
   git push -u origin main
   ```
4. Wait ~60s for first Pages build. Test: `https://<your-user>.github.io/ac-sw/` should serve a directory listing or a 404 (no index.html yet — fine).

### 4. First sign-in + promote yourself to admin (~5 min)

1. Open `https://<your-user>.github.io/ac-sw/AC_Intent.html` in **incognito**.
2. Click "Sign in with Google" → sign in with your `@ateliercarliza.com` account.
3. You'll land on "Access denied" — that's correct (no admin yet).
4. In Supabase SQL Editor:
   ```sql
   UPDATE public.profiles
   SET is_admin = true
   WHERE email = 'philip@ateliercarliza.com';
   ```
5. Reload AC_Intent → gate reveals.

### 5. Set Anthropic key + GitHub PAT in AC_Admin (~5 min)

1. Open `AC_Admin.html` in same browser.
2. Top-right gear icon → **Settings**.
3. Paste:
   - **Anthropic API key** (`sk-ant-...`) — for the build agent
   - **GitHub token** — fine-grained PAT with `contents:write` on `<your-user>/ac-sw`
   - **GitHub repo**: `<your-user>/ac-sw`
4. Save.

### 6. Smoke test: build + ship a hello-world tool (~10 min)

1. AC_Intent → chat box → "Build me a hello world page that says hi from AC Studio".
2. Agent will ask follow-up questions, then offer to submit. Confirm.
3. Switch to AC_Admin → new request appears in the sidebar.
4. Click it → **Build**. Watch the artifact generate.
5. When `ready_for_qa`: **Preview** → looks good → **Approve** → **Ship**.
6. Set lifecycle to `active` via dropdown.
7. Reload AC_Intent → hello-world tool now appears in "Authorized".

### 7. Invite Liza and Claudia

1. Send them: `https://<your-user>.github.io/ac-sw/AC_Intent.html`
2. They sign in with their `@ateliercarliza.com` accounts. Profile rows auto-created.
3. They'll see "Access denied" until you grant. Open AC_Admin → top-right **Users** → toggle the right things, or use **App Access** panel.

---

## Phase 2 — Onboard existing tools

Three tools to migrate, in this order (per Philip):

| # | Tool | Type | Effort |
|---|---|---|---|
| 1 | **LayerCut** | static HTML | ~30 min — gate retrofit + sync from live |
| 2 | **LayerForge** | python backend | ~45 min — gate retrofit on Flask template + launcher API hookup |
| 3 | **Print Production Editor** | python backend | ~45 min — same pattern as LayerForge |

For static tools: follow `handover_kit/07_existing_app_migration.md` — same script, just substitute the AC Supabase URL/key and use `templates/ac_auth_gate_template.html` instead.

For python tools: the gate goes into the Flask template's `<body>`. Flask serves the gated HTML on localhost, same as static. Auth still works (Supabase URLs accept any origin in the Redirect URLs list — already set in OAuth setup).

---

## Architecture in one diagram

```
┌──────────────────────────────────────────────────────────────┐
│       Supabase project (ac-platform)                          │
│   qqkgtjfurjepaaglxohq.supabase.co                            │
│   • Auth: Google Workspace (hd=ateliercarliza.com)            │
│   • Postgres + RLS:                                           │
│     profiles · requests · app_access · access_requests        │
│     · activity_log · anthropic_token_costs · user_settings    │
└──────────────────────────────────────────────────────────────┘
        ▲                  ▲                       ▲
        │                  │                       │
┌───────┴────────┐  ┌──────┴────────┐  ┌──────────┴──────────┐
│  AC_Intent     │  │  AC_Admin     │  │ Every shipped tool  │
│  chat-first    │  │  request mgr, │  │ has Auth Gate v1.0  │
│  catalog       │  │  build agent  │  │ at top of <body>    │
└───────┬────────┘  └───────────────┘  └─────────┬───────────┘
        │                                         │
        │ "Launch" / "Stop" (local actions)       │
        ▼                                         │
┌──────────────────────┐                          │
│ ac-launcher (local)  │                          │
│ 127.0.0.1:9999       │                          │
│ process manager + API│                          │
└────┬─────────────────┘                          │
     │ spawns                                     │
     ▼                                            ▼
┌──────────────────────┐         ┌─────────────────────────────┐
│ Python backends      │         │ Static HTML tools           │
│ PPE, LayerForge,     │         │ LayerCut, Maker Toolkit,    │
│ FrameForge           │         │ PromptForge + AC_Admin      │
│ (gated on localhost) │         │ builds (GitHub Pages)       │
└──────────────────────┘         └─────────────────────────────┘
```

---

## Lessons from DN that carry over (read once)

These are the gotchas that bit us at DN. Don't re-learn them.

1. **Artifact drift** — if you edit a shipped tool's HTML directly (paste from Claude, hand-edit) without going through AC_Admin, AC_Admin's stored `artifact_html` goes stale. A future rebuild would ship the stale version. **Mitigation**: AC_Admin's `checkArtifactDrift` runs before every build and the **↻ Sync from live** button manually re-syncs. Use it after any direct edit.

2. **Patches-mode is brittle** — the build agent can paraphrase find-strings when emitting patches. AC_Admin's build prompt forces full-HTML output for auth-gate retrofits and other surgical edits. Don't override.

3. **RLS recursion** — solved by `SECURITY DEFINER` helpers `is_admin()` and `has_app_access()`. Don't write raw policies that re-query `profiles`.

4. **The publishable key triggers content filters** in some assistant contexts even though it's *designed* to be safe in client code. If you need to paste files containing it back into a chat, split across messages.

5. **GitHub Pages caches aggressively** — after a push, force-refresh (Ctrl+Shift+R) to see changes. Don't assume the deploy failed; check response headers `age` and `cache-control`.

6. **Remove surface before adding** when redesigning UX — Intent was originally cluttered with stages, dashboard cards, mode pickers. Chat-first only worked once those were stripped out, not when a chat panel was bolted on top.

Full lessons-learned in `../handover_kit/08_lessons_learned.md`.
