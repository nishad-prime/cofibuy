-- Development and demo data.
--
-- Runs automatically on `supabase db reset` (local stack). For a hosted project
-- it is not run by `supabase db push`, so paste it into the dashboard's SQL
-- editor once, after changing the owner email below.
--
-- Idempotent: safe to run again.

-- ---------------------------------------------------------------------------
-- The first owner
--
-- `api.admin_set_staff` refuses anyone who is not already an owner, so the very
-- first one cannot be created through the API and has to be inserted here. Put
-- the email you will actually sign in with. The user row is created if it does
-- not exist, so you can run this before signing up; the password still has to be
-- set through the app or the dashboard.
-- ---------------------------------------------------------------------------

do $$
declare
  v_owner_email constant text := 'owner@example.com';
  v_user_id uuid;
begin
  select id into v_user_id from auth.users where lower(email) = lower(v_owner_email);

  if v_user_id is null then
    insert into auth.users (email) values (v_owner_email) returning id into v_user_id;
    raise notice 'created auth user % for the first owner', v_user_id;
  end if;

  insert into public.staff (user_id, role) values (v_user_id, 'owner')
  on conflict (user_id) do update set role = 'owner';
end
$$;

-- ---------------------------------------------------------------------------
-- A gateway to pay through
--
-- Without one, `api.create_order` has nothing to create an order against and the
-- checkout flow cannot be exercised at all.
-- ---------------------------------------------------------------------------

-- A fixed id, because `payment_gateways` has no natural unique key and
-- `on conflict do nothing` without one silently inserts a second copy every time
-- the seed is re-run.
insert into public.payment_gateways (
  id, kind, name_en, name_bn, account_number, account_name,
  supports_reference, evidence_fields, is_active, sort_order
)
values (
  '00000000-0000-4000-8000-000000000001',
  'bkash',
  'bKash',
  'বিকাশ',
  '01700000000',
  'Cofibuy',
  true,
  '[
    {"key":"sender_number","type":"text","label_en":"Sender number","label_bn":"প্রেরকের নম্বর","required":true,"validate":"bd_phone","max_len":20},
    {"key":"amount","type":"number","label_en":"Amount sent","label_bn":"প্রেরিত টাকার পরিমাণ","required":true,"validate":"numeric"},
    {"key":"trxid","type":"text","label_en":"TrxID","label_bn":"ট্রানজেকশন আইডি","required":true,"validate":"trxid","max_len":24},
    {"key":"screenshot","type":"image","label_en":"Screenshot","label_bn":"স্ক্রিনশট","required":false,"max_mb":4}
  ]'::jsonb,
  true,
  10
)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- A link to sell
--
-- `slug` is unique, so this one conflicts on its own.
--
-- The `paywall_links_publishable` check refuses an active link with no title and
-- no unlocked body, so all four of those are set. This is what `/:slug` renders
-- once the customer views land.
-- ---------------------------------------------------------------------------

insert into public.paywall_links (
  slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
  unlock_body_md_en, unlock_body_md_bn,
  unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
  is_active, sort_order
)
values (
  'demo-report',
  'Demo report',
  'ডেমো রিপোর্ট',
  'A short teaser shown before the paywall.',
  'পেওয়ালের আগে দেখানো সংক্ষিপ্ত বিবরণ।',
    'The full report, unlocked once payment is confirmed.',
    'পেমেন্ট নিশ্চিত হলে সম্পূর্ণ রিপোর্ট।',
  'Read the report',
  'রিপোর্ট পড়ুন',
  'https://example.com/report',
  true,
  10
)
-- `do nothing` rather than `do update`: re-running the seed should not quietly
-- undo edits made through the admin panel.
on conflict (slug) do nothing;
