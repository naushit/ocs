%%% ocs_rating.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2017 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This library module implements utility functions
%%% 	for handling rating in the {@link //ocs. ocs} application.
%%%
-module(ocs_rating).
-copyright('Copyright (c) 2016 - 2017 SigScale Global Inc.').

-export([rate/8]).

-include("ocs.hrl").
-include_lib("radius/include/radius.hrl").

%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}})
-define(EPOCH, 62167219200).

%% service types for radius
-define(RADIUSDATA, 2).
-define(RADIUSVOICE, 12).
%% service types for diameter
-define(DIAMETERDATA, <<"32251@3gpp.org">>).
-define(DIAMETERVOICE, <<"32260@3gpp.org">>).

-spec rate(Protocol, ServiceType, SubscriberID, Destination,
		Flag, DebitAmounts, ReserveAmounts, SessionAttributes) -> Result
	when
		Protocol :: radius | diameter,
		ServiceType :: integer() | binary(),
		SubscriberID :: string() | binary(),
		Destination :: string(),
		Flag :: initial | interim | final,
		DebitAmounts :: [{Type, Amount}],
		ReserveAmounts :: [{Type, Amount}],
		SessionAttributes :: [tuple()],
		Type :: octets | seconds,
		Amount :: integer(),
		Result :: {ok, Subscriber, GrantedAmount} | {out_of_credit, SessionList}
				| {disabled, SessionList} | {error, Reason},
		Subscriber :: #subscriber{},
		GrantedAmount :: integer(),
		SessionList :: [{pos_integer(), [tuple()]}],
		Reason :: term().
%% @doc Handle rating and balance management for used and reserved unit amounts.
%%
%% 	Subscriber balance buckets are permanently reduced by the
%% 	amount(s) in `DebitAmounts' and `Type' buckets are allocated
%% 	by the amount(s) in `ReserveAmounts'. The subscribed product
%% 	determines the price used to calculate the amount to be
%% 	permanently debited from available `cents' buckets.
%%
%% 	Returns `{ok, Subscriber, GrantedAmount}' if successful.
%%
%% 	Returns `{out_of_credit, SessionList}' if the subscriber's
%% 	balance is insufficient to cover the `DebitAmounts' and
%% 	`ReserveAmounts' or `{disabled, SessionList}' if the subscriber
%% 	is not enabled. In both cases subscriber's balance is debited.
%% 	`SessionList' describes the known active sessions which
%% 	should be disconnected.
%%
rate(Protocol, ServiceType, SubscriberID, Destination,
		Flag, DebitAmounts, ReserveAmounts, SessionAttributes) when is_list(SubscriberID)->
	rate(Protocol, ServiceType, list_to_binary(SubscriberID), Destination,
		Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
rate(Protocol, ServiceType, SubscriberID, Destination,
		Flag, DebitAmounts, ReserveAmounts, SessionAttributes) when
		((Protocol == radius) or (Protocol == diameter)), is_binary(SubscriberID),
		((Flag == initial) or (Flag == interim) or (Flag == final)),
		is_list(DebitAmounts), is_list(ReserveAmounts), length(SessionAttributes) > 0 ->
	F = fun() ->
			case mnesia:read(subscriber, SubscriberID, write) of
				[#subscriber{buckets = Buckets, product =
						#product_instance{product = ProdID,
						characteristics = Chars}} = Subscriber] ->
					case mnesia:read(product, ProdID, read) of
						[#product{} = Product] ->
							Validity = proplists:get_value(validity, Chars),
							Subscriber1 = Subscriber#subscriber{buckets = due(Buckets)},
							rate1(Protocol, ServiceType, Subscriber1, Destination, Product,
									Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
						[] ->
							throw(product_not_found)
					end;
				[] ->
					throw(subsriber_not_found)
			end
	end,
	case mnesia:transaction(F) of
		{atomic, {grant, Sub, GrantedAmount}} ->
			{ok, Sub, GrantedAmount};
		{atomic, {out_of_credit, SL}} ->
			{out_of_credit, SL};
		{atomic, {disabled, SL}} ->
			{disabled, SL};
		{aborted, {throw, Reason}} ->
			{error, Reason};
		{aborted, Reason} ->
			{error, Reason}
	end.
%% @hidden
rate1(Protocol, ServiceType, Subscriber, Destination,
		#product{specification = undefined, bundle = Bundle},
		Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes) ->
	try
		F = fun(#bundled_po{name = ProdId}, Acc) ->
				case mnesia:read(product, ProdId, read) of
					[#product{specification = Spec, status = Status} = P] when
							(((Status == active) orelse (Status == undefined)
							and
							(Protocol == radius)
								and
								((ServiceType == ?RADIUSDATA) and ((Spec == 4) orelse (Spec == 8)))
								orelse
								((ServiceType == ?RADIUSVOICE) and ((Spec == 5) orelse (Spec == 9))))
							orelse
							(Protocol == diameter)
								and
								((ServiceType == ?DIAMETERDATA) and ((Spec == 4) orelse (Spec == 8)))
								orelse
								((ServiceType == ?DIAMETERVOICE) and ((Spec == 5) orelse (Spec == 9)))) ->
						[P | Acc];
					_ ->
						Acc
				end
		end,
		[#product{} = Product | _] = lists:foldl(F, [], Bundle),
		rate2(Protocol, Subscriber, Destination, Product, Validity,
				Flag, DebitAmounts, ReserveAmounts, SessionAttributes)
	catch
		_:_ ->
			throw(invalid_bundle_product)
	end;
rate1(Protocol, _ServiceType, Subscriber, Destination, Product,
		Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes) ->
	rate2(Protocol, Subscriber, Destination, Product, Validity,
			Flag, DebitAmounts, ReserveAmounts, SessionAttributes).
%% @hidden
rate2(Protocol, Subscriber, Destination, #product{specification = ProdSpec,
		char_value_use = CharValueUse, price = Prices}, Validity, Flag,
		DebitAmounts, ReserveAmounts, SessionAttributes)
		when ProdSpec == "5", ProdSpec == "9" ->
	FilteredPrices = filter_prices(Prices),
	case lists:keyfind("destPrefixPriceTable", #char_value_use.name, CharValueUse) of
		#char_value_use{values = [#char_value{value = PriceTable}]} ->
			rate3(Protocol, list_to_existing_atom(PriceTable), Subscriber, Destination, FilteredPrices,
					Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
		false ->
			 case lists:keyfind("destPrefixTariffTable", #char_value_use.name, CharValueUse) of
				#char_value_use{values = [#char_value{value = TariffTable}]} ->
					rate4(Protocol, list_to_existing_atom(TariffTable), Subscriber, Destination,
							FilteredPrices, Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
				_ ->
					throw(table_prefix_not_found)
			end
	end;
rate2(Protocol, Subscriber, _Destiations, #product{price = Prices}, Validity,
		Flag, DebitAmounts, ReserveAmounts, SessionAttributes) ->
	case lists:keyfind(usage, #price.type, Prices) of
		#price{} = Price ->
			rate5(Protocol, Subscriber, Price, Validity,
				Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
		false ->
			throw(price_not_found)
	end.
%% @hidden
rate3(Protocol, PriceTable, Subscriber, Destination, Prices,
		Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes) ->
	case catch ocs_gtt:lookup_last(PriceTable, Destination) of
		{_Description, RateName} when is_list(RateName) ->
			F1 = fun(F, [#price{char_value_use = CharValueUse} = H | T]) ->
						case lists:keyfind("ratePrice", #char_value_use.name, CharValueUse) of
							#char_value_use{values = [#char_value{value = RateName}]} ->
								H;
							false ->
								F(F, T)
						end;
					(_, []) ->
						F2 = fun(_, [#price{name = Name} = H | _]) when Name == RateName ->
									H;
								(F, [_H | T]) ->
									F(F, T);
								(_, []) ->
									false
						end,
						F2(F2, Prices)
			end,
			case F1(F1, Prices) of
				#price{} = Price ->
					rate5(Protocol, Subscriber, Price, Validity,
							Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
				false ->
					error_logger:error_report(["Prefix table price name not found",
							{module, ?MODULE}, {table, PriceTable},
							{destination, Destination}, {price_name, RateName}]),
					throw(price_not_found)
			end;
		Other ->
			error_logger:error_report(["Prefix table price name lookup failed",
					{module, ?MODULE}, {table, PriceTable},
					{destination, Destination}, {result, Other}]),
			throw(table_lookup_failed)
	end.
%% @hidden
rate4(Protocol, TariffTable, Subscriber, Destination, Prices,
		Validity, Flag, DebitAmounts, ReserveAmounts, SessionAttributes) ->
	case catch ocs_gtt:lookup_last(TariffTable, Destination) of
		{_Description, AmountL} ->
			Amount = case AmountL of
				A when is_list(A) ->
					list_to_integer(A);
				A when is_integer(A) ->
					A
			end,
			case lists:keyfind(tariff, #price.type, Prices) of
				#price{} = Price ->
					rate5(Protocol, Subscriber, Price#price{amount = Amount}, Validity,
							Flag, DebitAmounts, ReserveAmounts, SessionAttributes);
				false ->
					error_logger:error_report(["Prefix table tariff price type not found",
							{module, ?MODULE}, {table, TariffTable},
							{destination, Destination}, {tariff_price, Amount}]),
					throw(price_not_found)
			end;
		Other ->
			error_logger:error_report(["Prefix table tariff lookup failed",
					{module, ?MODULE}, {table, TariffTable},
					{destination, Destination}, {result, Other}]),
			throw(table_lookup_failed)
	end.
%% @hidden
rate5(_Protocol, #subscriber{enabled = false} = Subscriber, _Price,
		_Validity, initial, _DebitAmounts, _ReserveAmounts,
		SessionAttributes) ->
	rate7(Subscriber, initial, 0, 0, 0, 0, SessionAttributes);
rate5(radius, Subscriber, Price, Validity,
		initial, [], [], SessionAttributes) ->
	rate6(Subscriber, Price, Validity, initial,
			0, get_reserve(Price), SessionAttributes);
rate5(radius, Subscriber, #price{units = Units} = Price, Validity,
		interim, [], ReserveAmounts, SessionAttributes) ->
	ReserveAmount = case lists:keyfind(Units, 1, ReserveAmounts) of
		{_, ReserveUnits} ->
			ReserveUnits + get_reserve(Price);
		false ->
			get_reserve(Price)
	end,
	rate6(Subscriber, Price, Validity, interim,
			0, ReserveAmount, SessionAttributes);
rate5(_Protocol, Subscriber, #price{units = Units} = Price, Validity,
		Flag, DebitAmounts, ReserveAmounts, SessionAttributes) ->
	DebitAmount = case lists:keyfind(Units, 1, DebitAmounts) of
		{_, DebitUnits} ->
			DebitUnits;
		false ->
			0
	end,
	ReserveAmount = case lists:keyfind(Units, 1, ReserveAmounts) of
		{_, ReserveUnits} ->
			ReserveUnits;
		false ->
			0
	end,
	rate6(Subscriber, Price, Validity, Flag,
			DebitAmount, ReserveAmount, SessionAttributes).
%% @hidden
rate6(#subscriber{buckets = Buckets1} = Subscriber,
		#price{units = Units, size = UnitSize, amount = UnitPrice},
		_Validity, initial, 0, ReserveAmount, SessionAttributes) ->
	SessionId = get_session_id(SessionAttributes),
	case reserve_session(Units, ReserveAmount, SessionId, Buckets1) of
		{ReserveAmount, Buckets2} ->
			rate7(Subscriber#subscriber{buckets = Buckets2},
					initial, 0, 0, ReserveAmount, ReserveAmount,
					SessionAttributes);
		{UnitsReserved, Buckets2} ->
			PriceReserveUnits = (ReserveAmount - UnitsReserved),
			{UnitReserve, PriceReserve} = price_units(PriceReserveUnits,
					UnitSize, UnitPrice),
			case reserve_session(cents, PriceReserve, SessionId, Buckets2) of
				{PriceReserve, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3},
							initial, 0, 0, ReserveAmount,
							UnitsReserved + UnitReserve, SessionAttributes);
				{PriceReserved, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = refund(SessionId, Buckets3)},
							initial, 0, 0, ReserveAmount,
							UnitsReserved + (PriceReserved div UnitPrice),
							SessionAttributes)
			end
	end;
rate6(#subscriber{enabled = false, buckets = Buckets1} = Subscriber,
		#price{units = Units, size = UnitSize, amount = UnitPrice},
		_Validity, interim, DebitAmount, _ReserveAmount, SessionAttributes) ->
	SessionId = get_session_id(SessionAttributes),
	case update_session(Units, DebitAmount, 0, SessionId, Buckets1) of
		{DebitAmount, 0, Buckets2} ->
			rate7(Subscriber#subscriber{buckets = Buckets2}, interim,
					DebitAmount, DebitAmount, 0, 0, SessionAttributes);
		{UnitsCharged, 0, Buckets2} ->
			PriceChargeUnits = DebitAmount - UnitsCharged,
			{UnitCharge, PriceCharge} = price_units(PriceChargeUnits,
					UnitSize, UnitPrice),
			case update_session(cents, PriceCharge, 0, SessionId, Buckets2) of
				{PriceCharge, 0, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3}, interim,
							DebitAmount, DebitAmount + UnitCharge,
							0, 0, SessionAttributes);
				{PriceCharged, 0, Buckets3} ->
					Bucket4 = [#bucket{remain_amount = PriceCharged - PriceCharge,
							units = cents} | refund(SessionId, Buckets3)],
					rate7(Subscriber#subscriber{buckets = Bucket4}, interim, DebitAmount,
							UnitsCharged + (PriceCharged div UnitPrice), 0, 0,
							SessionAttributes)
			end
	end;
rate6(#subscriber{buckets = Buckets1} = Subscriber,
		#price{units = Units, size = UnitSize, amount = UnitPrice},
		_Validity, interim, DebitAmount, ReserveAmount, SessionAttributes) ->
	SessionId = get_session_id(SessionAttributes),
	case update_session(Units, DebitAmount, ReserveAmount,
			SessionId, Buckets1) of
		{DebitAmount, ReserveAmount, Buckets2} ->
			rate7(Subscriber#subscriber{buckets = Buckets2}, interim,
					DebitAmount, DebitAmount, ReserveAmount, ReserveAmount,
					SessionAttributes);
		{DebitAmount, UnitsReserved, Buckets2} ->
			PriceReserveUnits = ReserveAmount - UnitsReserved,
			{UnitReserve, PriceReserve} = price_units(PriceReserveUnits,
					UnitSize, UnitPrice),
			case update_session(cents, 0, PriceReserve, SessionId, Buckets2) of
				{0, PriceReserve, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3}, interim,
							DebitAmount, DebitAmount, ReserveAmount,
							UnitReserve, SessionAttributes);
				{0, PriceReserved, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3}, interim,
							DebitAmount, DebitAmount, ReserveAmount,
							UnitsReserved + PriceReserved div UnitPrice,
							SessionAttributes)
			end;
		{UnitsCharged, 0, Buckets2} ->
			PriceChargeUnits = DebitAmount - UnitsCharged,
			{UnitCharge, PriceCharge} = price_units(PriceChargeUnits,
					UnitSize, UnitPrice),
			{UnitReserve, PriceReserve} = price_units(ReserveAmount,
					UnitSize, UnitPrice),
			case update_session(cents,
					PriceCharge, PriceReserve, SessionId, Buckets2) of
				{PriceCharge, PriceReserve, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3}, interim,
							DebitAmount, UnitsCharged + UnitCharge, ReserveAmount,
							UnitReserve, SessionAttributes);
				{PriceCharge, PriceReserved, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3}, interim,
							DebitAmount, UnitsCharged + UnitCharge, ReserveAmount,
							PriceReserved div UnitPrice, SessionAttributes);
				{PriceCharged, 0, Buckets3} ->
					Buckets4 = [#bucket{remain_amount = PriceCharged - PriceCharge,
							units = cents} | refund(SessionId, Buckets3)],
					rate7(Subscriber#subscriber{buckets = Buckets4}, interim,
							DebitAmount, UnitsCharged + (PriceCharged div UnitPrice),
							ReserveAmount, 0, SessionAttributes)
			end
	end;
rate6(#subscriber{buckets = Buckets1} = Subscriber,
		#price{units = Units, size = UnitSize, amount = UnitPrice},
		_Validity, final, DebitAmount, 0, SessionAttributes) ->
	SessionId = get_session_id(SessionAttributes),
	case charge_session(Units, DebitAmount, SessionId, Buckets1) of
		{DebitAmount, Buckets2} ->
			rate7(Subscriber#subscriber{buckets = Buckets2}, final,
					DebitAmount, DebitAmount, 0, 0, SessionAttributes);
		{UnitsCharged, Buckets2} ->
			PriceChargeUnits = DebitAmount - UnitsCharged,
			{UnitCharge, PriceCharge} = price_units(PriceChargeUnits,
					UnitSize, UnitPrice),
			case charge_session(cents, PriceCharge, SessionId, Buckets2) of
				{PriceCharge, Buckets3} ->
					rate7(Subscriber#subscriber{buckets = Buckets3}, final,
							DebitAmount, UnitsCharged + UnitCharge,
							0, 0, SessionAttributes);
				{PriceCharged, Buckets3} ->
					Buckets4 = [#bucket{remain_amount = PriceCharged - PriceCharge,
							units = cents} | refund(SessionId, Buckets3)],
					rate7(Subscriber#subscriber{buckets = Buckets4}, final,
					DebitAmount, UnitsCharged + (PriceCharged div UnitPrice),
					0, 0, SessionAttributes)
			end
	end.
%% @hidden
rate7(#subscriber{session_attributes = SessionList, buckets  = Buckets} = Subscriber1,
		final, Charge, Charged, 0, 0, SessionAttributes)
		when Charged >= Charge ->
	SessionId = get_session_id(SessionAttributes),
	NewBuckets = refund(SessionId, Buckets),
	NewSessionList = remove_session(SessionAttributes, SessionList),
	Subscriber2 = Subscriber1#subscriber{buckets = NewBuckets,
			session_attributes = NewSessionList},
	ok = mnesia:write(Subscriber2),
	{grant, Subscriber2, 0};
rate7(#subscriber{session_attributes = SessionList} = Subscriber1,
		final, _Charge, _Charged, 0, 0, _SessionAttributes) ->
	Subscriber2 = Subscriber1#subscriber{session_attributes = []},
	ok = mnesia:write(Subscriber2),
	{out_of_credit, SessionList};
rate7(#subscriber{enabled = false,
		session_attributes = SessionList} = Subscriber1, _Flag,
		_Charge, _Charged, _Reserve, _Reserved, _SessionAttributes) ->
	Subscriber2 = Subscriber1#subscriber{session_attributes = []},
	ok = mnesia:write(Subscriber2),
	{disabled, SessionList};
rate7(#subscriber{session_attributes = SessionList} = Subscriber1, _Flag,
		Charge, Charged, Reserve, Reserved, _SessionAttributes)
		when Charged < Charge; Reserved <  Reserve ->
	Subscriber2 = Subscriber1#subscriber{session_attributes = []},
	ok = mnesia:write(Subscriber2),
	{out_of_credit, SessionList};
rate7(#subscriber{session_attributes = SessionList} = Subscriber1,
		initial, 0, 0, _Reserve, Reserved, SessionAttributes) ->
	NewSessionList = add_session(SessionAttributes, SessionList),
	Subscriber2 = Subscriber1#subscriber{session_attributes = NewSessionList},
	ok = mnesia:write(Subscriber2),
	{grant, Subscriber2, Reserved};
rate7(Subscriber, interim, _Charge, _Charged, _Reserve, Reserved, _SessionAttributes) ->
	ok = mnesia:write(Subscriber),
	{grant, Subscriber, Reserved}.

%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------

-spec reserve_session(Type, Amount, SessionId, Buckets) -> Result
	when
		Type :: octets | seconds | cents,
		Amount :: non_neg_integer(),
		SessionId :: string() | binary(),
		Buckets :: [#bucket{}],
		Result :: {Reserved, NewBuckets},
		Reserved :: non_neg_integer(),
		NewBuckets :: [#bucket{}].
%% @doc Perform reservation for a session.
%%
%% 	Creates a reservation within bucket(s) of `Type' and
%% 	decrements remaining balance by the same amount(s).
%%
%% 	Expired buckets are removed when no session
%% 	reservations remain.
%%
%% 	Returns `{Reserved, NewBuckets}' where
%% 	`Reserved' is the total amount of reservation(s) made
%% 	and `NewBuckets' is the updated bucket list.
%%
%% @private
reserve_session(Type, Amount, SessionId, Buckets) ->
	Now = erlang:system_time(?MILLISECOND),
	reserve_session(Type, Amount, Now, SessionId, sort(Buckets), [], 0).
%% @hidden
reserve_session(Type, Amount, Now, SessionId,
		[#bucket{termination_date = Expires, reservations = [],
		remain_amount = Remain} | T], Acc, Reserved)
		when Expires /= undefined, Expires =< Now, Remain >= 0 ->
	reserve_session(Type, Amount, Now, SessionId, T, Acc, Reserved);
reserve_session(Type, Amount, Now, SessionId,
		[#bucket{units = Type, remain_amount = Remain,
		reservations = Reservations, termination_date = Expires} = B | T],
		Acc, Reserved) when Remain >= Amount,
		((Expires == undefined) or (Now < Expires)) ->
	NewReservation = {Now, Amount, SessionId},
	NewBuckets = lists:reverse(Acc)
			++ [B#bucket{remain_amount = Remain - Amount,
			reservations = [NewReservation | Reservations]} | T],
	{Reserved + Amount, NewBuckets};
reserve_session(Type, Amount, Now, SessionId,
		[#bucket{units = Type, remain_amount = 0} = B | T], Acc, Reserved) ->
	reserve_session(Type, Amount, Now, SessionId, T, [B | Acc], Reserved);
reserve_session(Type, Amount, Now, SessionId,
		[#bucket{units = Type, remain_amount = Remain,
		reservations = Reservations, termination_date = Expires} = B | T],
		Acc, Reserved) when Remain > 0, Remain < Amount,
		((Expires == undefined) or (Now < Expires)) ->
	NewReservation = {Now, Remain, SessionId},
	NewAcc = [B#bucket{remain_amount = 0,
			reservations = [NewReservation | Reservations]} | Acc],
	reserve_session(Type, Amount - Remain, Now,
			SessionId, T, NewAcc, Reserved + Remain);
reserve_session(Type, Amount, Now, SessionId, [H | T], Acc, Reserved) ->
	reserve_session(Type, Amount, Now, SessionId, T, [H | Acc], Reserved);
reserve_session(_, _, _, _, [], Acc, Reserved) ->
	{Reserved, lists:reverse(Acc)}.

-spec update_session(Type, Charge, Reserve, SessionId, Buckets) -> Result
	when
		Type :: octets | seconds | cents,
		Charge :: non_neg_integer(),
		Reserve :: non_neg_integer(),
		SessionId :: string() | binary(),
		Buckets :: [#bucket{}],
		Result :: {Charged, Reserved, NewBuckets},
		Charged :: non_neg_integer(),
		Reserved :: non_neg_integer(),
		NewBuckets :: [#bucket{}].
%% @doc Perform debit and reservation for a session.
%%
%% 	Finds reservations matching `SessionId'.
%%
%% 	Empty or expired buckets are removed when no session
%% 	reservations remain.
%%
%% 	Returns `{Charged, Reserved, NewBuckets}' where
%% 	`Charged' is the total amount debited from bucket(s),
%% 	`Reserved' is the total amount of reservation(s) made,
%% 	and `NewBuckets' is the updated bucket list.
%%
%% @private
update_session(Type, Charge, Reserve, SessionId, Buckets) ->
	Now = erlang:system_time(?MILLISECOND),
	update_session(Type, Charge, Reserve, Now, SessionId,
			sort(Buckets), [], 0, 0).
%% @hidden
update_session(Type, Charge, Reserve, Now, SessionId,
		[#bucket{termination_date = Expires, reservations = [],
		remain_amount = Remain} | T], Acc, Charged, Reserved)
		when Expires /= undefined, Expires =< Now, Remain >= 0 ->
	update_session(Type, Charge, Reserve,
			Now, SessionId, T, Acc, Charged, Reserved);
update_session(Type, Charge, Reserve, Now, SessionId,
		[#bucket{units = Type, remain_amount = Remain,
		termination_date = Expires, reservations = Reservations} = B | T],
		Acc, Charged, Reserved) ->
	case lists:keytake(SessionId, 3, Reservations) of
		{value, {_, Amount, _}, NewReservations}
				when Remain > 0, Remain >= (Reserve - (Amount - Charge)),
				((Expires == undefined) or (Now < Expires)) ->
			NewReservation = {Now, Reserve, SessionId},
			NewBuckets = lists:reverse(Acc)
					++ [B#bucket{remain_amount = Remain
					- (Reserve - (Amount - Charge)),
					reservations = [NewReservation | NewReservations]} | T],
			{Charged + Charge, Reserved + Reserve, NewBuckets};
		{value, {_, Amount, _}, []}
				when Remain >= 0, (Remain + Amount) =< Charge,
				((Expires == undefined) or (Now < Expires)) ->
			update_session(Type, Charge - (Remain + Amount), Reserve,
					Now, SessionId, T, Acc, Charged + Remain + Amount, Reserved);
		{value, {_, Amount, _}, []}
				when Amount >= Charge, Expires /= undefined, Expires =< Now ->
			update_session(Type, 0, Reserve, Now,
					SessionId, T, Acc, Charge, Reserved);
		{value, {_, Amount, _}, NewReservations}
				when Amount >= Charge, Expires /= undefined, Expires =< Now ->
			NewAcc = [B#bucket{reservations = NewReservations} | Acc],
			update_session(Type, 0, Reserve, Now,
					SessionId, T, NewAcc, Charge, Reserved);
		{value, {_, Amount, _}, []}
				when Amount < Charge, Expires /= undefined, Expires =< Now ->
			update_session(Type, Charge - Amount, Reserve, Now,
					SessionId, T, Acc, Charge, Reserved);
		{value, {_, Amount, _}, NewReservations}
				when Amount < Charge, Expires /= undefined, Expires =< Now ->
			NewAcc = [B#bucket{reservations = NewReservations} | Acc],
			update_session(Type, Charge - Amount, Reserve, Now,
					SessionId, T, NewAcc, Charge, Reserved);
		{value, {_, Amount, _}, NewReservations}
				when Remain > 0, (Remain + Amount) =< Charge,
				((Expires == undefined) or (Now < Expires)) ->
			NewAcc = [B#bucket{remain_amount = 0, reservations = NewReservations} | Acc],
			update_session(Type, Charge - (Remain + Amount), Reserve,
					Now, SessionId, T, NewAcc, Charged + Remain + Amount, Reserved);
		{value, {_, Amount, _}, NewReservations}
				when Remain >= (Charge - Amount),
				((Expires == undefined) or (Now < Expires)) ->
			NewReserve = Remain - (Charge - Amount),
			NewReservation = {Now, NewReserve, SessionId},
			NewAcc = [B#bucket{remain_amount = 0,
					reservations = [NewReservation | NewReservations]} | Acc],
			update_session(Type, 0, Reserve - NewReserve, Now, SessionId,
					T, NewAcc, Charged + Charge, Reserved + NewReserve);
		_ when Reservations == [], Expires /= undefined, Expires =< Now ->
			update_session(Type, Charge, Reserve, Now, SessionId,
					T, Acc, Charged, Reserved);
		false ->
			update_session(Type, Charge, Reserve, Now, SessionId,
					T, [B | Acc], Charged, Reserved)
	end;
update_session(Type, Charge, Reserve, Now, SessionId,
		[H | T], Acc, Charged, Reserved) ->
	update_session(Type, Charge, Reserve, Now, SessionId,
			T, [H | Acc], Charged, Reserved);
update_session(_, 0, Reserved, _, _, [], Acc, Charged, Reserved) ->
	{Charged, Reserved, lists:reverse(Acc)};
update_session(Type, Charge, Reserve, Now, SessionId, [], Acc, Charged, Reserved) ->
	update(Type, Charge, Reserve, Now, SessionId, lists:reverse(Acc), [], Charged, Reserved).

%% @hidden
update(Type, Charge, Reserve, Now, SessionId,
		[#bucket{termination_date = Expires, reservations = [],
		remain_amount = Remain} | T], Acc, Charged, Reserved)
		when Expires /= undefined, Expires =< Now, Remain >= 0 ->
	update(Type, Charge, Reserve, Now, SessionId, T, Acc, Charged, Reserved);
update(Type, Charge, Reserve, Now, SessionId, [#bucket{units = Type,
		remain_amount = Remain, termination_date = Expires,
		reservations = Reservations} = B | T], Acc, Charged, Reserved)
		when ((Expires == undefined) or (Now < Expires)), Remain > (Charge + Reserve) ->
	NewReservation = {Now, Reserve, SessionId},
	NewBuckets = [B#bucket{remain_amount = Remain - (Charge + Reserve),
		reservations = [NewReservation | Reservations]} | Acc],
	{Charged + Charge, Reserved + Reserve, lists:reverse(NewBuckets) ++ T};
update(Type, Charge, Reserve, Now, SessionId, [#bucket{units = Type,
		remain_amount = Remain, termination_date = Expires} = B | T],
		Acc, Charged, Reserved) when ((Expires == undefined) or (Now < Expires)),
		Remain >= 0, Remain =< Charge ->
	NewAcc = [B#bucket{remain_amount = 0} | Acc],
	update(Type, Charge - Remain, Reserve, Now,
			SessionId, T, NewAcc, Charged + Remain, Reserved);
update(Type, Charge, Reserve, Now, SessionId, [#bucket{units = Type,
		remain_amount = Remain, termination_date = Expires,
		reservations = Reservations} = B | T], Acc, Charged, Reserved)
		when ((Expires == undefined) or (Now < Expires)),
		Remain =< Reserve, Remain > 0 ->
	NewReservation = {Now, Remain, SessionId},
	NewAcc = [B#bucket{remain_amount = 0,
		reservations = [NewReservation | Reservations]} | Acc],
	update(Type, Charge, Reserve - Remain, Now,
			SessionId, T, NewAcc, Charged, Reserved + Remain);
update(_Type, 0, 0, _Now, _SessionId, Buckets, Acc, Charged, Reserved) ->
	{Charged, Reserved, lists:reverse(Acc) ++ Buckets};
update(Type, Charge, Reserve, Now, SessionId, [H | T], Acc, Charged, Reserved) ->
	update(Type, Charge, Reserve, Now, SessionId, T, [H | Acc], Charged, Reserved);
update(_, _, _,  _, _, [], Acc, Charged, Reserved) ->
	{Charged, Reserved, lists:reverse(Acc)}.

-spec charge_session(Type, Charge, SessionId, Buckets) -> Result
	when
		Type :: octets | seconds | cents,
		Charge :: non_neg_integer(),
		SessionId :: string() | binary(),
		Buckets :: [#bucket{}],
		Result :: {Charged, NewBuckets},
		Charged :: non_neg_integer(),
		NewBuckets :: [#bucket{}].
%% @doc Peform final charging for a session.
%%
%% 	Finds and removes all reservations matching `SessionId'.
%% 	If the total reservation amounts are less than `Charge'
%% 	the deficit is debited. Any surplus is refunded within
%% 	the bucket containing the reservation.
%%
%% 	Empty buckets are removed. Expired buckets are removed
%% 	when no session reservations remain.
%%
%% 	Returns `{Charged, NewBuckets}' where
%% 	`Charged' is the total amount debited from the buckets
%% 	and `NewBuckets' is the updated bucket list.
%%
%% @private
charge_session(Type, Charge, SessionId, Buckets) ->
	Now = erlang:system_time(?MILLISECOND),
	charge_session(Type, Charge, Now, SessionId, sort(Buckets), 0, []).
%% @hidden
charge_session(Type, Charge, Now, SessionId,
		[#bucket{units = Type, termination_date = Expires,
		remain_amount = Remain, reservations = Reservations} = B | T],
		Charged, Acc) ->
	case lists:keytake(SessionId, 3, Reservations) of
		{value, {_, Amount, _}, NewReservations} when Amount >= Charge,
				((Expires == undefined) or (Now < Expires)) ->
			NewAcc = [B#bucket{remain_amount = Remain + (Amount - Charge),
					reservations = NewReservations} | Acc],
			charge_session(Type, 0, Now, SessionId, T, Charged + Charge, NewAcc);
		{value, {_, Amount, _}, []} when Amount >= Charge,
				Expires /= undefined, Expires =< Now ->
			charge_session(Type, 0, Now, SessionId, T, Charged + Charge, Acc);
		{value, {_, Amount, _}, NewReservations} when Amount >= Charge,
				Expires /= undefined, Expires =< Now ->
			NewAcc = [B#bucket{reservations = NewReservations} | Acc],
			charge_session(Type, 0, Now, SessionId, T, Charged + Charge, NewAcc);
		{value, {_, Amount, _}, NewReservations}
				when Amount < Charge, Remain > (Charge - Amount),
				((Expires == undefined) or (Now < Expires)) ->
			NewAcc = [B#bucket{remain_amount = Remain - (Charge - Amount),
					reservations = NewReservations} | Acc],
			charge_session(Type, 0, Now, SessionId, T, Charged + Charge, NewAcc);
		{value, {_, Amount, _}, []} when Amount < Charge,
				Expires /= undefined, Expires =< Now ->
			charge_session(Type, Charge - Amount, Now, SessionId, T, Charged + Charge, Acc);
		{value, {_, Amount, _}, NewReservations} when Amount < Charge,
				Expires /= undefined, Expires =< Now ->
			NewAcc = [B#bucket{reservations = NewReservations} | Acc],
			charge_session(Type, Charged + Charge, Now, SessionId, T, Charge - Amount, NewAcc);
		{value, {_, Amount, _}, []}
				when Amount < Charge, Remain >= 0, Remain =< (Charge - Amount),
				((Expires == undefined) or (Now < Expires)) ->
			charge_session(Type, Charge - Amount - Remain, Now, SessionId, T, Amount + Remain, Acc);
		{value, {_, Amount, _}, NewReservations}
				when Amount < Charge, Remain >= 0, Remain =< (Charge - Amount),
				((Expires == undefined) or (Now < Expires)) ->
			NewAcc = [B#bucket{reservations = NewReservations} | Acc],
			charge_session(Type, Charge - Amount - Remain, Now, SessionId, T, Amount + Remain, NewAcc);
		{value, {_, Amount, _}, NewReservations} when Charge =:= 0,
				((Expires == undefined) or (Now < Expires)) ->
			NewAcc = [B#bucket{remain_amount = Remain + Amount,
					reservations = NewReservations} | Acc],
			charge_session(Type, 0, Now, SessionId, T, Charged, NewAcc);
		_ when Reservations == [], Expires /= undefined, Expires =< Now ->
			charge_session(Type, Charge, Now, SessionId, T, Charged, Acc);
		false ->
			charge_session(Type, Charge, Now, SessionId, T, Charged, [B | Acc])
	end;
charge_session(Type, Charge, Now, SessionId, [H | T], Charged, Acc) ->
	charge_session(Type, Charge, Now, SessionId, T, Charged, [H | Acc]);
charge_session(_, Charge, _, _, [], Charge, Acc) ->
	{Charge, lists:reverse(Acc)};
charge_session(Type, Charge, Now, _, [], Charged, Acc) ->
	charge(Type, Charge, Now, lists:reverse(Acc), [], Charged).

%% @hidden
charge(Type, Charge, Now,
		[#bucket{termination_date = Expires, reservations = [],
		remain_amount = Remain} | T], Acc, Charged)
		when Expires /= undefined, Expires =< Now, Remain >= 0 ->
	charge(Type, Charge, Now, T, Acc, Charged);
charge(Type, Charge, Now, [#bucket{units = Type,
		remain_amount = R, termination_date = Expires} = B | T],
		Acc, Charged) when R > Charge,
		((Expires == undefined) or (Now < Expires)) ->
	NewBuckets = [B#bucket{remain_amount = R - Charge} | T],
	{Charged + Charge, lists:reverse(Acc) ++ NewBuckets};
charge(Type, Charge, Now, [#bucket{units = Type,
		remain_amount = R, reservations = [],
		termination_date = Expires} | T], Acc, Charged)
		when R =< Charge, 0 =< R, ((Expires == undefined) or (Now < Expires)) ->
	charge(Type, Charge - R, Now, T, Acc, Charged + R);
charge(Type, Charge, Now, [#bucket{units = Type,
		remain_amount = R, termination_date = Expires} = B | T], Acc, Charged)
		when R =< Charge, 0 =< R, ((Expires == undefined) or (Now < Expires)) ->
	NewAcc = [B#bucket{remain_amount = 0} | Acc],
	charge(Type, Charge - R, Now, T, NewAcc, Charged + R);
charge(_Type, 0, _Now, Buckets, Acc, Charged) ->
	{Charged, lists:reverse(Acc) ++ Buckets};
charge(Type, Charge, Now, [H | T], Acc, Charged) ->
	charge(Type, Charge, Now, T, [H | Acc], Charged);
charge(_, _, _, [], Acc, Charged) ->
	{Charged, lists:reverse(Acc)}.

-spec remove_session(SessionAttributes, SessionList) -> NewSessionList
	when
		SessionAttributes :: [tuple()],
		SessionList :: [{pos_integer(), [tuple()]}],
		NewSessionList :: [{pos_integer(), [tuple()]}].
%% @doc Remove session identification attributes set from active sessions list.
%% @private
remove_session(SessionAttributes, SessionList) ->
	remove_session(SessionAttributes, SessionList, []).
%% @hidden
remove_session(SessionAttributes, [{_, L} = H | T], Acc) ->
	case L -- SessionAttributes of
		[] ->
			lists:reverse(Acc) ++ T;
		_ ->
			remove_session(SessionAttributes, T, [H | Acc])
	end;
remove_session(_, [], Acc) ->
	lists:reverse(Acc).

-spec add_session(SessionAttributes, SessionList) -> SessionList
	when
		SessionAttributes :: [tuple()],
		SessionList :: [{pos_integer(), [tuple()]}].
%% @doc Add new session identification attributes set to active sessions list.
%% @private
add_session(SessionAttributes, SessionList) ->
	SessionId = get_session_id(SessionAttributes),
	case add_session1(SessionId, SessionList) of
		true ->
			SessionList;
		false ->
			[{erlang:system_time(?MILLISECOND), SessionAttributes} | SessionList]
	end.
%% @hidden
add_session1(SessionId, [{_, L} | T]) ->
	case add_session2(SessionId, L) of
		true ->
			true;
		false ->
			add_session1(SessionId, T)
	end;
add_session1(_SessionId, []) ->
	false.
%% @hidden
add_session2([H | T], SessionAttributes) ->
	case lists:member(H, SessionAttributes) of
		true ->
			true;
		false ->
			add_session2(T, SessionAttributes)
	end;
add_session2([], _SessionAttributes) ->
	false.

-spec get_session_id(SessionAttributes) -> SessionId
	when
		SessionAttributes :: [tuple()],
		SessionId :: [tuple()].
%% @doc Get the session identifier value.
%% 	Returns a list of DIAMETER/RADIUS attributes.
%% @private
get_session_id(SessionAttributes) ->
	case lists:keyfind('Session-Id', 1, SessionAttributes) of
		false ->
			get_session_id1(SessionAttributes, []);
		SessionId ->
			[SessionId]
	end.
%% @hidden
get_session_id1([], Acc) ->
	lists:keysort(1, Acc);
get_session_id1(_, Acc) when length(Acc) =:= 3 ->
	lists:keysort(1, Acc);
get_session_id1([{?AcctSessionId, _} = AcctSessionId | T], Acc) ->
	get_session_id1(T, [AcctSessionId | Acc]);
get_session_id1([{?NasIdentifier, _} = NasIdentifier | T], Acc) ->
	get_session_id1(T, [NasIdentifier | Acc]);
get_session_id1([{?NasIpAddress, _} = NasIpAddress | T], Acc) ->
	get_session_id1(T, [NasIpAddress | Acc]);
get_session_id1([_ | T], Acc) ->
	get_session_id1(T, Acc).

-spec sort(Buckets) -> Buckets
	when
		Buckets :: [#bucket{}].
%% @doc Sort `Buckets' oldest first.
%% @private
sort(Buckets) ->
	F = fun(#bucket{termination_date = T1},
				#bucket{termination_date = T2}) when T1 =< T2 ->
			true;
		(_, _)->
			false
	end,
	lists:sort(F, Buckets).

-spec price_units(Amount, UnitSize, UnitPrice) -> {TotalUnits, TotalPrice}
	when
		Amount :: non_neg_integer(),
		UnitSize :: pos_integer(),
		UnitPrice :: pos_integer(),
		TotalUnits :: pos_integer(),
		TotalPrice :: pos_integer().
%% @doc Calculate total size and price.
price_units(0, _UnitSize, _UnitPrice) ->
	{0, 0};
price_units(Amount, UnitSize, UnitPrice) when (Amount rem UnitSize) == 0 ->
	{Amount, UnitPrice * (Amount div UnitSize)};
price_units(Amount, UnitSize, UnitPrice) ->
	Units = (Amount div UnitSize + 1),
	{Units * UnitSize, UnitPrice * Units}.

-spec get_reserve(Price) -> ReserveAmount
	when
		Price :: #price{},
		ReserveAmount :: pos_integer().
%% @doc Get the reserve amount.
get_reserve(#price{units = seconds,
		char_value_use = CharValueUse} = _Price) ->
	case lists:keyfind("radiusReserveTime",
			#char_value_use.name, CharValueUse) of
		#char_value_use{values = [#char_value{value = Value}]} ->
			Value;
		false ->
			0
	end;
get_reserve(#price{units = octets,
		char_value_use = CharValueUse} = _Price) ->
	case lists:keyfind("radiusReserveBytes",
			#char_value_use.name, CharValueUse) of
		#char_value_use{values = [#char_value{value = Value}]} ->
			Value;
		false ->
			0
	end.

-spec refund(SessionId, Buckets) -> Buckets
	when
		Buckets :: [#bucket{}],
		SessionId :: string() | binary().
%% @doc Refund unused reservations.
%% @hidden
refund(SessionId, Buckets) ->
	refund(SessionId, Buckets, []).
%% @hidden
refund(SessionId, [#bucket{reservations = Reservations} = H | T], Acc) ->
	refund(SessionId, H, Reservations, T, [], Acc);
refund(_SessionId, [], Acc) ->
	lists:reverse(Acc).
%% @hidden
refund(SessionId, #bucket{remain_amount = R} = Bucket1,
		[{_, Amount, SessionId} | T1], T2, Acc1, Acc2) ->
	Bucket2 = Bucket1#bucket{remain_amount = R + Amount,
			reservations = lists:reverse(Acc1) ++ T1},
	refund(SessionId, T2, [Bucket2 | Acc2]);
refund(SessionId, Bucket, [H | T1], T2, Acc1, Acc2) ->
	refund(SessionId, Bucket, T1, T2, [H | Acc1], Acc2);
refund(SessionId, Bucket1, [], T, Acc1, Acc2) ->
	Bucket2 = Bucket1#bucket{reservations = lists:reverse(Acc1)},
	refund(SessionId, T, [Bucket2 | Acc2]).

-spec due(Buckets) -> Buckets
	when
		Buckets :: [#bucket{}].
%% @doc Claim if any dues
%% @hidden
due(Buckets) ->
	F = fun(#bucket{remain_amount = R}) when R =< 0 ->
			true;
	(_) ->
			false
	end,
	{B1, B2} = lists:splitwith(F, Buckets),
	due1(B1, B2).
%% @hidden
due1([H | T], B2) ->
	due1(T, due2(H, B2));
due1([], B2) ->
	B2.
%% @hidden
due2(B1, B2) ->
	due2(B1, B2, []).
%% @hidden
due2(#bucket{units = Units, remain_amount = R1} = B1,
		[#bucket{units = Units, remain_amount = R2}
		| T], Acc) when R1 < 0, R1 + R2 < 0 ->
	due2(B1#bucket{remain_amount = R1 + R2}, T, Acc);
due2(#bucket{units = Units, remain_amount = R1},
		[#bucket{units = Units, remain_amount = R2} = B2
		| T], Acc) when R1 < 0, R1 + R2 >= 0 ->
	NewAcc = [B2#bucket{remain_amount = R1 + R2} | Acc],
	lists:reverse(NewAcc) ++ T;
due2(#bucket{} = B, [H | T], Acc) ->
	due2(B, T, [H | Acc]);
due2(#bucket{} = B, [], Acc) ->
	lists:reverse([B | Acc]).

-spec filter_prices(Prices) -> Prices
	when
		Prices :: [#price{}].
%% @doc Filter prices with `timeOfDayRange'
%% @hidden
filter_prices(Prices) ->
	filter_prices(Prices, []).
%% @hidden
filter_prices([#price{char_value_use = CharValueUse} = P | T], Acc) ->
	case lists:keyfind("timeOfDayRange", #char_value_use.name, CharValueUse) of
		#char_value_use{values = [#char_value{value =
				#range{lower = Start, upper = End}}]} ->
			case filter_prices1(Start, End) of
				true ->
					filter_prices(T, [P | Acc]);
				false ->
					filter_prices(T, Acc)
			end;
		_ ->
			filter_prices(T, [P | Acc])
	end;
filter_prices([], Acc) ->
	lists:reverse(Acc).
%% @hidden
filter_prices1(#quantity{units = U1, amount = A1},
		#quantity{units = U2, amount = A2}) ->
	Seconds = ?EPOCH + (erlang:system_time(?MILLISECOND) div 1000),
	{_, Time} = calendar:gregorian_seconds_to_datetime(Seconds),
	filter_prices1(to_seconds(U1, A1), to_seconds(U2, A2),
			calendar:time_to_seconds(Time)).
%% @hidden
filter_prices1(Start, End, Now) when Start < Now, End > Now ->
	true;
filter_prices1(_, _, _) ->
	false.

%% @hidden
to_seconds("seconds", Seconds) when
		(Seconds >= 0) and (Seconds < 86400) ->
	Seconds;
to_seconds("minutes", Minutes) when
		(Minutes >= 0) and (Minutes < 1440) ->
	Minutes * 60;
to_seconds("hours", Hours) when
		(Hours >= 0) and ((Hours < 24) orelse (Hours < 12)) ->
	Hours * 3600.

