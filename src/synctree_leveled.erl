%% -*- mode: erlang; erlang-indent-level: 4; indent-tabs-mode: nil -*-
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.
%% Copyright (c) 2025 Workday, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(synctree_leveled).
-behavior(synctree).

%% synctree behavior
-export([
    new/1,
    delete/2,
    exists/2,
    fetch/3,
    store/2, store/3
]).

-compile([
    no_auto_import,
    warn_missing_spec_all
]).

-type db()      :: pid().                   %% from leveled_bookie::start()
-type db_opts() :: proplists:proplist().    %% leveled_bookie:open_options()
-type id()      :: binary().
-type options() :: #{atom() => term()}.
-type path()    :: nonempty_string().       %% filesystem path
-type backoff() :: pos_integer().           %% milliseconds
-type state()   :: #{
    id      := id(),
    db      := db(),
    path    := path(),
    backoff := backoff()    %% pause if the leveled_bookie asks for backoff
}.

-include_lib("kernel/include/logger.hrl").

-include("synctree.hrl").

-define(OPEN_RETRIES,   10).
-define(RETRY_DELAY_MS, 100).

%% The time in ms to pause if the leveled_bookie asks for backoff.
-define(BACKOFF_PAUSE,  1).

%% -------------------------------------------------------------------
%% Prefix version used to tag keys stored in LevelEd to allow for easy
%% evolution of the storage format.
-define(KEY_VERSION,    0).
-define(KEY_VSN_BITS,   8).
%% -------------------------------------------------------------------

%% ===================================================================
%% synctree callbacks
%% ===================================================================

-spec new(synctree:options()) -> {ok, state()} | {error, term()}.
new(Opts) when erlang:is_map(Opts) ->
    Path = getopt_path(Opts),
    case maybe_open_leveled(Path, Opts) of
        {ok, DB} ->
            {ok, #{
                backoff => getopt_backoff(Opts),
                db      => DB,
                id      => getopt_tree_id(Opts),
                path    => Path
            }};
        Error ->
            Error
    end;
new(Opts) when erlang:is_list(Opts) ->
    new(proplists:to_map(Opts)).

-spec delete(Key :: key(), State :: state()) -> state().
delete(Key, #{id := Id, db := DB, backoff := BO} = State) ->
    {B, K} = db_bucket_key(Id, Key),
    leveled_bookie:book_delete(DB, B, K, []) =/= pause orelse timer:sleep(BO),
    State.

-spec exists(Key :: key(), State :: state()) -> boolean().
exists(Key, #{id := Id, db := DB}) ->
    {B, K} = db_bucket_key(Id, Key),
    case leveled_bookie:book_get(DB, B, K) of
        {ok, _} ->
            true;
        _ ->
            false
    end.

-spec fetch(Key :: key(), Default :: value(), State :: state()) -> value().
fetch(Key, Default, #{id := Id, db := DB}) ->
    {B, K} = db_bucket_key(Id, Key),
    case leveled_bookie:book_get(DB, B, K) of
        {ok, Val} ->
            Val;
        _ ->
            Default
    end.

-spec store(Updates :: actions(), State :: state()) -> state().
store([{put, Key, Val} | Updates], State) ->
    store(Updates, store(Key, Val, State));
store([{delete, Key} | Updates], State) ->
    store(Updates, delete(Key, State));
store([], State) ->
    State;
store(Updates, _State) ->
    erlang:error(badarg, [Updates]).

-spec store(Key :: key(), Val :: value(), state()) -> state().
store(Key, Val, #{id := Id, db := DB, backoff := BO} = State) ->
    {B, K} = db_bucket_key(Id, Key),
    leveled_bookie:book_put(DB, B, K, Val, []) =/= pause orelse timer:sleep(BO),
    State.

%% ===================================================================
%% Internal
%% ===================================================================

-spec db_bucket_key(Id :: id(), Key :: key()) -> {binary(), binary()}.
db_bucket_key(Id, {Level, Bucket}) when erlang:is_binary(Id)
        andalso ?is_st_level(Level) andalso ?is_st_bucket(Bucket) ->
    BBin = binary:encode_unsigned(Bucket),
    KBin = <<?KEY_VERSION:?KEY_VSN_BITS/integer,
        Id/binary, Level:?ST_LEVEL_BITS/integer>>,
    {BBin, KBin};
db_bucket_key(Id, Key) ->
    erlang:error(badarg, [Id, Key]).

-spec get_ets() -> ets:tid().
%% Creates the public ETS table used to keep track of shared LevelEd
%% references.
%% If the ensemble supervisor is running, ownership of the table is assigned
%% to it, otherwise it's owned by the calling process, almost certainly a test.
get_ets() ->
    case ets:whereis(?MODULE) of
        undefined ->
            Opts = [
                named_table, set, public,
                {read_concurrency, true},
                {write_concurrency, true}
            ],
            New = case ets:new(?MODULE, Opts) of
                ?MODULE ->
                    ets:whereis(?MODULE);
                Tid ->
                    Tid
            end,
            _ = case erlang:whereis(riak_ensemble_sup) of
                Pid when erlang:is_pid(Pid) ->
                    ets:give_away(New, Pid, ?MODULE);
                Nope ->
                    Nope
            end,
            New;
        TID ->
            TID
    end.

-spec maybe_open_leveled(Path :: path(), Opts :: options())
        -> {ok, db()} | {error, term()}.
maybe_open_leveled(Path, Opts) ->
    maybe_open_leveled(Path, Opts, get_ets(), getopt_retries(Opts)).

-spec maybe_open_leveled(
    Path :: path(), Opts :: options(),
    Ets :: ets:tid(), Retries :: non_neg_integer())
        -> {ok, db()} | {error, term()}.
maybe_open_leveled(Path, Opts, Ets, Retries) ->
    %% Check if we have already opened this LevelEd instance, which can
    %% occur when peers are sharing the same on-disk instance.
    Ets = get_ets(),
    case ets:lookup(Ets, Path) of
        [{_Path, {running, DB}}] ->
            {ok, DB};
        [{_Path, starting}] when Retries > 0 ->
            %% Another process is starting, retry
            timer:sleep(?RETRY_DELAY_MS),
            maybe_open_leveled(Path, Opts, Ets, (Retries - 1));
        [{_Path, starting}] ->
            %% We're out of retries
            {error, timeout};
        [] ->
            case ets:insert_new(Ets, {Path, starting}) of
                true ->
                    ok = filelib:ensure_dir(Path),
                    DbOpts = getopt_leveled_opts(Path, Opts),
                    {ok, DB} = Res = leveled_bookie:book_start(DbOpts),
                    ets:insert(?MODULE, {Path, {running, DB}}),
                    Res;
                _ ->
                    %% Race with another process, re-enter immediately
                    %% to pick up current state
                    maybe_open_leveled(Path, Opts, Ets, Retries)
            end;
        Values ->
            %% Nothing else *should* be possible ...
            Record = {Path, Values},
            ?LOG_ERROR("Unrecognized ETS record: ~0tp", [Record]),
            {error, {unrecognized, Record}}
    end.

%% ===================================================================
%% Options Handling
%% ===================================================================

-define(NON_DB_OPTS, [backoff_ms, open_retries, path, tree_id]).

-spec getopt_backoff(Opts :: options()) -> backoff().
getopt_backoff(#{backoff_ms := Backoff}) when ?is_pos_integer(Backoff) ->
    Backoff;
getopt_backoff(#{backoff_ms := Backoff}) ->
    erlang:error(badarg, [backoff_ms, Backoff]);
getopt_backoff(_Opts) ->
    ?BACKOFF_PAUSE.

-spec getopt_leveled_opts(Path :: path(), Opts :: options()) -> db_opts().
getopt_leveled_opts(Path, #{leveled := DbOpts}) ->
    lists:keystore(root_path, 1, DbOpts, {root_path, Path});
getopt_leveled_opts(Path, Opts) ->
    proplists:from_map(
        maps:put(root_path, Path, maps:without(?NON_DB_OPTS, Opts))).

-spec getopt_path(options()) -> path().
getopt_path(#{path := Path}) ->
    safe_path(Path);
getopt_path(_Opts) ->
    Base = "/tmp/ST",
    Name = erlang:integer_to_list(os:system_time(microsecond)),
    safe_path(filename:join(Base, Name)).

-spec safe_path(Path :: unicode:chardata()) -> path().
safe_path(Path) ->
    case unicode:characters_to_list(Path) of
        [_|_] = FlatList ->
            FlatList;
        Error ->
            erlang:error(badarg, [Path, Error])
    end.

-spec getopt_retries(Opts :: options()) -> backoff().
getopt_retries(#{open_retries := Retries}) when ?is_non_neg_integer(Retries) ->
    Retries;
getopt_retries(#{open_retries := Retries}) ->
    erlang:error(badarg, [open_retries, Retries]);
getopt_retries(_Opts) ->
    ?OPEN_RETRIES.

-spec getopt_tree_id(options()) -> id().
getopt_tree_id(#{tree_id := Id}) when erlang:is_binary(Id) ->
    Id;
getopt_tree_id(#{tree_id := Id}) ->
    erlang:error(badarg, [tree_id, Id]);
getopt_tree_id(_Opts) ->
    <<>>.
