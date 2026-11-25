# Changelog

## 1.1.0

- **FKS Banking integration** (`Config.FKS_Banking`, off by default): company bills written with `/billing` in
  fks-banking are paid straight into the company balance and show in the ledger as "Bank bill" (number, payer and
  reason).
- New server exports `BankingEnabled`, `GetCompanyByJob` and `AddBillIncome` (only fks-banking may call it).
- Console warning when `Config.FKS_Banking` is on but fks-banking is not running.

## 1.0.0

First public release.

- **Companies** created anywhere with `/createnewcompany`: identity, framework job, owner, blip, starting balance,
  automatic tax (fixed or % of the balance, every 0 to 30 days plus hours), storage capacity, employee limit and sale.
- **Employment contracts** signed by the player, custom **positions** mapped to the framework job grades and
  22 permissions in 6 groups. The Boss always has every permission.
- **Ledger** with every movement (who, before / after balance), deposits, withdrawals and automatic taxes with three
  failure policies (`skip`, `partial`, `suspend`).
- **Boss and general storages** and a **cash register** placed with a see-through preview; on/off **duty** with an
  on-duty / off-duty map blip colour and payment requests to customers.
- **NPC store** that sells the company products while nobody is on duty: product grid, cart and checkout, stock screen.
- **Marketplace**: companies for sale (public or at the company), paid in cash, the seller is paid even when offline.
- **`/managecompanies`** admin panel: search and filters, edit everything, status (active / inactive / suspended),
  admin log, **Archive** (keeps the history) or **Delete for good**, and an archived companies list.
- **Blip gallery** with search and categories, flat ground marker at the company point, custom menu icons.
- Every screen drawn by **fks-core** (one NUI for the server); 7 languages: en, pt, br, es, fr, de, it.
- Console version check against GitHub and a warning when fks-core is missing.
- Requires **fks-core 2.1.2+**, **ox_lib** and **oxmysql**. Tables are created on start (`sql/install.sql`).
