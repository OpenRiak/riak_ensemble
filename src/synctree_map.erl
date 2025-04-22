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
-module(synctree_map).
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

-type kvmap() :: #{key() => value()}.
-type state() :: kvmap().

-include("synctree.hrl").

%% ===================================================================
%% synctree callbacks
%% ===================================================================

-spec new(synctree:options()) -> {ok, state()}.
new(_) ->
    {ok, #{}}.

-spec delete(Key :: key(), State :: state()) -> state().
delete(Key, Map) ->
    maps:remove(Key, Map).

-spec exists(Key :: key(), State :: state()) -> boolean().
exists(Key, Map) ->
    erlang:is_map_key(Key, Map).

-spec fetch(Key :: key(), Default :: value(), State :: state()) -> value().
fetch(Key, Default, Map) ->
    maps:get(Key, Map, Default).

-spec store(Updates :: actions(), State :: state()) -> state().
store(Updates, Map) ->
    {Inserts, Deletes} = aggregate_stores(Updates, #{}),
    maps:merge(maps:without(Deletes, Map), Inserts).

-spec store(Key :: key(), Val :: value(), state()) -> state().
store(Key, Val, Map) ->
    Map#{Key => Val}.

%% ===================================================================
%% Internal
%% ===================================================================

-type inserts() :: kvmap().
-type deletes() :: list(key()).

-spec aggregate_stores(actions(), kvmap())
        -> {inserts(), deletes()}.
aggregate_stores([{put, Key, Val} | Updates], Stores) ->
    aggregate_stores(Updates, Stores#{Key => Val});
aggregate_stores([{delete, Key} | Updates], Stores) ->
    aggregate_stores(Updates, Stores#{Key => deleted});
aggregate_stores([], Stores) ->
    maps:fold(fun fold_stores/3, {#{}, []}, Stores);
aggregate_stores(Updates, _Stores) ->
    erlang:error(badarg, [Updates]).

-spec fold_stores(key(), value(), {inserts(), deletes()})
        -> {inserts(), deletes()}.
fold_stores(Key, deleted, {Inserts, Deletes}) ->
    {Inserts, [Key | Deletes]};
fold_stores(Key, Val, {Inserts, Deletes}) ->
    {Inserts#{Key => Val}, Deletes}.
