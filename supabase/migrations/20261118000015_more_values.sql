-- Values used by the next migration (enum values must be committed before use)
alter type public.tender_type add value if not exists 'gift_card';   -- redeemed from a gift card code
alter type public.tender_type add value if not exists 'cod';         -- cash on delivery, held by the driver until handed in
