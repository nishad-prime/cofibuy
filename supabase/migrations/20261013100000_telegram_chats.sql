-- Chat discovery: the bot persists every group/channel it encounters via its
-- webhook, so the admin form can show a dropdown instead of a raw chat ID.
--
-- `my_chat_member` (bot added/removed) and `chat_member` / `message` /
-- `channel_post` (activity in a chat) all carry the chat object. The bot
-- upserts on every webhook call. Private DMs are skipped by the bot.

create table public.telegram_chats (
  chat_id text primary key,
  title text not null default '',
  type text not null default 'channel' check (type in ('channel', 'group', 'supergroup')),
  added_at timestamptz not null default now()
);

alter table public.telegram_chats enable row level security;

-- Staff-only read: the admin form populates its dropdown from this.
create or replace function api.telegram_chats()
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $$
begin
  if not private.is_staff() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'chat_id', c.chat_id,
        'title', c.title,
        'type', c.type
      ) order by c.added_at desc
    )
    from public.telegram_chats c
  ), '[]'::jsonb);
end
$$;

revoke all on function api.telegram_chats() from public, anon;
grant execute on function api.telegram_chats() to authenticated, service_role;
