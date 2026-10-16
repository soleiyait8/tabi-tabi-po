# Tabi Tabi Po — RSVP site

Salakot Opening Night · Halloween · Z Hostel, Poblacion Makati.
Static site (HTML/CSS/JS) + Supabase. Guests RSVP and get a QR ticket; staff see the guest list and check people in at `/admin.html`.

```
index.html                      Event page + RSVP flow + QR ticket
admin.html                      Staff dashboard (passcode) + door check-in scanner
config.js                       Supabase keys, date, DJs, perks  ← the file you edit
assets/css, assets/js           Styles and logic
assets/z-hostel-logo.png        Logo (from the poster)
assets/og-poster.jpg            Social-share preview image
supabase/migrations/*.sql       Database tables + functions
```

## Backend status

Already live on Supabase project **Zhostel Salakot Halloween** (`bsgyfctspsecimphiljp`, Tokyo).
Migration `20261013084653_tabi_tabi_po_rsvp` is applied. The filename in this repo matches that version,
so the GitHub → Supabase integration treats it as already applied. The SQL is idempotent, so a re-run is harmless.

`config.js` already holds the project URL and the **publishable** key. That key is meant to be public.
Never commit the `service_role` / `sb_secret_…` key.

## v2 features

| Feature | Where | Notes |
|---|---|---|
| Privacy notice + consent | `privacy.html`, RSVP form | Consent is required (enforced in the database). Marketing opt-in is separate and optional. |
| Source tracking | `?ref=name` on any link | Admin → "Promoter & partner links" builds them. Shown under "Came from". |
| Guest types | `?as=sponsor` (or media / artist / vip) | Tags the RSVP; badge on ticket, email, and door scanner. |
| Add to calendar | Ticket screen | Appears once `eventStartISO` is set in `config.js`. |
| Sponsor strip + inquiry form | `#partners` section | Logos via `sponsors` in `config.js`; inquiries listed in admin. |
| Z Hostel stay link | Ticket + venue | `bookingUrl` in `config.js`. |

## Publish (GitHub Pages)

Repo → Settings → Pages → Source: *Deploy from a branch* → `main` / `(root)` → Save.
Live URL: `https://<your-username>.github.io/<repo-name>/`. A custom domain can be added on the same screen.
The door scanner needs `https`, which Pages provides.

## First admin login (do this immediately after publishing)

1. Open `/admin.html`.
2. Passcode: `tabi-change-me-on-first-login`
3. You'll be forced to set a new passcode (12+ characters). The starter passcode then stops working.

## Event day

- `/admin.html` on a phone → **Check in guests** → scan. Green = welcome, yellow = already in, red = not found / cancelled.
- No camera? Type the code (e.g. `TTP-7KX2QM`).
- Lost QR: guest re-enters the same email on the site and gets the same ticket back.

## Changing event details

All in `config.js`. Set `eventStartISO` (e.g. `"2026-10-31T21:00:00+08:00"`) once the date is final: it replaces "Date TBA" and turns on the countdown. Update `djs`, `perks`, links the same way. Commit; Pages redeploys in about a minute.

## Security notes

- The browser cannot read the guest table. RLS is on with no policies; all access goes through database functions.
  Supabase's advisor will flag "RLS enabled, no policy" and "anon can execute SECURITY DEFINER function". Both are intentional for this design.
- Admin functions re-check the passcode on every call. 10 wrong passcodes from one IP = 15-minute lockout.
- Anyone who knows a guest's email can retrieve that guest's ticket (by design, for lost-ticket recovery).
- One shared passcode = no per-staff audit trail. Fine for one event; for a recurring system, move to Supabase Auth with individual staff logins.
