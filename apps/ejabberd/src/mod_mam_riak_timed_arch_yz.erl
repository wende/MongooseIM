%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================
-module(mod_mam_riak_timed_arch_yz).

-behaviour(ejabberd_gen_mam_archive).
-behaviour(gen_mod).

-include("ejabberd.hrl").
-include("jlib.hrl").

%% API
-export([start/2,
         stop/1,
         archive_size/4,
         archive_message/9,
         lookup_messages/10,
         remove_archive/3,
         purge_single_message/6,
         purge_multiple_messages/9]).

-export([safe_archive_message/9,
         safe_lookup_messages/14]).

-export([key/3]).

%% For tests only
-export([create_obj/3, read_archive/6, bucket/1,
         list_mam_buckets/0, remove_bucket/1]).

-define(YZ_SEARCH_INDEX, <<"mam">>).
-define(MAM_BUCKET_TYPE, <<"mam_yz">>).

start(Host, Opts) ->
    start_chat_archive(Host, Opts).

start_chat_archive(Host, _Opts) ->
    case gen_mod:get_module_opt(Host, ?MODULE, no_writer, false) of
        true ->
            ok;
        false ->
            ejabberd_hooks:add(mam_archive_message, Host, ?MODULE, safe_archive_message, 50)
    end,
    ejabberd_hooks:add(mam_archive_size, Host, ?MODULE, archive_size, 50),
    ejabberd_hooks:add(mam_lookup_messages, Host, ?MODULE, safe_lookup_messages, 50),
    ejabberd_hooks:add(mam_remove_archive, Host, ?MODULE, remove_archive, 50),
    ejabberd_hooks:add(mam_purge_single_message, Host, ?MODULE, purge_single_message, 50),
    ejabberd_hooks:add(mam_purge_multiple_messages, Host, ?MODULE, purge_multiple_messages, 50).

stop(Host) ->
    stop_chat_archive(Host).

stop_chat_archive(Host) ->
    case gen_mod:get_module_opt(Host, ?MODULE, no_writer, false) of
        true ->
            ok;
        false ->
            ejabberd_hooks:delete(mam_archive_message, Host, ?MODULE, safe_archive_message, 50)
    end,
    ejabberd_hooks:delete(mam_archive_size, Host, ?MODULE, archive_size, 50),
    ejabberd_hooks:delete(mam_lookup_messages, Host, ?MODULE, safe_lookup_messages, 50),
    ejabberd_hooks:delete(mam_remove_archive, Host, ?MODULE, remove_archive, 50),
    ejabberd_hooks:delete(mam_purge_single_message, Host, ?MODULE, purge_single_message, 50),
    ejabberd_hooks:delete(mam_purge_multiple_messages, Host, ?MODULE, purge_multiple_messages, 50),
    ok.

safe_archive_message(Result, Host, MessID, UserID,
                     LocJID, RemJID, SrcJID, Dir, Packet) ->
    try
        R = archive_message(Result, Host, MessID, UserID,
                            LocJID, RemJID, SrcJID, Dir, Packet),
        case R of
            ok ->
                ok;
            Other ->
                throw(Other)
        end,
        R
    catch _Type:Reason ->
        ?WARNING_MSG("Could not write message to archive, reason: ~p", [Reason]),
        ejabberd_hooks:run(mam_drop_message, Host, [Host]),
        {error, Reason}
    end.

safe_lookup_messages({error, _Reason} = Result, _Host,
                     _UserID, _UserJID, _RSM, _Borders,
                     _Start, _End, _Now, _WithJID,
                     _PageSize, _LimitPassed, _MaxResultLimit,
                     _IsSimple) ->
                     Result;
safe_lookup_messages(_Result, _Host,
                     _UserID, UserJID, RSM, Borders,
                     Start, End, _Now, WithJID,
                     PageSize, LimitPassed, MaxResultLimit,
                     IsSimple) ->
    try
        lookup_messages(UserJID, RSM, Borders,
                        Start, End, WithJID,
                        PageSize, LimitPassed, MaxResultLimit,
                        IsSimple)
    catch _Type:Reason ->
        {error, Reason}
    end.

archive_size(Size, _Host, _ArchiveID, _ArchiveJID) ->
    Size.

%% use correct bucket for given date

-spec bucket(calendar:date() | integer()) -> binary().
bucket(MsgId) when is_integer(MsgId) ->
    {MicroSec, _} = mod_mam_utils:decode_compact_uuid(MsgId),
    MsgNow = mod_mam_utils:microseconds_to_now(MicroSec),
    {MsgDate, _} = calendar:now_to_datetime(MsgNow),
    bucket(MsgDate);
bucket({_, _, _} = Date) ->
    bucket(calendar:iso_week_number(Date));
bucket({Year, Week}) ->
    YearBin = integer_to_binary(Year),
    WeekNumBin = integer_to_binary(Week),
    {?MAM_BUCKET_TYPE, <<"mam_",YearBin/binary, "_", WeekNumBin/binary>>};
bucket(_) ->
    undefined.

list_mam_buckets() ->
    {ok, Buckets} = riakc_pb_socket:list_buckets(mongoose_riak:get_worker(), ?MAM_BUCKET_TYPE),
    [{?MAM_BUCKET_TYPE, Bucket} || Bucket <- Buckets].


remove_bucket(Bucket) ->
    {ok, Keys} = mongoose_riak:list_keys(Bucket),
    [mongoose_riak:delete(Bucket, Key) || Key <- Keys].

archive_message(_, _, MessID, _ArchiveID, LocJID, RemJID, SrcJID, _Dir, Packet) ->
    LocalJID = bare_jid(LocJID),
    RemoteJID = bare_jid(RemJID),
    SourceJID = bare_jid(SrcJID),
    MsgId = integer_to_binary(MessID),
    Key = key(LocalJID, RemoteJID, MsgId),

    Bucket = bucket(MessID),

    RiakMap = create_obj(MsgId, SourceJID, Packet),
    mongoose_riak:update_type(Bucket, Key, riakc_map:to_op(RiakMap)).

create_obj(MsgId, SourceJID, Packet) ->

    Ops = [{{<<"msg_id">>, register},
            fun(R) -> riakc_register:set(MsgId, R) end},
           {{<<"source_jid">>, register},
            fun(R) -> riakc_register:set(SourceJID, R) end},
           {{<<"packet">>, register},
            fun(R) -> riakc_register:set(exml:to_binary(Packet), R) end}],

    mongoose_riak:create_new_map(Ops).

lookup_messages(ArchiveJID, RSM, Borders, Start, End,
                WithJID, PageSize, LimitPassed, MaxResultLimit, IsSimple) ->

    OwnerJID = bare_jid(ArchiveJID),
    RemoteJID = bare_jid(WithJID),

    SearchOpts2 = add_sorting(RSM, [{rows, PageSize}]),
    SearchOpts = add_offset(RSM, SearchOpts2),

    F = fun get_msg_id_key/3,

    {MsgIdStart, MsgIdEnd} = calculate_msg_id_borders(RSM, Borders, Start, End),
    {TotalCountFullQuery, Result} = read_archive(OwnerJID, RemoteJID,
                                                 MsgIdStart, MsgIdEnd,
                                                 SearchOpts, F),

    SortedKeys = sort_messages(Result),
    case IsSimple of
        true ->
            {ok, {undefined, undefined, get_messages(SortedKeys)}};
        _ ->
            {MsgIdStartNoRSM, MsgIdEndNoRSM} = calculate_msg_id_borders(undefined, Borders, Start, End),
            {TotalCount, _} = read_archive(OwnerJID, RemoteJID,
                                           MsgIdStartNoRSM, MsgIdEndNoRSM,
                                           [{rows, 1}], F),
            Offset = calculate_offset(RSM, TotalCountFullQuery, length(SortedKeys),
                                      {OwnerJID, RemoteJID, MsgIdStartNoRSM}),
            case TotalCount - Offset > MaxResultLimit andalso not LimitPassed of
                true ->
                    {error, 'policy-violation'};
                _ ->
                    {ok, {TotalCount, Offset, get_messages(SortedKeys)}}
            end
    end.


add_sorting(#rsm_in{direction = before}, Opts) ->
    [{sort, <<"msg_id_register desc">>} | Opts];
add_sorting(_, Opts) ->
    [{sort, <<"msg_id_register asc">>} | Opts].

add_offset(#rsm_in{index = Offset}, Opts) when is_integer(Offset) ->
    [{start, Offset} | Opts];
add_offset(_, Opts) ->
    Opts.

calculate_offset(#rsm_in{direction = before}, TotalCount, PageSize, _) ->
    TotalCount - PageSize;
calculate_offset(#rsm_in{direction = aft, id = Id}, _, _, {Owner, Remote, MsgIdStart}) when Id /= undefined ->
    {Count, _} = read_archive(Owner, Remote, MsgIdStart, Id,
                              [{rows, 1}], fun get_msg_id_key/3),
    Count;
calculate_offset(#rsm_in{direction = undefined, index = Index}, _, _, _) when is_integer(Index) ->
    Index;
calculate_offset(_, _TotalCount, _PageSize, _) ->
    0.

get_msg_id_key(Bucket, Key, Msgs) ->
    [_, _, MsgId] = decode_key(Key),
    Item = {binary_to_integer(MsgId), Bucket, Key},
    [Item | Msgs].

get_messages(BucketKeys) ->
    lists:flatten([get_message2(MsgId, Bucket, Key) || {MsgId, Bucket, Key} <- BucketKeys]).

get_message2(MsgId, Bucket, Key) ->
    case mongoose_riak:fetch_type(Bucket, Key) of
        {ok, RiakMap} ->
            SourceJID = riakc_map:fetch({<<"source_jid">>, register}, RiakMap),
            PacketBin = riakc_map:fetch({<<"packet">>, register}, RiakMap),
            {ok, Packet} = exml:parse(PacketBin),
            {MsgId, jlib:binary_to_jid(SourceJID), Packet};
        _ ->
            []
    end.

remove_archive(Host, _ArchiveID, ArchiveJID) ->
    {ok, TotalCount, _, _} = R = remove_chunk(Host, ArchiveJID, 0),
    Result = do_remove_archive(100, R, Host, ArchiveJID),
    case Result of
        {stopped, N} ->
            lager:warning("archive removal stopped for jid after processing ~p items out of ~p total",
                          [ArchiveJID, N, TotalCount]);
        {ok, _} ->
            ok
    end,
    Result.

remove_chunk(_Host, ArchiveJID, Acc) ->
    KeyFiletrs = key_filters(bare_jid(ArchiveJID)),
    fold_archive(fun delete_key_fun/3,
                 KeyFiletrs,
                  [{rows, 50}, {sort, <<"msg_id_register asc">>}], Acc).

do_remove_archive(0, {ok, _, _, Acc}, _, _) ->
    {stopped, Acc};
do_remove_archive(_, {ok, 0, _, Acc}, _, _) ->
    {ok, Acc};
do_remove_archive(N, {ok, _TotalResults, _RowsIterated, Acc}, Host, ArchiveJID) ->
    timer:sleep(1000), %% give Riak some time to clear after just removed keys
    R = remove_chunk(Host, ArchiveJID, Acc),
    do_remove_archive(N-1, R, Host, ArchiveJID).

purge_single_message(_Result, _Host, MessID, _ArchiveID, ArchiveJID, _Now) ->
    ArchiveJIDBin = bare_jid(ArchiveJID),
    KeyFilters = key_filters(ArchiveJIDBin, MessID),
    {ok, 1, 1, 1} = fold_archive(fun delete_key_fun/3, KeyFilters, [], 0),
    ok.

purge_multiple_messages(_Result, _Host, _ArchiveID, ArchiveJID, _Borders, Start, End, _Now, WithJID) ->
    ArchiveJIDBin = bare_jid(ArchiveJID),
    KeyFilters = key_filters(ArchiveJIDBin, WithJID, Start, End),
    {ok, Total, _Iterated, Deleted} = fold_archive(fun delete_key_fun/3,
                                                   KeyFilters,
                                                   [{rows, 50}, {sort, <<"msg_id_register asc">>}], 0),
    case Total == Deleted of
        true ->
            ok;
        _ ->
            lager:warning("not all messages have been purged for user ~p", [ArchiveJID]),
            ok
    end.

delete_key_fun(Bucket, Key, N) ->
    ok = mongoose_riak:delete(Bucket, Key, [{dw, 2}]),
    N + 1.


key(LocalJID, RemoteJID, MsgId) ->
    <<LocalJID/binary, $/, RemoteJID/binary, $/, MsgId/binary>>.

decode_key(KeyBinary) ->
    binary:split(KeyBinary, <<"/">>, [global]).

-spec read_archive(binary(),
                   binary() | undefined,
                   term(),
                   term(),
                   integer() | undefined,
                   fun()) ->
    {integer(), list()} | {error, term()}.
read_archive(OwnerJID, WithJID, Start, End, SearchOpts, Fun) ->
    KeyFilters = key_filters(OwnerJID, WithJID, Start, End),
    {ok, Cnt, _, NewAcc} = fold_archive(Fun, KeyFilters, SearchOpts, []),
    {Cnt, NewAcc}.


sort_messages(Msgs) ->
    SortFun = fun({MsgId1, _, _}, {MsgId2, _, _}) ->
        MsgId1 =< MsgId2
    end,
    lists:sort(SortFun, Msgs).

fold_archive(Fun, Query, SearchOpts, InitialAcc) ->
    Result = mongoose_riak:search(?YZ_SEARCH_INDEX, Query, SearchOpts),
    case Result of
        {ok, {search_results, [], _, Count}} ->
            {ok, Count, 0, InitialAcc};
        {ok, {search_results, Results, _Score, Count}} ->
            {ok, Count, length(Results), do_fold_archive(Fun, Results, InitialAcc)};
        {error, R} = Err ->
            ?WARNING_MSG("Error reading archive key_filters=~p, reason=~p", [Query, R]),
            Err
    end.

do_fold_archive(Fun, BucketKeys, InitialAcc) ->
    lists:foldl(fun({_Index, Props}, Acc) ->
        {_, Bucket} = lists:keyfind(<<"_yz_rb">>, 1, Props),
        {_, Type} = lists:keyfind(<<"_yz_rt">>, 1, Props),
        {_ , Key} = lists:keyfind(<<"_yz_rk">>, 1, Props),
        Fun({Type, Bucket}, Key, Acc)
    end, InitialAcc, BucketKeys).

key_filters(Jid) ->
    <<"_yz_rk:",Jid/binary,"*">>.

key_filters(LocalJid, undefined) ->
    key_filters(LocalJid);
key_filters(LocalJid, MsgId) when is_integer(MsgId) ->
    StartsWith = key_filters(LocalJid),
    MsgIdBin = integer_to_binary(MsgId),
    <<StartsWith/binary, " AND msg_id_register:", MsgIdBin/binary>>;
key_filters(LocalJid, RemoteJid) ->
    <<"_yz_rk:",LocalJid/binary,"/", RemoteJid/binary,"*">>.

key_filters(LocalJid, RemoteJid, undefined, undefined) ->
    key_filters(LocalJid, RemoteJid);
key_filters(LocalJid, RemoteJid, Start, End) ->
    JidFilter = key_filters(LocalJid, RemoteJid),
    IdFilter = id_filters(Start, End),
    <<JidFilter/binary, " AND ", IdFilter/binary>>.

id_filters(StartInt, undefined) ->
    solr_id_filters(integer_to_binary(StartInt), <<"*">>);
id_filters(undefined, EndInt) ->
    solr_id_filters(<<"*">>, integer_to_binary(EndInt));
id_filters(StartInt, EndInt) ->
    solr_id_filters(integer_to_binary(StartInt), integer_to_binary(EndInt)).

solr_id_filters(Start, End) ->
    <<"msg_id_register:[",Start/binary," TO ", End/binary," ]">>.

calculate_msg_id_borders(#rsm_in{id = undefined}, Borders, Start, End) ->
    calculate_msg_id_borders(undefined, Borders, Start, End);
calculate_msg_id_borders(#rsm_in{direction = aft, id = Id}, Borders, Start, End) ->
    {StartId, EndId} = calculate_msg_id_borders(undefined, Borders, Start, End),
    NextId = Id + 1,
    {mod_mam_utils:maybe_max(StartId, NextId), EndId};
calculate_msg_id_borders(#rsm_in{direction = before, id = Id}, Borders, Start, End) ->
    {StartId, EndId} = calculate_msg_id_borders(undefined, Borders, Start, End),
    PrevId = Id - 1,
    {StartId, mod_mam_utils:maybe_min(EndId, PrevId)};
calculate_msg_id_borders(_RSM, Borders, Start, End) ->
    StartID = maybe_encode_compact_uuid(Start, 0),
    EndID = maybe_encode_compact_uuid(End, 255),
    {mod_mam_utils:apply_start_border(Borders, StartID),
     mod_mam_utils:apply_end_border(Borders, EndID)}.

bare_jid(undefined) -> undefined;
bare_jid(JID) ->
    jlib:jid_to_binary(jlib:jid_remove_resource(jlib:jid_to_lower(JID))).


maybe_encode_compact_uuid(undefined, _) ->
    undefined;
maybe_encode_compact_uuid(Microseconds, NodeID) ->
    mod_mam_utils:encode_compact_uuid(Microseconds, NodeID).