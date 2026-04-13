# Plan: AI Chat App MVP (v3 — Finalized)

Incorporates all decisions from `plan-02.md` review. Ready to implement.

---

## Stack

| Layer | Choice | Reason |
|---|---|---|
| Full-stack framework | Next.js 15 (App Router) | Route Handlers natively support `ReadableStream` for streaming; collocates frontend + API |
| Database + Auth | Supabase (Postgres + Auth) | Real Postgres for relational data, built-in SSR auth, Row Level Security, generous free tier |
| AI | Anthropic `claude-sonnet-4-6` | Per spec; SDK supports `.abort()` for Stop button and delta streaming |
| Styling | Tailwind CSS v3 | Standard `tailwind.config.js` setup via `create-next-app` scaffold |
| Markdown | `react-markdown` + `remark-gfm` + `react-syntax-highlighter` | Full GFM support + code block syntax highlighting |

---

## Directory Structure

```
ai-chat-app/
├── .env.local                          # NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY, ANTHROPIC_API_KEY
├── supabase/migrations/001_init.sql    # Full schema + RLS
│
├── src/
│   ├── middleware.ts                   # Auth guard: redirects unauthenticated users to /login
│   │
│   ├── app/
│   │   ├── (auth)/login/page.tsx
│   │   ├── (auth)/signup/page.tsx
│   │   ├── (app)/chat/layout.tsx       # Sidebar + main area shell
│   │   ├── (app)/chat/page.tsx         # Empty state
│   │   ├── (app)/chat/[conversationId]/page.tsx
│   │   └── api/
│   │       ├── chat/route.ts           # POST: stream response (most complex)
│   │       ├── conversations/route.ts  # GET list, POST create
│   │       ├── conversations/[id]/route.ts           # GET messages, DELETE conversation
│   │       ├── conversations/[id]/title/route.ts     # POST: generate + save title
│   │       └── conversations/[id]/messages/[msgId]/route.ts  # DELETE (for regenerate)
│   │
│   ├── components/
│   │   ├── sidebar/Sidebar.tsx, ConversationItem.tsx, LogoutButton.tsx
│   │   └── chat/ChatContainer.tsx, MessageList.tsx, MessageBubble.tsx,
│   │           MarkdownRenderer.tsx, ChatInput.tsx, ActionBar.tsx,
│   │           RateLimitBanner.tsx, ErrorBanner.tsx
│   │
│   ├── hooks/
│   │   ├── useChat.ts          # Core streaming state machine
│   │   ├── useConversations.ts # Sidebar list with optimistic delete + Realtime subscription
│   │   └── useAutoScroll.ts
│   │
│   ├── lib/
│   │   ├── supabase/client.ts  # createBrowserClient
│   │   ├── supabase/server.ts  # createServerClient (for route handlers)
│   │   ├── anthropic.ts        # Singleton Anthropic client
│   │   ├── rateLimit.ts        # Sliding window check + DB upsert
│   │   └── titleGenerator.ts  # Haiku call for 3-5 word title
│   │
│   └── types/index.ts
```

---

## Database Schema (`001_init.sql`)

```sql
create table public.conversations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  title      text not null default 'New Chat',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index conversations_user_id_updated_at on public.conversations(user_id, updated_at desc);

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  role            text not null check (role in ('user', 'assistant')),
  content         text not null,
  created_at      timestamptz not null default now()
);
create index messages_conversation_id_created_at on public.messages(conversation_id, created_at asc);

create table public.rate_limits (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  window_start  timestamptz not null default now(),
  message_count integer not null default 0
);

-- Trigger: bump conversations.updated_at on each message insert
create function public.touch_conversation() returns trigger language plpgsql as $$
begin
  update public.conversations set updated_at = now() where id = new.conversation_id;
  return new;
end; $$;
create trigger on_message_insert after insert on public.messages
  for each row execute function public.touch_conversation();

-- RLS
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;
alter table public.rate_limits   enable row level security;

create policy "users_own_conversations" on public.conversations
  for all using ((select auth.uid()) = user_id);
create policy "users_own_messages" on public.messages
  for all using (
    exists (select 1 from public.conversations c
            where c.id = conversation_id and c.user_id = (select auth.uid()))
  );
create policy "users_own_rate_limit" on public.rate_limits
  for all using ((select auth.uid()) = user_id);
```

---

## Implementation Phases (ordered by dependency)

### Phase 0 — Bootstrap
- `npx create-next-app@latest` (TypeScript, Tailwind **v3**, App Router, src dir)
- Install: `@supabase/supabase-js @supabase/ssr @anthropic-ai/sdk react-markdown remark-gfm react-syntax-highlighter @types/react-syntax-highlighter`
- Create `.env.local` with `NEXT_PUBLIC_SUPABASE_ANON_KEY` (not `PUBLISHABLE_KEY`) — match the key name shown in your Supabase dashboard under Project Settings → API
- Run SQL migration in Supabase dashboard

### Phase 1 — Auth Foundation
- `src/lib/supabase/client.ts` — `createBrowserClient`
- `src/lib/supabase/server.ts` — `createServerClient` with cookie handling
- `src/middleware.ts` — intercepts all routes, redirects unauthenticated to `/login`
- Login and Signup pages: call `supabase.auth.signInWithPassword` / `signUp`, redirect to `/chat` on success
- **Test:** `/chat` unauthenticated → `/login`; login → `/chat`

### Phase 2 — Conversation CRUD API Routes
- `GET /api/conversations` — list by `updated_at DESC`
- `POST /api/conversations` — create with title "New Chat"
- `GET /api/conversations/[id]` — return messages `ORDER BY created_at ASC`
- `DELETE /api/conversations/[id]` — cascade deletes messages
- `POST /api/conversations/[id]/title` — calls `titleGenerator.ts`, saves title
- `DELETE /api/conversations/[id]/messages/[msgId]` — for Regenerate feature

### Phase 3 — Streaming Chat Route (`src/app/api/chat/route.ts`)
Critical file. Key pattern:
```typescript
// 1. Auth check → 2. Rate limit check → 3. Persist user message
// 4. Build ReadableStream fed by Anthropic MessageStream
// 5. On each text_delta: controller.enqueue(encoded chunk)
// 6. Wire req.signal → anthropicStream.abort() for Stop button
// 7. In finally: ALWAYS persist accumulated content to DB, even if stream
//    was aborted mid-way. Save accumulatedContent as-is (may be partial).
//    If accumulatedContent is empty string, still save to mark the turn.
```

**Message truncation (handled in route handler, not client):**
- Take the last 20 messages total from the conversation history
- Always preserve the very first user message for context, even if it falls outside the 20-message window
- Implementation: slice `messages.slice(-20)`, then check if `messages[0]` is already included; if not, prepend it

**Accepts:** `{ conversationId, messages: [{role, content}][] }` — full history; route handler performs truncation  
**Returns:** `Content-Type: text/plain` streaming response

### Phase 4 — Auto-Titling (`src/lib/titleGenerator.ts`)
- Single non-streaming call to `claude-haiku-4-5-20251001` (cheap + fast)
- Prompt: `"Generate a 3-5 word title for this conversation. Reply with ONLY the title."`
- Triggered client-side after first assistant response completes (fire-and-forget fetch)
- **If the user navigates away before stream completes, the title is never generated.** The conversation keeps its default title "New Chat". Acceptable for MVP — no special handling needed.

### Phase 5 — Rate Limiting (`src/lib/rateLimit.ts`)
- Sliding 1-hour window, threshold = 50 (hidden from client)
- DB upsert pattern: reset window if expired, increment count, return boolean
- Route handler returns HTTP 429 + `{ rateLimited: true }` if exceeded
- Client shows `RateLimitBanner.tsx` with friendly message

### Phase 6 — UI Components

**`ChatInput.tsx`**
- `<textarea rows={1}>`, auto-expand via `onInput: el.style.height = el.scrollHeight + 'px'`
- `onKeyDown`: `Enter` (no Shift) → submit; `Shift+Enter` → newline
- `disabled` when `isStreaming === true`

**`MarkdownRenderer.tsx`**
- `<ReactMarkdown remarkPlugins={[remarkGfm]}` with custom `code` component
- Block code: `<SyntaxHighlighter language={...} style={oneDark}>` + absolute-positioned "Copy Code" button using `navigator.clipboard.writeText()`

**`ActionBar.tsx`**
- `isStreaming` → shows "Stop" button → calls `abortController.abort()`
- `!isStreaming && messages.length >= 2` → shows "Regenerate" → deletes last assistant message from DB + local state, resubmits last user message
- **Note:** if Regenerate is clicked and the subsequent stream fails, the conversation will have a dangling user message with no assistant response. No rollback is implemented for MVP — acceptable.

**`ErrorBanner.tsx`**
- Shown when `streamStatus === 'error'` (non-rate-limit errors, e.g. Anthropic 500)
- Displays inline below the message list: red-tinted banner with text "Something went wrong. Please try again."
- Dismissed automatically when the user sends a new message (status resets to `'idle'`)

**`useChat.ts`** — Central state machine:
```typescript
type StreamStatus = 'idle' | 'streaming' | 'error' | 'rate_limited'
// sendMessage: optimistic append, fetch stream, read loop → streamingContent state
// stop: abortController.abort()
// regenerate: slice messages, delete last assistant from DB, resend
// On non-429 fetch error or stream read error → set status to 'error'
```

**`Sidebar.tsx`** + **`ConversationItem.tsx`** + **`LogoutButton.tsx`**
- `useConversations` hook: fetch initial list, then subscribe to Supabase Realtime on the `conversations` table filtered by `user_id = auth.uid()`
  - On `INSERT` event: prepend new conversation to list
  - On `UPDATE` event (title change): update the matching item in place
  - On `DELETE` event: remove from list
  - Unsubscribe on component unmount
- "New Chat": `POST /api/conversations` → navigate to new ID
- Highlight active via `usePathname()`
- **Logout button** at the bottom of the sidebar: calls `supabase.auth.signOut()`, then `router.push('/login')`

**`useAutoScroll.ts`** — watches `streamingContent`, calls `scrollIntoView({ behavior: 'smooth' })`

### Phase 7 — Page Assembly
- `chat/layout.tsx` — two-column: 240px sidebar + flex-1 main
- `chat/[conversationId]/page.tsx` — Server Component fetching initial history, passes to `<ChatContainer initialMessages={...}>`
- Wire auto-title: after first streaming response, fire-and-forget title fetch; the Realtime subscription in `useConversations` picks up the `UPDATE` event and refreshes the sidebar title automatically — no manual invalidation needed

---

## Critical Files

| File | Complexity | Notes |
|---|---|---|
| `src/app/api/chat/route.ts` | High | Streaming, abort propagation, truncation, DB persistence |
| `src/hooks/useChat.ts` | High | All client streaming state transitions |
| `src/hooks/useConversations.ts` | Medium | Realtime subscription wiring |
| `src/middleware.ts` | Medium | Must be correct before any routes work |
| `src/components/chat/MarkdownRenderer.tsx` | Medium | Custom code block with Copy button |
| `supabase/migrations/001_init.sql` | Medium | Full schema + RLS — run once |

---

## Decisions Log

| # | Question | Decision |
|---|---|---|
| 1 | `PUBLISHABLE_KEY` or `ANON_KEY`? | `NEXT_PUBLIC_SUPABASE_ANON_KEY` |
| 2 | Tailwind v3 or v4? | v3 |
| 3 | Sidebar refresh strategy? | Supabase Realtime subscription |
| 4 | Logout in scope? | Yes — button at bottom of sidebar |
| 5 | Partial message on Stop: save or skip? | Save `accumulatedContent` as-is in `finally` |
| 6 | Who truncates to 20 messages? | Route handler |
| 7 | Truncation: total or per-role? | 20 total; always prepend first user message if outside window |
| 8 | Regenerate + failed stream rollback? | No rollback for MVP |
| 9 | Error state UI for non-rate-limit errors? | Inline `ErrorBanner` with "Something went wrong. Please try again." |
| 10 | Title if user navigates away before stream completes? | Conversation keeps "New Chat" title |

---

## Verification (End-to-End Test Checklist)

- [ ] `/chat` unauthenticated → redirects to `/login`
- [ ] Sign up → auto-redirect to `/chat`
- [ ] New Chat → URL changes, sidebar shows "New Chat" item
- [ ] Send message → typewriter streaming effect visible
- [ ] After stream: sidebar title updates from "New Chat" to auto-generated title (via Realtime)
- [ ] Open same account in two tabs: new conversation in tab A appears in tab B sidebar automatically (Realtime)
- [ ] Click Stop mid-stream → streaming halts, partial message saved to DB
- [ ] Regenerate → new response replaces old, only one assistant message in DB
- [ ] Code block renders with syntax highlighting + Copy Code button works
- [ ] Sidebar shows conversations newest-first; clicking loads full history
- [ ] Delete conversation → removed from sidebar
- [ ] Logout button → signs out, redirects to `/login`
- [ ] Context: "My name is Alex" → follow-up "What is my name?" → Claude answers correctly
- [ ] Rate limit: lower threshold to 3, send 4 messages → friendly banner appears
- [ ] Anthropic error simulation → red inline error banner appears
- [ ] Two accounts: account B cannot access account A's conversation (RLS)
- [ ] `ANTHROPIC_API_KEY` never appears in browser network tab
