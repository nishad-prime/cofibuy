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

-- ---------------------------------------------------------------------------
-- Three more demo pages
--
-- They exist to show the range of the template system and the index: one
-- landing-template page with its config fully populated, the same shape
-- hidden from the index (reachable only by its URL, which is what "hidden"
-- means here - it is not an access control), and a second standard page so
-- the index lists more than one row.
--
-- Unlike the gateway above, these do `do update`: demo copy for products that
-- only exist to show the flow, so it is expected to be rewritten whenever the
-- customer-facing UI changes.
-- ---------------------------------------------------------------------------

insert into public.pages (
  slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
  unlock_body_md_en, unlock_body_md_bn,
  unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
  template, template_config,
  is_active, is_listed, sort_order
)
values (
  'freelancing-starter-kit',
  'Freelancing Starter Kit',
  'ফ্রিল্যান্সিং স্টার্টার কিট',
  'Everything you need to send your first invoice within two weeks.',
  'দুই সপ্তাহের মধ্যে প্রথম ইনভয়েস পাঠানোর জন্য যা যা দরকার।',
  '## Your download

The starter kit (PDF + three contract templates + the rate calculator
spreadsheet) is below. Re-download any time from this page.',
  '## আপনার ডাউনলোড

স্টার্টার কিট (পিডিএফ + তিনটি চুক্তির নমুনা + রেট ক্যালকুলেটর স্প্রেডশিট) নিচে। এই
পেজ থেকে যতবার খুশি আবার ডাউনলোড করুন।',
  'Get the kit', 'কিটটি নিন', 'https://example.com/starter-kit',
  'landing',
  '{
    "subtitle_en": "Contracts, pricing scripts and a 30-day plan, written for Bangladeshi freelancers.",
    "subtitle_bn": "বাংলাদেশি ফ্রিল্যান্সারদের জন্য লেখা চুক্তি, প্রাইসিং স্ক্রিপ্ট এবং ৩০ দিনের পরিকল্পনা।",
    "items": [
      { "title_en": "Three contract templates", "title_bn": "তিনটি চুক্তির নমুনা",
        "body_en": "Fixed-price, hourly and retainer - copy, fill in the blanks, send.",
        "body_bn": "ফিক্সড-প্রাইস, ঘণ্টাভিত্তিক এবং রিটেইনার - কপি করুন, খালি ঘর পূরণ করুন, পাঠান।" },
      { "title_en": "The rate calculator", "title_bn": "রেট ক্যালকুলেটর",
        "body_en": "A spreadsheet that turns your target monthly income into an hourly rate.",
        "body_bn": "আপনার মাসিক আয়ের লক্ষ্যকে ঘণ্টাভিত্তিক রেটে রূপ দেওয়ার স্প্রেডশিট।" },
      { "title_en": "The 30-day plan", "title_bn": "৩০ দিনের পরিকল্পনা",
        "body_en": "Profile, portfolio and first-client outreach, one small task a day.",
        "body_bn": "প্রোফাইল, পোর্টফোলিও ও প্রথম ক্লায়েন্টের সন্ধান - প্রতিদিন ছোট একটি কাজ।" },
      { "title_en": "Payment scripts", "title_bn": "পেমেন্ট স্ক্রিপ্ট",
        "body_en": "Exact sentences for quoting, raising an invoice and following up.",
        "body_bn": "দাম বলা, ইনভয়েস পাঠানো ও ফলোআপের জন্য হুবহু বাক্য।" }
    ],
    "faq": [
      { "q_en": "Is this useful outside Bangladesh?", "q_bn": "বাংলাদেশের বাইরে কি এটি কাজে লাগবে?",
        "a_en": "The contracts and scripts work anywhere; the payment and tax parts are BD-specific.",
        "a_bn": "চুক্তি ও স্ক্রিপ্ট সব জায়গায় কাজ করে; পেমেন্ট ও কর অংশ বাংলাদেশভিত্তিক।" },
      { "q_en": "Do I need experience?", "q_bn": "অভিজ্ঞতা দরকার?",
        "a_en": "No. The plan assumes you are starting from zero this month.",
        "a_bn": "না। পরিকল্পনাটি ধরে নেয় আপনি এই মাসেই শুরু করছেন।" }
    ]
  }'::jsonb,
  true, true, 1
)
on conflict (slug) do update set
  title_en = excluded.title_en, title_bn = excluded.title_bn,
  teaser_md_en = excluded.teaser_md_en, teaser_md_bn = excluded.teaser_md_bn,
  unlock_body_md_en = excluded.unlock_body_md_en, unlock_body_md_bn = excluded.unlock_body_md_bn,
  unlock_cta_label_en = excluded.unlock_cta_label_en, unlock_cta_label_bn = excluded.unlock_cta_label_bn,
  unlock_cta_url = excluded.unlock_cta_url,
  template = excluded.template, template_config = excluded.template_config,
  is_active = excluded.is_active, is_listed = excluded.is_listed,
  sort_order = excluded.sort_order;

insert into public.pages (
  slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
  unlock_body_md_en, unlock_body_md_bn,
  unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
  template, template_config,
  is_active, is_listed, sort_order
)
values (
  'vip-resources',
  'VIP Resource Pack',
  'ভিআইপি রিসোর্স প্যাক',
  'The extended pack: every template, every checklist, plus the recordings.',
  'এক্সটেন্ডেড প্যাক: সব টেমপ্লেট, সব চেকলিস্ট, এবং রেকর্ডিং।',
  '## VIP pack

Everything in one zip: the kit, the advanced checklists and the workshop
recordings. This page is shared by direct link only.',
  '## ভিআইপি প্যাক

সব এক জিপে: কিট, অ্যাডভান্সড চেকলিস্ট এবং ওয়ার্কশপ রেকর্ডিং। এই পেজটি শুধু সরাসরি
লিংকে শেয়ার করা হয়।',
  'Download the pack', 'প্যাকটি ডাউনলোড করুন', 'https://example.com/vip-pack',
  'landing',
  '{
    "subtitle_en": "For people who bought the starter kit and want the rest of it.",
    "subtitle_bn": "যারা স্টার্টার কিট নিয়েছেন এবং বাকিটাও চান তাদের জন্য।",
    "items": [
      { "title_en": "Advanced checklists", "title_bn": "অ্যাডভান্সড চেকলিস্ট",
        "body_en": "Client onboarding, project close-out and the quarterly review.",
        "body_bn": "ক্লায়েন্ট অনবোর্ডিং, প্রজেক্ট সমাপ্তি ও ত্রৈমাসিক রিভিউ।" },
      { "title_en": "Workshop recordings", "title_bn": "ওয়ার্কশপ রেকর্ডিং",
        "body_en": "Four sessions on pricing, negotiation and scope control.",
        "body_bn": "প্রাইসিং, নেগোসিয়েশন ও স্কোপ নিয়ন্ত্রণ নিয়ে চারটি সেশন।" }
    ],
    "faq": []
  }'::jsonb,
  true, false, 2
)
on conflict (slug) do update set
  title_en = excluded.title_en, title_bn = excluded.title_bn,
  teaser_md_en = excluded.teaser_md_en, teaser_md_bn = excluded.teaser_md_bn,
  unlock_body_md_en = excluded.unlock_body_md_en, unlock_body_md_bn = excluded.unlock_body_md_bn,
  unlock_cta_label_en = excluded.unlock_cta_label_en, unlock_cta_label_bn = excluded.unlock_cta_label_bn,
  unlock_cta_url = excluded.unlock_cta_url,
  template = excluded.template, template_config = excluded.template_config,
  is_active = excluded.is_active, is_listed = excluded.is_listed,
  sort_order = excluded.sort_order;

insert into public.pages (
  slug, title_en, title_bn, teaser_md_en, teaser_md_bn,
  unlock_body_md_en, unlock_body_md_bn,
  unlock_cta_label_en, unlock_cta_label_bn, unlock_cta_url,
  is_active, sort_order
)
values (
  'ielts-writing-pack',
  'IELTS Writing Pack',
  'আইইএলটিএস রাইটিং প্যাক',
  'Twenty band-8 sample answers with the examiner commentary beside them.',
  '২০টি ব্যান্ড-৮ নমুনা উত্তর, পাশে পরীক্ষকের মন্তব্যসহ।',
  '## The pack

Twenty task-2 answers, each annotated with what moved it to band 8, plus the
six structures that cover almost every prompt type.',
  '## প্যাকটি

২০টি টাস্ক-২ উত্তর, প্রতিটির পাশে ব্যান্ড ৮-এ পৌঁছানোর কারণ, এবং প্রায় সব ধরনের
প্রশ্ন কাভার করা ছয়টি স্ট্রাকচার।',
  'Get the pack', 'প্যাকটি নিন', 'https://example.com/ielts-pack',
  true, 3
)
on conflict (slug) do update set
  title_en = excluded.title_en, title_bn = excluded.title_bn,
  teaser_md_en = excluded.teaser_md_en, teaser_md_bn = excluded.teaser_md_bn,
  unlock_body_md_en = excluded.unlock_body_md_en, unlock_body_md_bn = excluded.unlock_body_md_bn,
  unlock_cta_label_en = excluded.unlock_cta_label_en, unlock_cta_label_bn = excluded.unlock_cta_label_bn,
  unlock_cta_url = excluded.unlock_cta_url,
  template = excluded.template, template_config = excluded.template_config,
  is_active = excluded.is_active, is_listed = excluded.is_listed,
  sort_order = excluded.sort_order;
