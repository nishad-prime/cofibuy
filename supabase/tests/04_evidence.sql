-- Evidence submission.
--
-- The customer is uploading proof they already paid, on the strength of what
-- they typed. Everything here is about not letting that become a hole: only the
-- owner may submit, only while the order is open, only fields the gateway asked
-- for, and only files that really are theirs. The normalisation at the end is
-- what lets an admin find the TrxID later without caring which keyboard the
-- customer used.

select plan(38);

-- ---------------------------------------------------------------------------
-- A draft is not an order
--
-- Guessing the amount leaves a draft behind so the probe counter has somewhere
-- to live. There is nothing to attach a screenshot to, and saying so is clearer
-- than letting the customer upload into a void.
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 10) ->> 'code';

select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id)$$,
  '22023',
  'this order is not accepting evidence',
  'a probe draft does not accept evidence'
);

-- ---------------------------------------------------------------------------
-- Whose order is it, and when
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 750) ->> 'ok';

select test_data.as_anon();

select throws_ok(
  $$select api.submit_evidence((test_data.subject_order()).id, '{"trxid": "ABC123XYZ9"}'::jsonb)$$,
  '42501',
  'authentication required',
  'an anonymous visitor cannot submit evidence'
);

-- Not "you may not do that" but "there is no such order", so one customer cannot
-- learn that another's order exists by trying to submit to it.
select throws_ok(
  $$select test_data.submit(test_data.new_user(), (test_data.subject_order()).id)$$,
  'P0002',
  'order not found',
  'another customer cannot submit to an order they do not own'
);

update public.orders set expires_at = now() - interval '1 minute';

select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id)$$,
  '22023',
  'this order has expired',
  'an expired order does not accept evidence'
);

update public.orders set expires_at = now() + interval '30 minutes';

select is(
  test_data.submit(test_data.subject_id(), (test_data.subject_order()).id) ->> 'ok',
  'true',
  'the same submission is accepted once the order is open again'
);

select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id)$$,
  '22023',
  'this order is not accepting evidence',
  'a second submission while it is already with staff is refused'
);

-- ---------------------------------------------------------------------------
-- The fields the gateway asked for
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 750) ->> 'ok';

-- The presence check runs before anything is written, so a half-filled form
-- cannot leave a partial evidence trail behind.
select throws_ok(
  $$select test_data.submit_fields(test_data.subject_id(), (test_data.subject_order()).id, '{"amount": "750", "trxid": "ABC123XYZ9"}'::jsonb)$$,
  '22023',
  'every required field must be filled in',
  'a missing required field is refused'
);

select is(
  test_data.evidence_count((test_data.subject_order()).id),
  0,
  'and nothing was recorded while it was refused'
);

-- Present but saying nothing, so it counts as missing.
select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"trxid": "   "}'::jsonb)$$,
  '22023',
  'trxid is required',
  'a blank required field is refused'
);

-- Anything the gateway did not ask for is refused rather than stored, or a
-- customer could add fields that later mean something to an admin.
select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"nickname": "a friend of the owner"}'::jsonb)$$,
  '22023',
  'unknown evidence field(s): nickname',
  'a field the gateway never asked for is refused'
);

select throws_ok(
  $$select test_data.submit_fields(test_data.subject_id(), (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
      jsonb_build_object('statement', 'x.png'))$$,
  '22023',
  'unknown evidence file field(s)',
  'a file for a field the gateway never asked for is refused'
);

-- ---------------------------------------------------------------------------
-- What counts as a valid value
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"trxid": "!!!"}'::jsonb)$$,
  '22023',
  'trxid must be 4 to 24 letters or digits',
  'a TrxID that is not letters and digits is refused'
);

select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"trxid": "ABC123XYZ9ABC123XYZ9ABC123"}'::jsonb)$$,
  '22023',
  'trxid accepts at most 24 characters',
  'a TrxID longer than the field allows is refused'
);

-- The number field is typed, not free text. A Bangla keyboard must not turn a
-- screenshot review into a puzzle about digits.
select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"amount": "৭৫০"}'::jsonb)$$,
  '22023',
  'amount must be a number',
  'a number written in Bangla digits is refused'
);

select throws_ok(
  $$select test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"sender_number": "0170000"}'::jsonb)$$,
  '22023',
  'sender_number is not a valid Bangladeshi mobile number',
  'a sender number that is not a Bangladeshi mobile is refused'
);

-- ---------------------------------------------------------------------------
-- Files
--
-- The path check is not decoration. A customer who could name any path could
-- attach somebody else's screenshot, and the reviewer would see it as part of
-- their own payment.
-- ---------------------------------------------------------------------------

-- Sent as both a file and a value, the field is ambiguous. Refusing beats
-- picking one and storing evidence nobody can explain later.
select throws_ok(
  $$select test_data.submit_fields(
      test_data.subject_id(),
      (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9", "screenshot": "and a typed note"}'::jsonb,
      jsonb_build_object('screenshot', test_data.proof(test_data.subject_id(), (test_data.subject_order()).id)))$$,
  '22023',
  'screenshot takes a file, not text',
  'a file field sent as both a file and a value is refused'
);

select throws_ok(
  $$select test_data.submit_fields(
      test_data.subject_id(),
      (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
      jsonb_build_object('trxid', test_data.proof(test_data.subject_id(), (test_data.subject_order()).id, 'trxid')))$$,
  '22023',
  'trxid takes text, not a file',
  'a file where text belongs is refused'
);

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 750) ->> 'ok';

select is(
  test_data.submit_fields(
    test_data.subject_id(),
    (test_data.subject_order()).id,
    '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
    jsonb_build_object('screenshot', test_data.proof(test_data.subject_id(), (test_data.subject_order()).id))
  ) ->> 'ok',
  'true',
  'a screenshot in the customer own folder is accepted'
);

select is(
  (test_data.evidence((test_data.subject_order()).id, 'screenshot')).file_path is not null,
  true,
  'and the path is recorded against the order'
);

-- Every one of these is refused before the order is touched, so they can all be
-- asked of the same order still waiting for its screenshot.
select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 750) ->> 'ok';

-- The shape is right and the object is real, but it is filed under a different
-- customer folder.
select throws_ok(
  $$select test_data.submit_fields(test_data.subject_id(), (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
      jsonb_build_object('screenshot', test_data.proof(test_data.new_user(), (test_data.subject_order()).id)))$$,
  '22023',
  'invalid file path for screenshot',
  'a file in another customer folder is refused'
);

-- Under this customer, but under a different order.
select throws_ok(
  $$select test_data.submit_fields(test_data.subject_id(), (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
      jsonb_build_object('screenshot', test_data.proof(test_data.subject_id(), gen_random_uuid())))$$,
  '22023',
  'invalid file path for screenshot',
  'a file filed under a different order is refused'
);

-- Correct folder, no such upload. Naming a path is not uploading to it.
select throws_ok(
  $$select test_data.submit_fields(test_data.subject_id(), (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
      jsonb_build_object('screenshot', test_data.subject_id()::text || '/' || (test_data.subject_order()).id::text || '/screenshot/' || gen_random_uuid()::text || '.png'))$$,
  '22023',
  'uploaded file for screenshot was not found',
  'a path that was never uploaded is refused'
);

-- The object exists in the bucket but belongs to somebody else, so a customer who
-- guessed the path still gets nothing.
select throws_ok(
  $$select test_data.submit_fields(test_data.subject_id(), (test_data.subject_order()).id,
      '{"sender_number": "01712345678", "amount": "750", "trxid": "ABC123XYZ9"}'::jsonb,
      jsonb_build_object('screenshot', test_data.proof(test_data.subject_id(), (test_data.subject_order()).id, 'screenshot', 'png', test_data.new_user())))$$,
  '22023',
  'uploaded file for screenshot was not found',
  'a file owned by another customer is refused'
);

-- ---------------------------------------------------------------------------
-- What is kept
-- ---------------------------------------------------------------------------

select test_data.reset();
select test_data.link('guide', 500, false);
select test_data.gateway('bkash');
select test_data.new_subject();
select test_data.orders('guide', 'bKash', 750) ->> 'ok';

select is(
  test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"trxid": " abc123xyz9 "}'::jsonb) ->> 'ok',
  'true',
  'a TrxID with stray spaces and mixed case is accepted'
);

select is(
  (test_data.evidence((test_data.subject_order()).id, 'trxid')).value_text_norm,
  'ABC123XYZ9',
  'and is stored in the form an admin will search for'
);

select is(
  (test_data.evidence((test_data.subject_order()).id, 'trxid')).value_text_raw,
  ' abc123xyz9 ',
  'while the original is kept alongside it, exactly as typed'
);

select is(
  test_data.evidence_count((test_data.subject_order()).id),
  3,
  'one row per field that was sent'
);

select is(
  (test_data.subject_order()).status::text,
  'under_review',
  'and the order moves to review'
);

-- The sender number is the recovery identity, so a valid submission is also
-- what links a phone to the account.
select is(
  (test_data.subject_order()).phone_e164,
  '+8801712345678',
  'the sender number is stored on the order in international form'
);

select is(
  (select count(*)::int from public.customer_contacts where user_id = test_data.subject_id()),
  1,
  'and is recorded as a contact for later recovery'
);

-- ---------------------------------------------------------------------------
-- Sending it again
--
-- A rejected order goes back to review on a new attempt. The old attempt stays,
-- because the reviewer needs to see what the customer sent the first time.
-- ---------------------------------------------------------------------------

select test_data.reviewed_by_staff((test_data.subject_order()).id, 'reject', 'the screenshot is cropped') ->> 'ok';

select is(
  (test_data.subject_order()).status::text,
  'rejected',
  'staff can reject a submitted order'
);

select is(
  test_data.submit(test_data.subject_id(), (test_data.subject_order()).id, '{"trxid": "ZZZ999YYY8"}'::jsonb) ->> 'attempt',
  '2',
  'resubmitting is a second attempt, not an edit of the first'
);

select is(
  (test_data.subject_order()).status::text,
  'under_review',
  'and the order is back in the queue'
);

select is(
  (test_data.evidence((test_data.subject_order()).id, 'trxid', 1)).value_text_norm,
  'ABC123XYZ9',
  'the first attempt is still on file'
);

select is(
  (test_data.evidence((test_data.subject_order()).id, 'trxid', 2)).value_text_norm,
  'ZZZ999YYY8',
  'alongside the correction'
);

select is(
  test_data.evidence_count((test_data.subject_order()).id, 1),
  3,
  'the first attempt keeps its own rows'
);

select is(
  (test_data.subject_order()).reject_code,
  null,
  'and the rejection reason is cleared so the customer is not shown a stale one'
);

-- Evidence is a trail, not a draft. Rewriting what a reviewer already saw would
-- make the audit log a lie, and this runs as the role that owns the table: the
-- append-only rule is not something a privileged caller can opt out of.
select throws_ok(
  $$update public.order_evidence set value_text_raw = 'ABC0000000' where order_id = (test_data.subject_order()).id$$,
  '42501',
  'order_evidence is append-only: UPDATE is not permitted',
  'an evidence row cannot be rewritten afterwards'
);

select test_data.as_anon();

select * from finish();
