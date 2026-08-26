#!/usr/bin/env python3
"""
One-off generator for migration 0013 — the November 2023 run sheets.

NOT part of the site. The site has no build step and never will; this is a
desk tool that turned two spreadsheets into reviewable SQL, kept so the next
person can see exactly how each column was read.

Source: data/nov23-all-records.csv       (the master customer list + days)
        data/nov23-van-kemu-thursday.csv (Kemu's Thursday run, already loaded)

Three things the sheets do NOT record, decided here and flagged in the SQL:
  * which driver does which customer -- inferred from suburb (see ROUTE)
  * the order of stops within a day   -- alphabetical, except Kemu's Thursday
  * a run start time per customer     -- left null

    python3 data/build_nov23_import.py    # writes migrations 0013 and 0014
"""

BIZ    = 'b7d18d8b-aa7c-4dd8-a37a-4ced75748239'
VAN    = '353c2c0e-4dd6-4fbd-bbc4-7c797bf625c6'   # Kemu   10:30  west
DARREN = 'c4d95005-1007-4e0f-8c12-95cf3d727e83'   # Darren 08:00  city, inner east and south
WERRI  = '479a4d47-8acd-4f24-89fa-305f7e364611'   # Keith  09:00  Werribee and Wyndham
TRUCK  = '6d18cfa0-6c82-4687-856b-4d186f6ed99c'   # Binod  07:00  Geelong

MON, TUE, WED, THU, FRI, SAT = 1, 2, 3, 4, 5, 6
ALL6 = [MON, TUE, WED, THU, FRI, SAT]

# row = source line in nov23-all-records.csv, and the external_ref suffix.
# ref  = an external_ref that ALREADY exists in the database (from Kemu's
#        Thursday sheet); the customer is updated, never duplicated.
# days = weekdays this customer appears on. Empty means the sheet gave no day,
#        so they are loaded as a customer with no template stop.
C = []
def c(row, name, addr=None, sub=None, pc=None, days=(), freq='weekly', nth=None,
      order=None, access=None, contact=None, phone=None, early=None,
      route=None, ref=None, pr=None, prpct=None):
    C.append(dict(row=row, name=name, addr=addr, sub=sub, pc=pc, days=list(days),
                  freq=freq, nth=nth, order=order, access=access, contact=contact,
                  phone=phone, early=early, route=route, ref=ref, pr=pr, prpct=prpct))

# ── the city, inner east and south — Darren ──────────────────────────────────
c(1,  "A'Beckett St - Tunnel", "A'Beckett St", "Melbourne", days=ALL6, route=DARREN,
     order="Bags of shirts, pants and overalls", access="Deliver to the change rooms")
c(3,  "ARA", "Level 4, 289 Wellington Parade South", "East Melbourne",
     access="No day on the sheet - not on a run yet")
c(5,  "ATL Melbourne Connect", "700 Swanston St", "Carlton", days=[MON], freq='on_call',
     route=DARREN, contact="Tim Kochitzke", phone="0400 131 0382")
c(11, "Curtis Stone Events", "Australian Unity Building", "Melbourne", days=[MON, WED],
     route=DARREN, access="Enter via Little La Trobe St", contact="Nick", phone="0419 683 671")
c(13, "Federal / Family Court", "Cnr Alsop Lane and Little Lonsdale St", "Melbourne",
     days=[TUE, FRI], route=DARREN,
     order="Drop off and pick up towels, tea towels, table cloths, robes, shirts, "
           "pants, jackets, ties, scarves",
     access="Entrance via Little Lonsdale. Can drive directly into the guard house "
            "for easy collection")
c(14, "Federation Square", "Swanston St and Flinders St", "Melbourne",
     days=[MON, WED, FRI, SAT], route=DARREN,
     order="Bags of shirts, pants and overalls - take wheely bin",
     access="Deliver to the clean side change rooms")
c(15, "Food and Desire", "114 Munro St", "South Melbourne", pc="3205", days=[TUE, THU],
     route=DARREN, order="Hanging garments / bag of aprons")
c(18, "Grand Chancellor", "131 Lonsdale St", "Melbourne", pc="3000", days=ALL6,
     route=DARREN, order="Hanging orders", access="Drop off and pick up from the cupboard")
c(19, "Gratia Beauty", "Shop 100/179 Little Bourke St", "Melbourne", days=[TUE, FRI],
     route=DARREN, order="Bag of towels", access="Pick up and drop off")
c(21, "Grill Americano", "101 Collins St", "Melbourne", days=ALL6, route=DARREN,
     order="Napkins. Hanging staff uniforms. Drop off and pick up",
     access="Entry via Flinders Lane (101 Collins St loading dock). Staff room code C30XY")
c(22, "Hagen South Melbourne", "South Melbourne Market, York St", "South Melbourne",
     days=[FRI], route=DARREN, order="Hanging / bag of aprons", access="Pick up also")
c(23, "Hagen's Bentleigh", "35 Patterson Rd", "Bentleigh", pc="3204", days=[TUE],
     route=DARREN, order="Aprons and hanging garments", access="Pick up also")
c(24, "Hagen's Marketplace", "Victoria Market", "Melbourne", days=[THU], route=DARREN)
c(25, "Hagen's Prahran", "Prahran Market", "Prahran", days=[THU], route=DARREN,
     order="Hanging coats / bag of aprons")
c(26, "Hilton Hotel", "18 Little Queen Lane", "Melbourne", days=ALL6, route=DARREN,
     order="Hang staff uniforms", access="Collapsible trolley and small laundry bags")
c(37, "Melbourne Airport Smartcarte", None, None, days=[TUE, FRI], route=DARREN,
     order="Drop off and pick up",
     access="No address on the sheet. Run not confirmed - the airport is not on "
            "anyone's round in the sheet")
c(38, "Melbourne Museum", "11 Nicholson St", "Carlton", days=[MON, WED, FRI], route=DARREN,
     order="Hanging t-shirts and bagged blue aprons", access="Enter via the loading bay",
     contact="Soni", phone="0430 882 488")
c(39, "Miss Pearl", "140 Southbank Blvd", "Southbank", days=[TUE, THU], route=DARREN,
     order="Hanging garments",
     access="Back door D onto Level 1. Sliding door at the top of the stairs")
c(43, "North Melbourne Police Station", "36 Wreckyn St", "North Melbourne",
     days=[TUE, THU], route=DARREN, order="Pick up and drop off cell blankets",
     access="On call on the sheet - ring before going")
c(44, "Novotel on Collins", "Dame Edna Place", "Melbourne", days=ALL6, route=DARREN,
     order="Pick up and drop off", phone="9667 5800",
     access="Call 9667 5800 - check if they need a pickup")
c(45, "Oakwood", None, None, days=[MON, WED, FRI], route=DARREN,
     order="Hanging staff uniforms. Drop off and pick up. Level 2",
     access="No address on the sheet. Guest pick ups on call, from reception")
c(46, "One Stop", "99 Bell St", "Preston", days=[MON], freq='on_call', route=DARREN,
     order="Pick up and drop off", access="On call only")
c(47, "Oxford Scholar", "427 Swanston St", "Melbourne", days=[THU], route=DARREN,
     order="150 tea towels and 150 white polish cloths per week")
c(48, "PCI Moorabbin Airport", "2/7 Chifley Dr", "Moorabbin Airport", pc="3194",
     days=[TUE], freq='fortnightly', route=DARREN, order="Hanging garments",
     access="Every two weeks. Call beforehand", contact="Toula", phone="0418 680 896")
c(49, "PCI Port Melbourne", "Unit 10/9-52 Wirraway Dr", "Port Melbourne", days=[TUE],
     freq='fortnightly', route=DARREN, order="Hanging garments",
     access="Pick up and drop off - fortnightly")
c(51, "Pullman Hotel", "Little Bourke St and Albion Lane", "Melbourne", days=ALL6,
     route=DARREN, order="Pick up and drop off", phone="0429 142 373",
     access="Call 0429 142 373 - check if they need a pickup")
c(52, "Richmond Police Station", "217 Church St", "Richmond", days=[TUE, THU],
     route=DARREN, order="Pick up and drop off cell blankets")
c(58, "Society", "80 Collins St", "Melbourne", days=ALL6, route=DARREN,
     order="Staff uniforms, aprons and napkins",
     access="Entry from Little Collins St. Napkins to be delivered to the kitchen "
            "with the grey polish cloths")
c(60, "Starpharma", "4/6 Southampton Cres", "Abbotsford", days=[THU], freq='monthly_nth',
     nth=1, route=DARREN, order="Lab coats and towels", access="First Thursday of the month")
c(64, "The Albion Rooftop", "172 York St", "South Melbourne", pc="3205", days=[TUE, THU],
     route=DARREN, order="Tuesday - pick up dirty aprons from the staff room",
     access="Thursday - drop off to the staff room")
c(66, "The Precinct Hotel", "60 Swan St", "Cremorne", pc="3121", days=[TUE, THU],
     route=DARREN, order="Tuesday - pick up dirty aprons from the staff room",
     access="Thursday - drop off only")
c(69, "Victor Churchill", "953 High St", "Armadale", pc="3143", days=[TUE, THU, SAT],
     route=DARREN, access="Gate code 9783")
c(70, "Victoria Hotel", "215 Little Collins St", "Melbourne", days=ALL6, route=DARREN,
     order="Hanging staff uniforms. Drop off and pick up")
c(71, "Voco", "371 Little Lonsdale St", "Melbourne", days=ALL6, route=DARREN,
     order="Hanging staff uniforms. Drop off and pick up", contact="Mert",
     phone="0423 745 623", access="Second number 0438 209 485")
c(77, "Woodfrog Bakery", "108A Barkly St", "St Kilda", days=[TUE, THU], route=DARREN,
     order="Tuesday - 3 small mats, 1 rubber mat, tin liners / bag of aprons",
     access="Thursday - bag of aprons and tin liners")

# ── the west — Kemu's van ────────────────────────────────────────────────────
c(2,  "Altona Police Station", "1 Galvin St", "Altona", days=[WED], route=VAN,
     order="Pick up and deliver cell blankets", phone="9392 3111")
c(4,  "Atlantic Group", "43 Agosta Drive", "Laverton North", days=[MON], freq='on_call',
     route=VAN, contact="Nikhil Nischal", phone="0430 308 454", access="On call only")
c(6,  "Aware Health", "1/22 Mason St", "Newport", days=[MON, WED, FRI], route=VAN,
     order="Pick up and drop off bags of towels", pr='2023-12-07', prpct=10)
c(7,  "Black Sheep", "25B Vernon St", "South Kingsville", days=[FRI], route=VAN,
     order="50 tea towels and 40 blue microfibre", access="On invoice")
c(8,  "Butchers Yarraville", "44 Simpson St", "Yarraville", days=[MON, THU], route=VAN,
     ref='C-002', order="Bag of aprons, hanging chefs jackets, 25 tea towels",
     access="Dirty stuff down near the washers")
c(9,  "Concept Engineering", "1/32 Westside Drive", "Laverton North", days=[MON],
     freq='on_call', route=VAN, order="Pick up and drop off overalls", access="On call only")
c(10, "Cupcake Queen", "Unit 2/49 McArthurs Rd", "Altona North", days=[THU],
     freq='fortnightly', route=VAN, ref='C-007', order="100 tea towels",
     access="The master list still shows 17 Hall St Yarraville and 50 tea towels - "
            "Kemu's sheet is newer. Check which is right")
c(12, "Daffy Contracting", "89A Strzelecki Ave", "Sunshine West", days=[MON], route=VAN,
     order="Bags of overalls")
c(20, "Greek Church", "Millers Rd", "Altona North", days=[MON, THU], route=VAN, ref='C-009',
     order="Pick up and drop off linen", access="Get the key off the hook",
     contact="Ayman", phone="0410 260 716")
c(30, "John Holland West", "20-40 Booker St", "Spotswood", days=[TUE, THU], route=VAN,
     order="Pick up and drop off uniforms in bags. West is yellow",
     access="Gate code 2580#", contact="Claire", phone="0412 405 706")
c(31, "John Holland East", "97 Kooringal Way", "Port Melbourne", days=[TUE, THU],
     route=VAN, ref='C-003',
     order="Pick up and drop off uniforms in blue bags. Leave extra bags",
     access="Gate code 2580#", contact="Claire (Peggy)", phone="0412 405 706")
c(34, "Little Ginger", "4/10 Akuna Dr", "Williamstown North", days=[MON], freq='on_call',
     route=VAN, order="Table cloths and hand towels",
     access="Customer drops off", contact="Nikki", phone="0416 096 414")
c(40, "Morning Star Hotel", "3 Electra St", "Williamstown", days=[THU], route=VAN,
     order="50 tea towels, 40 white polish cloths. Table cloths 135x135 - "
           "rolling stock of 50")
c(41, "My Mama Said", "67 Austin St", "Seddon", days=[TUE, THU, SAT], route=VAN,
     order="Pick up and drop off")
c(42, "Nhu Lan Bakery", "116 Hopkins St", "Footscray", days=[MON], route=VAN,
     order="Bag of aprons", access="Pick up and drop off")
c(50, "Pier St", "125 Pier St", "Altona", days=[WED, FRI], route=VAN,
     order="Folded blue sheets")
c(53, "Scienceworks", "2 Booker St", "Spotswood", days=[MON, THU], route=VAN,
     order="Pick up and drop off t-shirts and aprons", access="Via reception",
     contact="Nicole 0459 830 991, Soni 0430 882 488")
c(54, "Seaview Events", "71 Morris St", "Williamstown", days=[MON, THU], route=VAN,
     ref='C-006', order="Pick up and drop off table linen", early='09:30',
     access="Enter by the Battery Rd gate. Do NOT pick up or deliver before 9.30am",
     contact="Flamur 0449 765 518, Krista 0423 508 770 (events manager)")
c(62, "Tasty Chips", "410 Somerville Rd", "Tottenham", days=[MON, TUE, WED, THU, FRI],
     route=VAN, order="Take 2 wheelie bins. White uniforms on hangers",
     access="Check CHS")
c(68, "Velvet Bean", "5/112 Pier St", "Altona", days=[FRI], route=VAN,
     order="50 tea towels per week")
c(72, "VRC", None, "Flemington", days=[MON, THU], route=VAN, order="After race meets",
     access="No address on the sheet. Flemington assumed - confirm")
c(74, "Western Imaging for Women", "Level 2, Suite 16/1 Thomas Holmes St", "Maribyrnong",
     days=[MON, THU], route=VAN, ref='C-001', order="Pick up and drop off bags of towels",
     access="Level 2")
c(75, "Williamstown Butcher", "3 Becroft Mews", "Williamstown", days=[MON, THU],
     route=VAN, ref='C-005', order="Bag of aprons, 25 tea towels",
     access="Must wear a hat. Pick up also")
c(76, "Williamstown Police", "100 Nelson Parade", "Williamstown", days=[MON],
     freq='on_call', route=VAN, order="Pick up and drop off cell blankets",
     access="On call only. Call beforehand 9393 9555", phone="9393 9555")
c(79, "Urban Edge", "Level 1/90 Maribyrnong St", "Footscray",
     order="Bags of towels. Drop off and pick up",
     access="No day on the sheet - not on a run yet")
c(29, "Ikon Hygiene Services", "47 Baretta Rd", "Ravenhall", order="Take the truck and trolley",
     contact="Lily Kurti", phone="0408 366 798",
     access="No day on the sheet - not on a run yet")

# ── Werribee and Wyndham — Keith ─────────────────────────────────────────────
c(17, "Goodyear Werribee", "11 Bridge St", "Werribee", days=[FRI], freq='monthly_nth',
     nth=1, route=WERRI, order="1 x medium mat, 10 x roll towel",
     access="First Friday of the month. Take the invoice from Shane or Sunil "
            "before leaving")
c(35, "Mamma Roti", "1/2 Infinity Drive", "Truganina", days=[MON], route=WERRI,
     order="As per order", access="Take his phone number", contact="Dee", phone="0415 727 560")
c(57, "Sims", "Cnr Shaws Rd and Tarneit Rd", "Werribee", days=[FRI], route=WERRI,
     order="Blue coats on hangers", access="Check CHS")
c(59, "Sottile's Pizza", "12 Quarbing St", "Werribee", days=[FRI], route=WERRI,
     order="Bags of aprons, 25 tea towels, 20 microfibre cloths, 1 small mat",
     access="Use the key for the front door, or get it from the milk bar next door")
c(63, "Techtrans", "5/395 Old Geelong Rd", "Hoppers Crossing", days=[FRI],
     freq='fortnightly', route=WERRI, order="3 roll towel", access="Fortnightly")
c(67, "The Views - Werribee Golf Club", "K Rd", "Werribee South", days=[FRI],
     route=WERRI, order="Pick up and drop off")
c(73, "Westbourne Grammar School", "300 Sayers Rd", "Truganina", days=[MON, FRI],
     route=WERRI, order="Pick up and drop off tablecloths from reception",
     access="On call on the sheet - ring before going", contact="Andrea Cairns",
     phone="9731 9427")
c(78, "Wyndham Council (depot)", "241 Old Geelong Rd", "Hoppers Crossing", days=[FRI],
     route=WERRI, order="Bag(s) of overalls", access="2 bags")

# ── Geelong — the truck ──────────────────────────────────────────────────────
c(16, "G.T Recycling", "100 Point Henry Rd", "Moolap", days=[WED], route=TRUCK,
     order="Soft plastic drop off")
c(27, "IGA Supermarket - Grovedale", "17/79 Heyers Rd", "Grovedale", days=[WED],
     route=TRUCK, order="3 small mats, 1 medium mat, 2 long mats")
c(28, "IGA Supermarket - Grovedale East", "142-146 Marshalltown Rd", "Grovedale East",
     days=[WED], route=TRUCK, order="2 small mats, 1 medium mat, 1 long mat")
c(32, "Kempe", "52-60 Moon St", "Moolap", days=[WED], route=TRUCK,
     order="Bags of overalls, 5 x small mats, 3 x long mats, 12 x roll towel")
c(33, "Kempe - Incitec Pivot", "40 Sea Breeze Parade", "North Shore", days=[WED],
     route=TRUCK, order="Wheelie bin - overalls",
     access="Contact David H on 0490 736 298 for access, 5 minutes before")
c(56, "Sharp Welding", "6 Sandra Ave", "Norlane", days=[WED], route=TRUCK,
     order="Bags of overalls, 2 x roll towel")
c(61, "Steamatic Geelong", "7 Essington St", "Grovedale", days=[WED], route=TRUCK,
     order="Pick up and drop off insurance work", access="On call on the sheet - ask Phil")

# ── the three shops already in the database, from the master list ────────────
c(36, "Albert Park store", "35 Victoria Ave", "Albert Park", ref='C-004',
     order="Store orders - pick ups and drop offs")
c(55, "Seddon store", "83A Charles St", "Seddon", pc="3011", ref='MDC-SEDDON',
     order="Store orders - pick ups and drop offs")
c(65, "Butler store", "180 Camberwell Rd", "Hawthorn East", ref='C-010',
     order="Store orders - pick ups and drop offs")

# ─────────────────────────────────────────────────────────────────────────────
def q(v):
    if v is None: return 'null'
    if isinstance(v, (int, float)): return str(v)
    return "'" + str(v).replace("'", "''") + "'"

ROUTE_NAME = {VAN: "Van (Kemu) - the west", DARREN: "Darren's Van - city, inner east and south",
              WERRI: "Werribee (Keith) - Werribee and Wyndham", TRUCK: "Truck (Binod) - Geelong"}
DAY = {1:'Mon',2:'Tue',3:'Wed',4:'Thu',5:'Fri',6:'Sat'}

out = []
w = out.append
w("-- " + "=" * 74)
w("-- 0013 - the November 2023 run sheets")
w("--")
w("-- Generated by data/build_nov23_import.py from the two spreadsheets in data/.")
w("-- Do not hand-edit: change the sheet or the generator and regenerate.")
w("--")
w("-- What the sheets DO say, and is therefore reliable here:")
w("--   the customer list, addresses, what to collect or deliver, access notes")
w("--   and contacts, which weekdays each customer is visited, and whether they")
w("--   are weekly, fortnightly, monthly or on call.")
w("--")
w("-- What the sheets do NOT say, and is a guess for the office to correct:")
w("--")
w("--   * WHICH DRIVER. Split by suburb: the west on Kemu's van, the city and")
w("--     inner east and south on Darren's, Werribee and Wyndham on Keith's,")
w("--     Geelong on the truck. Nothing in the sheet supports this beyond")
w("--     geography. Moving a customer to another run is remove-then-add in the")
w("--     Runs screen, so expect that to be the bulk of the tidying up.")
w("--")
w("--   * THE ORDER WITHIN A DAY. Alphabetical, because the master sheet is")
w("--     alphabetical. The one exception is Kemu's Thursday, whose real running")
w("--     order came off his own sheet and is already loaded - left untouched,")
w("--     with the master sheet's extra Thursday stops appended behind it.")
w("--")
w("-- Re-runnable. Customers match on external_ref; stops are skipped when the")
w("-- same customer already sits on that run and weekday.")
w("-- " + "=" * 74)
w("")
w("-- -- customers --------------------------------------------------------------")
w("-- external_ref NOV23-nnn is the line number in data/nov23-all-records.csv.")
w("-- C-nnn and MDC-* already existed, from Kemu's Thursday sheet.")
w("insert into public.customers (business_id, external_ref, name, address_line, suburb,")
w("       postcode, phone, contact_name, standing_order, access_notes, earliest_time,")
w("       price_rise_date, price_rise_pct) values")
rows = []
for r in sorted(C, key=lambda r: r['row']):
    ref = r['ref'] or "NOV23-%03d" % r['row']
    rows.append("  (%s, %s, %s, %s, %s,\n   %s, %s, %s,\n   %s,\n   %s,\n   %s, %s, %s)" % (
        q(BIZ), q(ref), q(r['name']), q(r['addr']), q(r['sub']),
        q(r['pc']), q(r['phone']), q(r['contact']),
        q(r['order']), q(r['access']),
        q(r['early']) + '::time', q(r['pr']) + '::date', q(r['prpct'])))
w(",\n".join(rows))
w("on conflict (business_id, external_ref) where external_ref is not null do update set")
w("  name            = excluded.name,")
for f in ('address_line','suburb','postcode','phone','contact_name','standing_order',
          'access_notes','earliest_time','price_rise_date','price_rise_pct'):
    w("  %-15s = coalesce(excluded.%s, public.customers.%s)," % (f, f, f))
w("  updated_at      = now();")
w("")
w("-- -- the weekly pattern -----------------------------------------------------")
w("-- Kemu's Thursday closing marker moves to the back so his proven running")
w("-- order survives the extra Thursday stops the master sheet adds behind it.")
w("update public.route_stops set seq = 900")
w(" where route_id = %s and weekday = 4 and kind = 'target' and seq < 900;" % q(VAN))
w("")

pat = []
for rid in (VAN, DARREN, WERRI, TRUCK):
    for wd in range(1, 7):
        day = sorted([r for r in C if r['route'] == rid and wd in r['days']],
                     key=lambda r: r['name'].lower())
        if not day: continue
        seq = 140 if (rid == VAN and wd == 4) else 10
        pat.append("  -- %s, %s (%d)" % (ROUTE_NAME[rid], DAY[wd], len(day)))
        for r in day:
            ref = r['ref'] or "NOV23-%03d" % r['row']
            pat.append("  (%s, %s, %d, %d, %s, %s)" % (
                q(ref), q(rid), wd, seq, q(r['freq']), q(r['nth'])))
            seq += 10

w("insert into public.route_stops (business_id, route_id, customer_id, kind, tickable,")
w("       weekday, visit_no, seq, frequency, anchor_date, nth_of_month)")
w("select %s, v.route_id::uuid, c.id, 'customer', true," % q(BIZ))
w("       v.weekday, 1, v.seq, v.frequency,")
w("       -- the snap_fortnightly_anchor trigger moves this to the stop's own weekday")
w("       case when v.frequency = 'fortnightly' then current_date end,")
w("       v.nth_of_month")
w("  from (values")
w(",\n".join(p for p in pat if not p.startswith('  --')) if False else "\n".join(
    (p if p.startswith('  --') else p + ',') for p in pat).rstrip(','))
w("       ) as v(ref, route_id, weekday, seq, frequency, nth_of_month)")
w("  join public.customers c")
w("    on c.business_id = %s and c.external_ref = v.ref" % q(BIZ))
w(" where not exists (")
w("   select 1 from public.route_stops x")
w("    where x.route_id = v.route_id::uuid and x.weekday = v.weekday")
w("      and x.customer_id = c.id and x.visit_no = 1 and x.active_to is null);")
w("")
text = "\n".join(out)
head, rest = text.split("\n\n-- -- customers", 1)
body = "-- -- customers" + rest
cust, patt = body.split("-- -- the weekly pattern", 1)
open("supabase/migrations/0013_nov23_customers.sql", "w").write(
    head.replace("0013 - the November 2023 run sheets",
                 "0013 - the November 2023 run sheets: the customers")
    + "\n\n" + cust.rstrip() + "\n")
open("supabase/migrations/0014_nov23_run_pattern.sql", "w").write(
    head.replace("0013 - the November 2023 run sheets",
                 "0014 - the November 2023 run sheets: the weekly pattern")
    + "\n\n-- -- the weekly pattern" + patt.rstrip() + "\n")
print("wrote supabase/migrations/0013_nov23_customers.sql and 0014_nov23_run_pattern.sql")
