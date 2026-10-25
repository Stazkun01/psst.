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
- No fake messages, no "pay to see who sent it", no tracking or analytics

## How it works

- **Frontend:** one static `index.html` (vanilla JS, no build step), hosted on Vercel. `vercel.json` routes every `/username` to it.
- **Backend:** Supabase Postgres. Tables are fully locked; the app only calls the functions in [`supabase/schema.sql`](supabase/schema.sql).
- **Anonymity:** senders are identified only by a salted hash of their IP, used for rate limits and blocking. Nobody (not even the inbox owner) sees who sent a message.
- Passwords are hashed with bcrypt; logins use random session tokens stored hashed.

## Run your own

1. Create a free [Supabase](https://supabase.com) project and run `supabase/schema.sql` in its SQL editor.
2. In `index.html`, set `SB` to your project URL and `KEY` to its anon (public) key.
3. Deploy the folder to [Vercel](https://vercel.com) (or any static host that can rewrite all paths to `index.html`).

## License

MIT
