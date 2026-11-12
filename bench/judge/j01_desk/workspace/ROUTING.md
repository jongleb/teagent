# Where a ticket goes

Send each ticket to exactly one queue.

- `security`: someone else may have access to the account or to payment data, or the customer
  wrote a password or a card number into the ticket. This queue wins over every other.
- `outage`: a service is down or failing for the customer right now.
- `billing`: charges, refunds, invoices and plan prices.
- `account`: signing in, the email address, the profile, closing the account.
- `feedback`: wishes, praise, and complaints about how something works when nothing is broken.

A follow-up ("about my ticket T…") on the same problem goes where the ticket it follows went,
unless it is a security case itself. A new problem in a follow-up is routed on its own.
