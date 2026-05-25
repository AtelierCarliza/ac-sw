# Google Workspace OAuth — AC Studio setup

This is the exact, step-by-step setup for the `ac-platform` Supabase project to authenticate against `@ateliercarliza.com` Google Workspace accounts.

Total time: about 15-20 minutes.

---

## Prerequisites

- You have a Google Workspace admin role at `ateliercarliza.com`
- You have the Supabase project URL: `https://qqkgtjfurjepaaglxohq.supabase.co`
- You're signed into Google with an `@ateliercarliza.com` account (not a personal `@gmail.com`)

---

## Part 1 — Google Cloud Console (~10 min)

### Step 1. Create or open a Google Cloud project

1. Go to **https://console.cloud.google.com**
2. Project selector at top → **New Project**
   - Name: `Atelier Carliza Studio`
   - Organization: select **ateliercarliza.com** (NOT "No organization")
3. Create. Wait ~30s for provisioning.

### Step 2. OAuth consent screen

1. Left nav → **APIs & Services → OAuth consent screen**
2. User Type: **Internal** *(only @ateliercarliza.com accounts can sign in)*
3. Click **Create**.
4. Fill in:
   - App name: `Atelier Carliza Studio`
   - User support email: `philip@ateliercarliza.com` (your address)
   - App logo: optional — you can add the AC mark later
   - App home page: `https://carliza.com` (your website)
   - Developer contact: `philip@ateliercarliza.com`
5. **Save and continue**.
6. **Scopes** step: don't add any — Supabase requests `openid email profile` at runtime. **Save and continue**.
7. **Summary**: review, then **Back to dashboard**.

### Step 3. Create OAuth client ID

1. Left nav → **APIs & Services → Credentials**
2. **+ Create Credentials → OAuth client ID**
3. Application type: **Web application**
4. Name: `AC Studio Web Client`
5. **Authorized JavaScript origins** — add both:
   ```
   https://<your-github-username>.github.io
   ```
   *(Once you decide on a custom domain like `studio.ateliercarliza.com`, add that too.)*

6. **Authorized redirect URIs** — add exactly this (no trailing slash):
   ```
   https://qqkgtjfurjepaaglxohq.supabase.co/auth/v1/callback
   ```

7. **Create**.
8. A modal pops up with your **Client ID** and **Client Secret**. **Copy both** — you'll paste them into Supabase next.

---

## Part 2 — Supabase (~5 min)

### Step 4. Enable Google provider

1. Open **https://supabase.com/dashboard/project/qqkgtjfurjepaaglxohq/auth/providers**
2. Find **Google** in the providers list. Click to expand.
3. Toggle **Enabled** to ON.
4. Paste:
   - **Client ID (for OAuth)**: from Google (step 3.8)
   - **Client Secret (for OAuth)**: from Google (step 3.8)
5. **Skip nonce checks**: leave OFF (default).
6. **Save**.

### Step 5. Configure auth URLs

1. Left nav → **Authentication → URL Configuration**
2. **Site URL**: set to your primary GitHub Pages URL:
   ```
   https://<your-github-username>.github.io/ac-sw/AC_Intent.html
   ```
3. **Redirect URLs** — add wildcards so any AC tool page is allowed:
   ```
   https://<your-github-username>.github.io/ac-sw/*
   http://localhost:5000/*
   http://localhost:5001/*
   http://localhost:5002/*
   http://localhost:8765/*
   http://127.0.0.1:9999/*
   ```
   *(The localhost entries are for the python-backed tools — LayerForge, FrameForge, PPE, AIOps, and the future ac-launcher local API.)*

4. **Save**.

---

## Part 3 — Smoke test (~5 min)

1. Open `https://<your-github-username>.github.io/ac-sw/AC_Intent.html` in an **incognito window**.
2. You should see the AC Studio auth gate with "Sign in with Google".
3. Click it.
4. Google consent screen appears — you should see your @ateliercarliza.com accounts listed (no @gmail.com offered, because the `hd` parameter restricts it).
5. Choose your account → "Allow".
6. You're back at AC Studio → the gate shows "Access denied" because you're not yet an admin.
7. Open Supabase SQL Editor → run:
   ```sql
   UPDATE public.profiles
   SET is_admin = true
   WHERE email = 'philip@ateliercarliza.com';
   ```
   *(replace with your actual address)*
8. Reload AC_Intent.html → the gate reveals → you're in.

---

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| **"redirect_uri_mismatch"** from Google | The Supabase callback URL in step 3.6 is missing or has a typo | Re-check exact URL: `https://qqkgtjfurjepaaglxohq.supabase.co/auth/v1/callback` (no trailing slash) |
| Gate stuck on "checking access…" forever | RLS policy denying SELECT on `profiles` | Verify `bootstrap.sql` ran successfully — try `SELECT * FROM public.profiles;` in SQL Editor while signed in |
| Sign-in completes but page reloads to same gate | Supabase Site URL doesn't match the page URL | Add your GitHub Pages URL to **Redirect URLs** in step 5 |
| Personal `@gmail.com` accounts can sign in | OAuth consent screen set to "External" instead of "Internal" | Go back to step 2.2 — change to Internal *(requires Workspace admin)* |
| "Access blocked: This app's request is invalid" | The Google Cloud project isn't owned by your Workspace org | Re-do step 1 with Organization = ateliercarliza.com |

---

## What's running where (mental model)

```
Browser (incognito)
   │
   │ 1. user clicks "Sign in with Google"
   ▼
accounts.google.com
   │  consent screen filtered to @ateliercarliza.com (hd param)
   │
   │ 2. user picks account, Google issues OAuth code
   ▼
qqkgtjfurjepaaglxohq.supabase.co/auth/v1/callback
   │  Supabase exchanges code for session token
   │
   │ 3. redirect back to AC Studio page with #access_token=...
   ▼
github.io/ac-sw/AC_Intent.html
   │  Auth gate sees session, runs 3-way access check against
   │  profiles + requests + app_access tables
   │
   │ 4. reveals the page (or shows access-denied)
   ▼
User uses the tool
```
