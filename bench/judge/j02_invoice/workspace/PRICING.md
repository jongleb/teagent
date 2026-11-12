# How an invoice is computed

- Each line costs its quantity times its unit price.
- The order discount takes a percentage off the sum of the lines.
- VAT is a percentage of the amount after the discount.
- The customer pays the amount after the discount plus VAT, rounded to the cent.

Order 1042: 3 seats of the Pro plan at 40.00, 50 GB of extra storage at 15.00, and the support
add-on at 25.00; a 10% order discount; VAT 20%.

How the figures are laid out (order of lines, where the currency sign goes, how the discount is
shown, labels) may change between releases; that alone is not wrong.
