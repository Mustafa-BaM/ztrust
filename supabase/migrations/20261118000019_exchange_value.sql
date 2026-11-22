-- Z Trust · tender used to settle the returned part of an exchange (enum values need their own migration)
alter type public.tender_type add value if not exists 'exchange';
