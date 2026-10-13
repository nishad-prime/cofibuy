-- Telegram invite-link delivery.
--
-- When an order is approved, a single-use-per-order invite link to the
-- page's Telegram channel/group is created via the shop's bot (a separate
-- Cloudflare Worker in bot/). The customer sees the link as the join button
-- in the payment modal's status phase.
--
-- Two creators, one guarantee:
--   * bkash-execute calls the bot directly (instant for auto payments)
--   * the bot's cron picks up manual approvals every minute (catch-all)
-- `telegram_invites.order_id` is the primary key, so both paths are
-- idempotent — whoever lands first wins, the other is a no-op.
--
-- RLS is enabled on both tables with zero policies: default deny. The bot
-- uses the service-role key (bypasses RLS); customers read exclusively via
-- `api.get_telegram_invite`, which checks ownership inline.

create table public.telegram_invites (
  order_id uuid primary key references public.orders(id) on delete cascade,
  invite_url text not null,
  chat_type text not null default 'channel' check (chat_type in ('channel', 'group')),
  max_uses integer not null default 2,
  uses_count integer not null default 0,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.telegram_invites enable row level security;

create table public.telegram_invite_errors (
  order_id uuid primary key references public.orders(id) on delete cascade,
  attempts integer not null default 0,
  last_error text,
  last_attempt_at timestamptz not null default now()
);

alter table public.telegram_invite_errors enable row level security;

-- ---------------------------------------------------------------------------
-- The bot's work queue: approved orders whose page targets a Telegram chat,
-- that have no invite yet, and that have not exhausted the retry budget.
-- Readable only by the service role.
-- ---------------------------------------------------------------------------
create view public.telegram_pending_invites as
select
  o.id as order_id,
  p.template_config->>'telegram_chat_id' as chat_id,
  coalesce(p.template_config->>'telegram_chat_type', 'channel') as chat_type
from public.orders o
join public.pages p on p.id = o.link_id
left join public.telegram_invite_errors e on e.order_id = o.id
where o.status = 'approved'
  and coalesce(p.template_config->>'telegram_chat_id', '') <> ''
  and not exists (select 1 from public.telegram_invites ti where ti.order_id = o.id)
  and coalesce(e.attempts, 0) < 5
  and coalesce(e.last_attempt_at, '1970-01-01'::timestamptz) < now() - interval '5 minutes';

revoke all on public.telegram_pending_invites from public, anon, authenticated;
grant select on public.telegram_pending_invites to service_role;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- The customer's own invite, for the modal's status phase. Ownership is
-- checked inline; the table itself is unreachable.
create or replace function api.get_telegram_invite(p_order_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $$
declare
  v_order public.orders;
  v_invite public.telegram_invites;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = auth.uid();
  if not found then
    return null;
  end if;

  select * into v_invite from public.telegram_invites where order_id = v_order.id;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'url', v_invite.invite_url,
    'chat_type', v_invite.chat_type,
    'revoked', v_invite.revoked
  );
end
$$;

revoke all on function api.get_telegram_invite(uuid) from public, anon;
grant execute on function api.get_telegram_invite(uuid) to authenticated, service_role;

-- Bot webhook: a member joined through an invite link.
create or replace function api.telegram_invite_used(p_invite_url text)
 returns void
 language sql
 security definer
 set search_path to ''
as $$
  update public.telegram_invites
  set uses_count = uses_count + 1
  where invite_url = p_invite_url;
$$;

revoke all on function api.telegram_invite_used(text) from public, anon, authenticated;
grant execute on function api.telegram_invite_used(text) to service_role;

-- Bot: a creation attempt failed (bad chat id, bot not admin, Telegram down).
create or replace function api.telegram_invite_failed(p_order_id uuid, p_error text)
 returns void
 language sql
 security definer
 set search_path to ''
as $$
  insert into public.telegram_invite_errors (order_id, attempts, last_error, last_attempt_at)
  values (p_order_id, 1, p_error, now())
  on conflict (order_id) do update
    set attempts = telegram_invite_errors.attempts + 1,
        last_error = excluded.last_error,
        last_attempt_at = now();
$$;

revoke all on function api.telegram_invite_failed(uuid, text) from public, anon, authenticated;
grant execute on function api.telegram_invite_failed(uuid, text) to service_role;
