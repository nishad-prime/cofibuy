# Payment flow

The one part of this app where a bug grants a customer something for free. Everything here exists
to make a single question unanswerable from the browser: _did bKash actually take the money?_

Read this before touching `bkash-execute`, `PaymentReturnView.vue`, or either settlement RPC.

## The return URL is fixed, and that is why

bKash redirects the customer back to **`/payment/return`**, configured once in the merchant
dashboard. It cannot carry an order id — there is nowhere to put one — so the browser comes back
holding a `paymentID` and nothing else:

```
/payment/return?paymentID=XXXXXXXX&status=success|failure|...
```

`PaymentReturnView.vue` finds the order from that payment id alone.

## `status` is never read

That is the whole design, not an oversight.

`status` arrives in the query string of a URL the customer's own browser is holding. Anyone can
edit it. `status=success` is a claim by the customer, not a fact from bKash, and treating it as
proof would let anyone who knows a `paymentID` approve their own order by reloading a URL.

So nothing in this app reads it. The order is settled only when **bKash tells the server** the
payment completed, which means the server calls Execute Payment with the merchant's own
credentials and reads the answer.

If you find yourself wanting `status`, the reason to want it is always "to avoid a round trip" or
"to avoid an error message the customer will not like". Both are worth an error message.

## The order of operations

`supabase/functions/bkash-execute/index.ts`, in this order and no other:

1. **`api.bkash_payment_claim(p_order_id, p_payment_id)`** establishes in SQL that this payment id
   belongs to this order. Until it returns, nothing is executed and no secret is read.
2. **If it reports `already_settled`, return immediately.** Execute Payment is allowed _exactly
   once_ per payment id. A second call is not a retry — it is a permanent failure of that payment,
   and retrying it destroys a payment that may already have worked.
3. **Execute Payment** against bKash, with credentials from the service-role client.
4. **`api.bkash_settle_order(...)`** approves the order, and refuses if anything disagrees.

Only `statusCode === '0000'` counts as success. bKash answers HTTP 200 with a body describing the
failure, so treating a 2xx as success would approve orders bKash explicitly refused.

## Sandbox payments cannot settle an order

`api.bkash_settle_order` reads the environment off **the gateway row that took the order**, not
off a deployment setting, because a shop can run a sandbox method against a live merchant
credential and the two can disagree. When that gateway's environment is `sandbox` the RPC raises:

```
sandbox gateways cannot settle an order: bkash reported success for a payment it did not charge,
so approving it would grant access for no money. Set the gateway to live to settle.
```

A sandbox payment that bKash calls successful did not move any money. Approving it would grant a
download for free, which is the exact outcome the whole flow is built to prevent — so the test
payment fails, loudly, and the customer is told plainly that this was a test.

The two environments:

| Environment | Base URL                                                          |
| ----------- | ----------------------------------------------------------------- |
| sandbox     | `https://tokenized.sandbox.bka.sh/v1.2.0-beta/tokenized/checkout` |
| live        | `https://tokenized.pay.bka.sh/v1.2.0-beta/tokenized/checkout`     |

Both are in `supabase/functions/_shared/bkash.ts`. Sandbox **credentials** are not in this
repository: they come from the shop's own bKash sandbox account and are saved through the gateway
form like any other credential. Nothing here should ever name them.

## Who may do what

| Surface                                  | Role                   | Why                                                                                                                                                                                       |
| ---------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `api.bkash_payment_lookup(p_payment_id)` | the signed-in customer | Scoped to `o.user_id = auth.uid()`, so one customer's `paymentID` reveals nothing about another's order. Returns `order_id`, `slug`, `status` and `already_settled` — never a credential. |
| `api.bkash_payment_claim(...)`           | service role           | Establishes the payment↔order binding. No browser may call it.                                                                                                                            |
| `api.bkash_settle_order(...)`            | service role           | The only thing that approves an order.                                                                                                                                                    |
| `api.gateway_credential_bundle(...)`     | service role           | Which bundle belongs to a gateway. Returns a bundle id, never plaintext.                                                                                                                  |
| `api.secret_bundle_open(p_bundle_id)`    | service role           | The single path from a bundle id to plaintext.                                                                                                                                            |

The browser never holds a bKash credential. `bkash-execute` opens the bundle on the service-role
client, calls bKash, and drops it — the one function in the codebase whose entire job is to make
an authenticated HTTP call with a secret.

`api.bkash_payment_lookup` is granted to `authenticated` and revoked from `anon` and `public`; the
three service-role RPCs are revoked from everyone and granted to `service_role` only.

## What the RPCs refuse

`bkash_settle_order` raises rather than deciding, on each of these:

- no order, or a completed payment with no `trx_id` (`22023`)
- the payment id belongs to a different order (`22023`)
- the confirmed amount is not the order's amount (`22023`)
- the gateway's environment is `sandbox` (see above)

Partial unique indexes on `payment_sessions` and `orders` are the backstop behind these checks,
so a race cannot produce two completed sessions for one payment id even if every guard above is
bypassed. `supabase/tests/16_bkash_settlement_safety.sql` is where that is asserted.

## Tests that must stay green

- `supabase/tests/16_bkash_settlement_safety.sql` — the settlement guards, the sandbox refusal,
  and the race backstops.
- `supabase/tests/11_bkash.sql` — token lifecycle and the credential bundle.
- `supabase/tests/15_weighted_routing.sql` — which gateway takes a given order.

Run `npm run test:db`. It is the only gate that can see any of this.
