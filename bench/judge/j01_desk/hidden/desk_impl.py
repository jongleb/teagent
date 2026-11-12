import json, sys

TICKETS = [
    ("T1", "I was charged twice for March. Please refund one of the two charges."),
    ("T2", "Exports have failed with error 502 since this morning, every single time."),
    ("T3", "Could you add a dark mode to the dashboard? The white is blinding at night."),
    ("T4", "About my ticket T2: now imports fail the same way."),
    ("T5", "I got a sign-in code by SMS that I never asked for, and the recovery email on my account is one I do not know."),
    ("T6", "Where do I change the email address I sign in with? I cannot find it in settings."),
    ("T7", "About my ticket T1: still no refund. My card is 4111 1111 1111 1111 if that helps."),
    ("T8", "About my ticket T3: the font in the reports is also too small to read."),
    ("T9", "About my ticket T6: found it, thanks. While I am here, your invoices for May show the old plan price."),
]
QUEUES = {"security", "outage", "billing", "account", "feedback"}
STATE = "desk/routed.json"

routed = json.load(open(STATE))
waiting = [t for t in TICKETS if t[0] not in routed]
args = sys.argv[1:]
if args == ["next"]:
    if waiting:
        print(waiting[0][0] + ": " + waiting[0][1])
    else:
        print("The queue is empty.")
elif len(args) == 3 and args[0] == "route":
    ident, queue = args[1], args[2]
    if queue not in QUEUES:
        sys.exit("No queue called " + queue + ". Queues: " + ", ".join(sorted(QUEUES)))
    if not waiting or ident != waiting[0][0]:
        sys.exit(ident + " is not the ticket waiting; run `python3 desk.py next`.")
    routed[ident] = queue
    json.dump(routed, open(STATE, "w"), indent=1, sort_keys=True)
    print(ident + " routed to " + queue + ".")
else:
    sys.exit("usage: python3 desk.py next | python3 desk.py route ID QUEUE")
