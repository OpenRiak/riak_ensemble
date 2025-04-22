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
-module(synctree_ets).
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

-type state() :: ets:tid().

-include("synctree.hrl").

%% ===================================================================
%% synctree callbacks
%% ===================================================================

-spec new(synctree:options()) -> {ok, state()}.
new(_) ->
    TID = case ets:new(?MODULE, []) of
        ?MODULE ->
            ets:whereis(?MODULE);
        Tid ->
            Tid
    end,
    {ok, TID}.

-spec delete(Key :: key(), State :: state()) -> state().
delete(Key, TID) ->
    ets:delete(TID, Key),
    TID.

-spec exists(Key :: key(), State :: state()) -> boolean().
exists(Key, TID) ->
    ets:member(TID, Key).

-spec fetch(Key :: key(), Default :: value(), State :: state()) -> value().
fetch(Key, Default, TID) ->
    case ets:lookup(TID, Key) of
        [] ->
            Default;
        [{_, Value}] ->
            Value
    end.

-spec store(Updates :: actions(), State :: state()) -> state().
store(Updates, TID) ->
    Inserts = store_inserts(Updates),
    ets:insert(TID, Inserts),
    Deletes = store_deletes(Updates, Inserts),
    _ = [ets:delete_object(TID, Rec) || Rec <- Deletes],
    TID.

-spec store(Key :: key(), Val :: value(), state()) -> state().
store(Key, Val, TID) ->
    ets:insert(TID, {Key, Val}),
    TID.

%% ===================================================================
%% Internal
%% ===================================================================

-type ets_delete()  :: {key(), deleted}.
-type ets_deletes() :: list(ets_delete()).
-type ets_insert()  :: {key(), value()}.
-type ets_inserts() :: list(ets_insert()).

-spec store_deletes(actions(), ets_inserts()) -> ets_deletes().
store_deletes([{delete, _} | Updates], [Rec | Inserts]) ->
    [Rec | store_deletes(Updates, Inserts)];
store_deletes([_ | Updates], [_ | Inserts]) ->
    store_deletes(Updates, Inserts);
store_deletes([], []) ->
    [].

-spec store_inserts(actions()) -> ets_inserts().
store_inserts([{put, Key, Val} | Updates]) ->
    [{Key, Val} | store_inserts(Updates)];
store_inserts([{delete, Key} | Updates]) ->
    [{Key, deleted} | store_inserts(Updates)];
store_inserts([]) ->
    [].
