-- Index the sender foreign key used by conversation history and message ownership.
create index if not exists support_messages_sender_id_idx
  on public.support_messages (sender_id);
