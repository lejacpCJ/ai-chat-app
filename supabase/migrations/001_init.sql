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
