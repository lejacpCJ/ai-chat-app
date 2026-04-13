# Phase 0 — Bootstrap

> Goal: Scaffold the Next.js project, install all dependencies, wire environment variables, and run the database migration so every subsequent phase starts from a clean, runnable baseline.

---

## Step 1 — Scaffold the Next.js App

Run the following from the **parent** directory (one level above where `ai-chat-app/` will live):

```bash
npx create-next-app@latest ai-chat-app
```

When prompted, answer **exactly**:

| Prompt | Answer |
|---|---|
| TypeScript? | Yes |
| ESLint? | Yes |
| Tailwind CSS? | Yes |
| `src/` directory? | Yes |
| App Router? | Yes |
| Turbopack for `next dev`? | No (stick with webpack for stability) |
| Customize import alias? | No (keep default `@/*`) |

> **Why Tailwind v3?** `create-next-app` as of early 2026 scaffolds Tailwind v4 by default. You must pin to v3 — see Step 3 below.

After scaffolding, `cd` into the project:

```bash
cd ai-chat-app
```

---

## Step 2 — Install Dependencies

```bash
npm install \
  @supabase/supabase-js \
  @supabase/ssr \
  @anthropic-ai/sdk \
  react-markdown \
  remark-gfm \
  react-syntax-highlighter

npm install -D \
  @types/react-syntax-highlighter
```

| Package | Purpose |
|---|---|
| `@supabase/supabase-js` | Supabase client (auth, DB queries, Realtime) |
| `@supabase/ssr` | SSR-safe Supabase client factory (`createBrowserClient`, `createServerClient`) |
| `@anthropic-ai/sdk` | Official Anthropic SDK — streaming + `.abort()` support |
| `react-markdown` | Render AI responses as Markdown |
| `remark-gfm` | GitHub Flavored Markdown plugin (tables, strikethrough, etc.) |
| `react-syntax-highlighter` | Syntax-highlighted code blocks inside Markdown |
| `@types/react-syntax-highlighter` | TypeScript types for the above |

---

## Step 3 — Pin Tailwind to v3

If `create-next-app` installed Tailwind v4, downgrade:

```bash
npm install -D tailwindcss@^3 postcss autoprefixer
npx tailwindcss init -p
```

Your `tailwind.config.js` should look like this after init:

```js
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './src/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
```

And `src/app/globals.css` should include the v3 directives:

```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```

> **Why v3?** The plan specifies v3 explicitly. Tailwind v4 has a different config format (`tailwind.config.ts` + CSS-based config) that is not compatible with the patterns used in this project.

---

## Step 4 — Create `.env.local`

Create `.env.local` in the project root:

```bash
touch .env.local
```

Populate it with your credentials:

```env
# Supabase — Project Settings → API
NEXT_PUBLIC_SUPABASE_URL=https://<your-project-ref>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=<your-anon-key>

# Anthropic — console.anthropic.com → API Keys
ANTHROPIC_API_KEY=sk-ant-...
```

**Important key name:** The Supabase dashboard shows `anon public` — the env var must be `NEXT_PUBLIC_SUPABASE_ANON_KEY`, **not** `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`. Using the wrong name is a common mistake that silently breaks the auth client.

> `ANTHROPIC_API_KEY` has no `NEXT_PUBLIC_` prefix — it must never be exposed to the browser. It is only referenced in server-side route handlers.

Add `.env.local` to `.gitignore` (it is already excluded by the Next.js default `.gitignore` — verify this):

```bash
grep '\.env\.local' .gitignore
# should output: .env.local
```

---

## Step 5 — Run the Database Migration

The full schema lives in `supabase/migrations/001_init.sql` (create this file now — see below). Run it manually in the **Supabase SQL editor**:

1. Open your project at [supabase.com/dashboard](https://supabase.com/dashboard)
2. Navigate to **SQL Editor** → **New Query**
3. Paste the full contents of `001_init.sql`
4. Click **Run**

### `supabase/migrations/001_init.sql`

Create the file at the path above with the following content:

```sql
-- Tables
create table public.conversations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  title      text not null default 'New Chat',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index conversations_user_id_updated_at
  on public.conversations(user_id, updated_at desc);

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  role            text not null check (role in ('user', 'assistant')),
  content         text not null,
  created_at      timestamptz not null default now()
);
create index messages_conversation_id_created_at
  on public.messages(conversation_id, created_at asc);

create table public.rate_limits (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  window_start  timestamptz not null default now(),
  message_count integer not null default 0
);

-- Trigger: bump conversations.updated_at on each message insert
create function public.touch_conversation()
returns trigger language plpgsql as $$
begin
  update public.conversations set updated_at = now() where id = new.conversation_id;
  return new;
end;
$$;

create trigger on_message_insert
  after insert on public.messages
  for each row execute function public.touch_conversation();

-- Row Level Security
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;
alter table public.rate_limits   enable row level security;

create policy "users_own_conversations" on public.conversations
  for all using ((select auth.uid()) = user_id);

create policy "users_own_messages" on public.messages
  for all using (
    exists (
      select 1 from public.conversations c
      where c.id = conversation_id and c.user_id = (select auth.uid())
    )
  );

create policy "users_own_rate_limit" on public.rate_limits
  for all using ((select auth.uid()) = user_id);
```

**Verify migration ran correctly** — in the Supabase Table Editor you should see three new tables: `conversations`, `messages`, `rate_limits`.

---

## Step 6 — Enable Supabase Realtime

The sidebar uses Realtime to push live conversation list updates. Enable it for the `conversations` table:

1. Supabase dashboard → **Database** → **Replication**
2. Under **Supabase Realtime**, toggle on the `conversations` table
3. Leave `messages` and `rate_limits` off (not needed for Realtime)

---

## Step 7 — Smoke Test

Start the dev server and confirm the scaffold works:

```bash
npm run dev
```

- Open [http://localhost:3000](http://localhost:3000)
- You should see the default Next.js welcome page with no console errors
- Tailwind styles should be applied (the page should not look unstyled)

### Checklist

- [ ] `npm run dev` starts without errors
- [ ] `http://localhost:3000` renders the Next.js default page
- [ ] `.env.local` exists and is excluded from git (`git status` should not list it)
- [ ] Three tables visible in Supabase Table Editor: `conversations`, `messages`, `rate_limits`
- [ ] Realtime enabled for `conversations` table
- [ ] `node_modules/@supabase`, `node_modules/@anthropic-ai`, `node_modules/react-markdown` all present

---

## Directory State After Phase 0

```
ai-chat-app/
├── .env.local                        # credentials (gitignored)
├── .gitignore
├── next.config.ts
├── tailwind.config.js                # v3 config
├── postcss.config.js
├── tsconfig.json
├── package.json
├── supabase/
│   └── migrations/
│       └── 001_init.sql              # schema (already run in Supabase)
└── src/
    ├── app/
    │   ├── globals.css               # @tailwind directives
    │   ├── layout.tsx
    │   └── page.tsx                  # default Next.js welcome page (will be replaced)
    └── (no lib/, hooks/, components/ yet — added in Phase 1+)
```
