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
  v_owner_email constant text := 'endstudeo@gmail.com';
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
  id, kind, name_en, name_bn, account_number, account_name, account_fields,
  supports_reference, evidence_fields, is_active, sort_order
)
values (
  '00000000-0000-4000-8000-000000000001',
  'bkash',
  'bKash',
  'বিকাশ',
  '01700000000',
  'Cofibuy',
  '[
    {"key":"account_number","label_en":"Account / wallet number","value":"01700000000"},
    {"key":"account_name","label_en":"Account name","value":"Cofibuy"}
  ]'::jsonb,
  true,
  '[
    {"key":"sender_number","type":"text","label_en":"Sender number","label_bn":"প্রেরকের নম্বর","required":true,"validate":"bd_phone","max_len":20},
    {"key":"amount","type":"number","label_en":"Amount sent","label_bn":"প্রেরিত টাকার পরিমাণ","required":true,"validate":"numeric"},
    {"key":"trxid","type":"text","label_en":"Transaction ID (TrxID)","label_bn":"ট্রানজেকশন আইডি","required":true,"validate":"trxid","max_len":24},
    {"key":"screenshot","type":"image","label_en":"Payment screenshot","label_bn":"পেমেন্টের স্ক্রিনশট","required":false,"max_mb":4}
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
-- The `pages_publishable` check refuses an active link with no title and
-- no unlocked body, so all four of those are set. This is what `/:slug` renders
-- once the customer views land.
--
-- Unlike the gateway above this one does `do update`: it is demo copy for a
-- product that only exists to show the flow, so it is expected to be rewritten
-- whenever the customer-facing UI changes. The gateway holds real account
-- details an operator may have edited, so it stays `do nothing`.
-- ---------------------------------------------------------------------------

insert into public.pages (
  slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
  unlock_body_md_en, unlock_body_md_bn,
  unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
  is_active, sort_order
)
values (
  'demo-report',
  'SSC Exam Strategy Handbook',
  'এসএসসি পরীক্ষার কৌশল হ্যান্ডবুক',
  '### What is inside

A 34-page handbook for students sitting SSC this year: a week-by-week revision
plan, the chapters that carry the most marks, and 40 previous-year questions
with worked solutions.

**Format:** PDF · **Language:** Bangla and English · **Edition:** 2026',
  '### ভেতরে যা আছে

এই বছর এসএসসি পরীক্ষার্থীদের জন্য ৩৪ পৃষ্ঠার হ্যান্ডবুক: সপ্তাভিত্তিক রিভিশন পরিকল্পনা, সবচেয়ে নম্বরবহুল অধ্যায়গুলো, এবং ৪০টি আগের বর্ষের প্রশ্ন ও বিস্তারিত সমাধান।

**ফরম্যাট:** পিডিএফ · **ভাষা:** বাংলা ও ইংরেজি · **সংস্করণ:** ২০২৬',
  '## How to use this handbook

1. **Read the revision plan first.** It assumes you have six weeks. If you have
   fewer, skip to the compressed schedule on page 9.
2. **Attempt the 40 questions timed.** Most students lose marks to pacing
   rather than knowledge. Treat the timer as part of the practice.
3. **Revise by chapter weight, not by dislike.** The highest-weight chapters
   are the ones students tend to avoid.

## Chapter weight

| Chapter | Marks | Priority |
| --- | --- | --- |
| Mathematics | 40 | High |
| Physics | 25 | Medium |
| Chemistry | 20 | Medium |
| Biology | 15 | Medium |
| Higher Mathematics | 30 | High |

## What you get after paying

The full PDF, delivered to your email within a few minutes of your order being
approved. You can re-download it from the same link as many times as you need.',
  '## হ্যান্ডবুকটি কীভাবে ব্যবহার করবেন

১. **প্রথমে রিভিশন পরিকল্পনাটি পড়ুন।** এতে ছয় সপ্তাহের কথা ধরা আছে। সময় কম
হলে পৃষ্ঠা ৯-এর সংক্ষিপ্ত সূচিতে যান।

২. **৪০টি প্রশ্ন সময়মতো সমাধান করুন।** অধিকাংশ ছাত্র জ্ঞানের ঘাটতিতে নয়,
গতির ঘাটতিতে নম্বর হারায়। ঘড়িকে অনুশীলনের অংশ হিসেবে ধরে নিন।

৩. **অধ্যায় ভিত্তিক গুরুত্ব অনুযায়ী পড়ুন।** সবচেয়ে বেশি নম্বরের অধ্যায়গুলোই
ছাত্ররা এড়িয়ে যেতে বলে ভুল করেন।

## অধ্যায়ের নম্বরবিভাজন

| অধ্যায় | নম্বর | অগ্রাধিকার |
| --- | --- | --- |
| গণিত | ৪০ | উচ্চ |
| পদার্থবিজ্ঞান | ২৫ | মাঝারি |
| রসায়ন | ২০ | মাঝারি |
| জীববিজ্ঞান | ১৫ | মাঝারি |
| উচ্চতর গণিত | ৩০ | উচ্চ |

## পেমেন্টের পর যা পাবেন

পূর্ণ পিডিএফটি অর্ডার অনুমোদনের কয়েক মিনিটের মধ্যেই আপনার ইমেইলে পৌঁছে যাবে। একই
লিংক থেকে যতবার খুশি আবার ডাউনলোড করতে পারবেন।',
  'Download the handbook',
  'হ্যান্ডবুক ডাউনলোড করুন',
  'https://example.com/ssc-handbook',
  true,
  10
)
on conflict (slug) do update
set title_en = excluded.title_en,
    title_bn = excluded.title_bn,
    teaser_md_en = excluded.teaser_md_en,
    teaser_md_bn = excluded.teaser_md_bn,
    unlock_body_md_en = excluded.unlock_body_md_en,
    unlock_body_md_bn = excluded.unlock_body_md_bn,
    unlock_cta_label_en = excluded.unlock_cta_label_en,
    unlock_cta_label_bn = excluded.unlock_cta_label_bn,
    unlock_cta_url = excluded.unlock_cta_url;
