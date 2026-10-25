# psst 🤫

Anonymous messages for your Instagram and Snapchat stories. Like NGL, but **free, open source, no paywall and no bot messages**.

**Live:** https://sendpsst.vercel.app

## Features

- Personal link to put on your story with the link sticker
- Anyone can send you a message, no account needed (with a 🎲 random-question button)
- Private inbox only you can open
- Reply and turn any message into a 1080×1920 story image, shared straight to Instagram or Snapchat on mobile
- Safety: built-in filter for the worst harassment, your own blocked words, block sender, pause inbox, rate limits
- One-tap story sharing like NGL: a ready-made story pic for Instagram (your link is auto-copied for the link sticker) and Snapchat sharing with your link attached
- Installable: add it to your home screen and it opens full-screen like a real app
- **Free hints** on every message: the sender's phone type, approximate city and time. Senders are told this on the send page, and their name is never revealed (no app can do that, NGL included)
- **Games** like NGL: anonymous messages, tbh, never have i ever, confessions, 3 words, rate me, shoot your shot, ask me anything, red or green flag. Each has its own colors on the send page and story pics
- **Profile picture** on your send page and story pic
- **Push notifications** for new messages (on iPhone, add psst to your home screen first)
- No fake messages, no paywall, no tracking or analytics

## Guides

Shareable step-by-step pictures for adding psst to your home screen: [iPhone](guides/psst-home-screen-iphone.png) · [Android](guides/psst-home-screen-android.png) · Arabic: [iPhone](guides/psst-home-screen-iphone-ar.png) · [Android](guides/psst-home-screen-android-ar.png)

## How it works

- **Frontend:** one static `index.html` (vanilla JS, no build step), hosted on Vercel. `vercel.json` routes every `/username` to it. `api/geo.js` gives the sender's approximate city for hints, `sw.js` shows notifications.
- **Backend:** Supabase Postgres. Tables are fully locked; the app only calls the functions in [`supabase/schema.sql`](supabase/schema.sql).
- **Anonymity:** senders are identified only by a salted hash of their IP, used for rate limits and blocking. Nobody (not even the inbox owner) sees who sent a message.
- Passwords are hashed with bcrypt; logins use random session tokens stored hashed.

## Run your own

1. Create a free [Supabase](https://supabase.com) project and run `supabase/schema.sql`, then `supabase/02_ngl_features.sql` in its SQL editor.
   For notifications: generate keys with `npx web-push generate-vapid-keys`, save them plus a random `hook_secret` in `app_config` (see the commented line), set your project ref in the trigger, and deploy `supabase/functions/notify` with JWT verification off.
2. In `index.html`, set `SB` to your project URL and `KEY` to its anon (public) key.
3. Deploy the folder to [Vercel](https://vercel.com) (or any static host that can rewrite all paths to `index.html`).

## License

MIT
