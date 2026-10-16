-- WAVE Social: secure gift sending and protect wallet balances.
-- Applied to Supabase project fhpvjzhpavgvrwdqzutd on 2026-10-16.

create or replace function public.send_gift(
  p_recipient_id uuid,
  p_gift_id uuid,
  p_quantity integer default 1,
  p_room_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender uuid := auth.uid();
  v_price bigint;
  v_total bigint;
  v_balance bigint;
  v_transaction_id uuid;
begin
  if v_sender is null then
    raise exception 'يجب تسجيل الدخول أولاً' using errcode = '28000';
  end if;
  if p_recipient_id is null or p_recipient_id = v_sender then
    raise exception 'اختر عضواً آخر لإرسال الهدية' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'الكمية يجب أن تكون من 1 إلى 100' using errcode = '22023';
  end if;

  select coin_price into v_price
  from public.gifts
  where id = p_gift_id and is_active = true;
  if not found then
    raise exception 'الهدية غير متاحة حالياً' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_recipient_id) then
    raise exception 'العضو المستلم غير موجود' using errcode = '22023';
  end if;

  if p_room_id is not null and not exists (
    select 1 from public.rooms where id = p_room_id and status = 'open'
  ) then
    raise exception 'الغرفة غير متاحة' using errcode = '22023';
  end if;

  v_total := v_price * p_quantity;
  select coins into v_balance
  from public.profiles where id = v_sender for update;

  if not found then
    raise exception 'ملف حساب المرسل غير موجود' using errcode = 'P0002';
  end if;
  if v_balance < v_total then
    raise exception 'رصيد العملات غير كافٍ' using errcode = '22003';
  end if;

  update public.profiles
  set coins = coins - v_total, updated_at = now()
  where id = v_sender;

  insert into public.gift_transactions
    (sender_id, recipient_id, room_id, gift_id, quantity, total_coins)
  values
    (v_sender, p_recipient_id, p_room_id, p_gift_id, p_quantity, v_total)
  returning id into v_transaction_id;

  insert into public.admin_audit_log(actor_id, action, target_type, target_id, details)
  values (v_sender, 'gift_sent', 'gift_transaction', v_transaction_id::text,
          jsonb_build_object('recipient_id', p_recipient_id, 'gift_id', p_gift_id,
                             'quantity', p_quantity, 'total_coins', v_total));

  return jsonb_build_object('transaction_id', v_transaction_id,
                            'total_coins', v_total,
                            'remaining_coins', v_balance - v_total);
end;
$$;

revoke all on function public.send_gift(uuid, uuid, integer, uuid) from public, anon;
grant execute on function public.send_gift(uuid, uuid, integer, uuid) to authenticated;

-- Do not allow clients to mint coins or change VIP levels through profile updates.
revoke update on public.profiles from authenticated;
grant update (username, display_name, avatar_url, bio, country) on public.profiles to authenticated;
