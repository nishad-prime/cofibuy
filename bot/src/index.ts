/// <reference types="@cloudflare/workers-types" />

/**
 * Telegram invite-link bot for cofibuy.
 *
 * One job: when an order is approved and the page targets a Telegram chat,
 * create an invite link (member_limit = 2) via the Bot API, store it, and
 * hand it back. Two creators — bkash-execute calls /api/create-invite
 * directly (instant for auto payments), the cron picks up manual approvals
 * every minute. `telegram_invites.order_id` is the primary key, so both
 * paths are idempotent.
 *
 * Secrets (wrangler secret put):
 *   TELEGRAM_BOT_TOKEN      — from @BotFather
 *   SHARED_SECRET           — cofibuy ↔ bot auth
 *   SUPABASE_URL            — project URL
 *   SUPABASE_SERVICE_ROLE_KEY — bypasses RLS for the invite tables
 */

export interface Env {
  TELEGRAM_BOT_TOKEN: string
  SHARED_SECRET: string
  SUPABASE_URL: string
  SUPABASE_SERVICE_ROLE_KEY: string
}

interface PendingInvite {
  order_id: string
  chat_id: string
  chat_type: string
}

/** The `chat` object Telegram puts on every update. */
interface TgChat {
  id: number | string
  title?: string
  type: string
}

/** Subset of Telegram update types the bot processes. */
interface TgUpdate {
  my_chat_member?: { chat?: TgChat }
  chat_member?: {
    chat?: TgChat
    invite_link?: { invite_link?: string }
    new_chat_member?: { status?: string }
  }
  message?: { chat?: TgChat }
  channel_post?: { chat?: TgChat }
}

function sbHeaders(env: Env): Record<string, string> {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    'content-type': 'application/json',
  }
}

async function createInviteLink(env: Env, chatId: string): Promise<string | null> {
  const res = await fetch(
    `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/createChatInviteLink`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: Number(chatId), member_limit: 2 }),
    },
  )
  const data = (await res.json().catch(() => null)) as {
    ok?: boolean
    result?: { invite_link?: string }
    description?: string
  } | null
  return data?.ok && data.result?.invite_link ? data.result.invite_link : null
}

async function recordFailure(env: Env, orderId: string, error: string): Promise<void> {
  await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/telegram_invite_failed`, {
    method: 'POST',
    headers: sbHeaders(env),
    body: JSON.stringify({ p_order_id: orderId, p_error: error.slice(0, 200) }),
  })
}

async function getInviteForOrder(env: Env, orderId: string): Promise<string | null> {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/telegram_invites?order_id=eq.${orderId}&select=invite_url`,
    { headers: sbHeaders(env) },
  )
  const rows = (await res.json().catch(() => [])) as Array<{ invite_url: string }>
  return rows[0]?.invite_url ?? null
}

async function processOne(env: Env, pending: PendingInvite): Promise<void> {
  const inviteUrl = await createInviteLink(env, pending.chat_id)
  if (!inviteUrl) {
    await recordFailure(
      env,
      pending.order_id,
      'createChatInviteLink failed — check bot admin rights and chat_id',
    )
    return
  }

  const insert = await fetch(`${env.SUPABASE_URL}/rest/v1/telegram_invites`, {
    method: 'POST',
    headers: { ...sbHeaders(env), Prefer: 'resolution=ignore-duplicates' },
    body: JSON.stringify({
      order_id: pending.order_id,
      invite_url: inviteUrl,
      chat_type: pending.chat_type,
      max_uses: 2,
    }),
  })
  if (!insert.ok) {
    await recordFailure(env, pending.order_id, `insert failed: ${insert.status}`)
  }
}

async function processPending(env: Env): Promise<void> {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/telegram_pending_invites?select=*`, {
    headers: sbHeaders(env),
  })
  if (!res.ok) return
  const pending = (await res.json().catch(() => [])) as PendingInvite[]
  for (const item of pending) {
    await processOne(env, item)
  }
}

/** Upserts a chat into the discovery table so the admin form can list it. */
async function upsertChat(env: Env, chat: TgChat): Promise<void> {
  await fetch(`${env.SUPABASE_URL}/rest/v1/telegram_chats`, {
    method: 'POST',
    headers: { ...sbHeaders(env), Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({
      chat_id: String(chat.id),
      title: chat.title ?? '',
      type: chat.type,
    }),
  })
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url)

    // Cofibuy edge function / admin panel triggers invite creation.
    if (url.pathname === '/api/create-invite' && request.method === 'POST') {
      if (request.headers.get('authorization') !== `Bearer ${env.SHARED_SECRET}`) {
        return Response.json({ ok: false, error: 'unauthorized' }, { status: 401 })
      }

      const body = (await request.json().catch(() => null)) as { orderId?: string } | null
      const orderId = body?.orderId
      if (!orderId || !/^[0-9a-f-]{36}$/i.test(orderId)) {
        return Response.json({ ok: false, error: 'orderId required' }, { status: 400 })
      }

      // Idempotent: if the invite already exists, return it.
      const existing = await getInviteForOrder(env, orderId)
      if (existing) {
        return Response.json({ ok: true, inviteUrl: existing, already: true })
      }

      const res = await fetch(
        `${env.SUPABASE_URL}/rest/v1/telegram_pending_invites?order_id=eq.${orderId}&select=*`,
        { headers: sbHeaders(env) },
      )
      const rows = (await res.json().catch(() => [])) as PendingInvite[]
      if (!rows.length) {
        return Response.json(
          {
            ok: false,
            error: 'order not eligible — not approved, no chat configured, or exhausted retries',
          },
          { status: 404 },
        )
      }

      await processOne(env, rows[0])

      const inviteUrl = await getInviteForOrder(env, orderId)
      return Response.json({ ok: !!inviteUrl, inviteUrl })
    }

    // Telegram's own webhook: member joins, chat discovery, messages.
    if (url.pathname === '/telegram/webhook' && request.method === 'POST') {
      // Telegram echoes back the secret_token set during setWebhook.
      if (request.headers.get('x-telegram-bot-api-secret-token') !== env.SHARED_SECRET) {
        return new Response('forbidden', { status: 403 })
      }

      const update = (await request.json().catch(() => null)) as TgUpdate | null

      // Chat discovery: persist every non-DM chat the bot encounters.
      const chat =
        update?.my_chat_member?.chat ??
        update?.chat_member?.chat ??
        update?.message?.chat ??
        update?.channel_post?.chat
      if (chat && chat.type !== 'private') {
        await upsertChat(env, chat)
      }

      const inviteUrl = update?.chat_member?.invite_link?.invite_link
      const status = update?.chat_member?.new_chat_member?.status
      if (inviteUrl && status === 'member') {
        await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/telegram_invite_used`, {
          method: 'POST',
          headers: sbHeaders(env),
          body: JSON.stringify({ p_invite_url: inviteUrl }),
        })
      }

      return new Response('ok')
    }

    return new Response('not found', { status: 404 })
  },

  // Cron catch-all: picks up manual approvals and retries failures within
  // the backoff budget (the pending view filters exhausted/cooldown rows).
  async scheduled(_event, env): Promise<void> {
    await processPending(env)
  },
} satisfies ExportedHandler<Env>
