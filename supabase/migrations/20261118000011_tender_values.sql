-- New tenders used by phases B–D. Enum values must be committed before any function uses them, so they live in their own migration.
alter type public.tender_type add value if not exists 'loyalty';   -- points redeemed
alter type public.tender_type add value if not exists 'package';   -- a prepaid session from a customer package
alter type public.tender_type add value if not exists 'deposit';   -- a deposit taken earlier on a job card or pre-order
