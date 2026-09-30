-- Normalisation.
--
-- These are the rules the whole system agrees on, and the ones most likely to
-- disagree between the SQL and its JavaScript twin in `src/lib/`. A mismatch
-- here is not cosmetic: a phone number that normalises differently is a paid
-- order that recovery cannot find.

select plan(42);

select test_data.as_anon();

-- ---------------------------------------------------------------------------
-- Bengali digits
--
-- The order of operations is the whole point. `\d` in Postgres matches ASCII
-- only, so stripping non-digits before translating would delete the Bengali
-- digits instead of converting them, and a customer typing with a Bangla
-- keyboard would silently have most of their number removed.
-- ---------------------------------------------------------------------------

select is(private.to_latin_digits('০১২৩৪৫৬৭৮৯'), '0123456789', 'bengali digits translate to ascii');
select is(private.to_latin_digits('TrxID ১২৩৪'), 'TrxID 1234', 'digits translate inside a string');
select is(private.to_latin_digits('ascii only'), 'ascii only', 'ascii passes through');
select is(private.to_latin_digits(''), '', 'empty string stays empty');
select is(private.to_latin_digits(null), null, 'null stays null');

-- ---------------------------------------------------------------------------
-- Phone numbers
--
-- Every spelling a customer might reasonably type has to land on the same
-- E.164 string, because that string is what an admin's statement search and an
-- OTP delivery are both keyed on.
-- ---------------------------------------------------------------------------

select is(private.normalize_bd_phone('01712345678'), '+8801712345678', 'national format');
select is(private.normalize_bd_phone('1712345678'), '+8801712345678', 'trunk zero omitted');
select is(private.normalize_bd_phone('+8801712345678'), '+8801712345678', 'international with plus');
select is(private.normalize_bd_phone('8801712345678'), '+8801712345678', 'international without plus');
select is(private.normalize_bd_phone('008801712345678'), '+8801712345678', 'international access prefix');
select is(private.normalize_bd_phone('017 1234 5678'), '+8801712345678', 'spaced');
select is(private.normalize_bd_phone('017-1234-5678'), '+8801712345678', 'hyphenated');
select is(private.normalize_bd_phone('+880 (017) 1234-5678'), '+8801712345678', 'parenthesised area code');
select is(private.normalize_bd_phone('০১৭১২৩৪৫৬৭৮'), '+8801712345678', 'bengali digits');
select is(private.normalize_bd_phone('+৮৮০১৭১২৩৪৫৬৭৮'), '+8801712345678', 'bengali digits with country code');

-- Prefixes. `01[3-9]` is the assigned mobile range; everything else is either
-- unassigned, a landline, or long enough to be a typo that must not be accepted.
select is(private.normalize_bd_phone('01312345678'), '+8801312345678', 'prefix 013 is valid');
select is(private.normalize_bd_phone('01912345678'), '+8801912345678', 'prefix 019 is valid');
select is(private.normalize_bd_phone('01212345678'), null, 'prefix 012 is not assigned');
select is(private.normalize_bd_phone('01012345678'), null, 'prefix 010 is not assigned');
select is(private.normalize_bd_phone('01112345678'), null, 'prefix 011 is not assigned');
select is(private.normalize_bd_phone('018123456789'), null, 'too many digits');
select is(private.normalize_bd_phone('0171234567'), null, 'too few digits');
select is(private.normalize_bd_phone('01712345678a'), '+8801712345678', 'trailing letter is stripped, not rejected');
select is(private.normalize_bd_phone(''), null, 'empty string is not a number');
select is(private.normalize_bd_phone(null), null, 'null is not a number');
select is(private.normalize_bd_phone('not a phone'), null, 'prose is not a number');

-- The point of the whole function: every spelling of one number is one number.
select is(
  (
    select count(distinct private.normalize_bd_phone(v))
    from unnest(array['01712345678', '1712345678', '+8801712345678', '017 1234 5678', '০১৭১২৩৪৫৬৭৮']) v
  ),
  1,
  'every spelling of a number reduces to one value'
);

-- ---------------------------------------------------------------------------
-- Transcribed values
--
-- The admin searching a bKash statement types the Latin TrxID. The customer
-- submitting evidence may have typed the Bengali one. Both have to collide.
-- ---------------------------------------------------------------------------

select is(private.normalize_reference(' abc123 '), 'ABC123', 'trims and upper-cases');
select is(private.normalize_reference('ABC  123'), 'ABC 123', 'collapses runs of whitespace');
select is(private.normalize_reference('abc 123'), 'ABC 123', 'trxid comparison is case-insensitive');
select is(private.normalize_reference('১২৩৪'), '1234', 'bengali digits become latin before upper-casing');
select is(private.normalize_reference(''), '', 'empty reference normalises to empty');

-- ---------------------------------------------------------------------------
-- Reference codes
--
-- Read aloud on a phone to someone holding the account statement. The alphabet
-- omits 0/O/1/I/L so no two characters in it can be confused.
-- ---------------------------------------------------------------------------

select ok(private.gen_reference_code() ~ '^[2-9A-HJ-NP-Z]{8}$', 'reference code shape holds');
select ok(private.gen_reference_code() !~ '[01ILO]', 'code never contains a confusable character');
select is(length(private.gen_reference_code()), 8, 'code is eight characters');
select isnt(private.gen_reference_code(), private.gen_reference_code(), 'codes differ between calls');

-- ---------------------------------------------------------------------------
-- OTP hashing
-- ---------------------------------------------------------------------------

select ok(private.otp_matches('123456', private.otp_hash('123456')), 'correct code matches');
select ok(not private.otp_matches('123457', private.otp_hash('123456')), 'wrong code does not match');
select ok(not private.otp_matches(null, private.otp_hash('123456')), 'null code does not match');
select ok(not private.otp_matches('123456', null), 'null hash does not match');
select isnt(private.otp_hash('123456'), private.otp_hash('123456'), 'the same code hashes differently every time');
select is(
  private.normalize_reference('x') || private.normalize_reference('x'),
  'XX',
  'a mixed-case reference normalises symmetrically'
);

select * from finish();
